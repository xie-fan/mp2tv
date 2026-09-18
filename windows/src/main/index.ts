import { app, BrowserWindow, Tray, Menu, ipcMain, screen, powerMonitor, powerSaveBlocker, dialog, nativeImage, shell } from 'electron'
import path from 'node:path'
import fs from 'node:fs'
import os from 'node:os'
import { initLog, getLogFile, log } from './log'
import { loadOrCreateIdentity, type Identity } from './identity'
import { Store } from './store'
import { Pairing, localIPv4 } from './pairing'
import { MdnsAdvertiser } from './mdns'
import { ReceiverServer } from './server'
import { FRAME_VIDEO } from './protocol'

app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required')

// portable builds unpack to a temp dir — register the outer exe, not the
// (deleted-after-exit) temp path; and only packaged builds may autostart
function applyAutostart(enabled: boolean): void {
  const portable = process.env.PORTABLE_EXECUTABLE_FILE
  app.setLoginItemSettings({
    openAtLogin: enabled && app.isPackaged,
    ...(portable ? { path: portable } : {})
  })
}

const gotLock = app.requestSingleInstanceLock()

let identity: Identity
let store: Store
let pairing: Pairing
let mdns = new MdnsAdvertiser()
let server: ReceiverServer
let mainWin: Electron.BrowserWindow | null = null
let mirrorWin: Electron.BrowserWindow | null = null
let mirrorReady = false
let mirrorSenderName = ''
const mediaBacklog: { type: number; payload: Buffer }[] = []
let tray: Electron.Tray | null = null
let locked = false
let quitting = false
let sleepBlockerId: number | null = null

const receiverName = os.hostname()

function fingerprintB64url(): string {
  return Buffer.from(identity.fingerprint, 'hex').toString('base64url')
}

function currentQrPayload(): string {
  return pairing.qrPayload(server.port, fingerprintB64url(), receiverName)
}

function rendererFile(name: string): string {
  return path.join(__dirname, `../renderer/${name}`)
}

function loadRenderer(win: Electron.BrowserWindow, page: string): void {
  const devUrl = process.env.ELECTRON_RENDERER_URL?.replace(/\/$/, '')
  if (devUrl) win.loadURL(`${devUrl}/${page}.html`)
  else win.loadFile(rendererFile(`${page}.html`))
}

function createMainWindow(): void {
  mainWin = new BrowserWindow({
    width: 420,
    height: 640,
    resizable: true,
    autoHideMenuBar: true,
    icon: path.join(__dirname, '../../assets/icon.png'),
    webPreferences: {
      preload: path.join(__dirname, '../preload/index.js'),
      sandbox: false
    }
  })
  loadRenderer(mainWin, 'index')
  mainWin.on('close', (e: Electron.Event) => {
    if (!quitting) {
      e.preventDefault()
      mainWin?.hide()
    }
  })
  mainWin.on('closed', () => (mainWin = null))
}

function targetDisplay(): Electron.Display {
  const want = store.getSettings().displayId
  const all = screen.getAllDisplays()
  return all.find((d) => String(d.id) === want) ?? screen.getPrimaryDisplay()
}

function createMirrorWindow(senderName: string): void {
  if (mirrorWin) mirrorWin.destroy()
  const disp = targetDisplay()
  mirrorWin = new BrowserWindow({
    x: disp.bounds.x,
    y: disp.bounds.y,
    width: disp.bounds.width,
    height: disp.bounds.height,
    fullscreen: true,
    autoHideMenuBar: true,
    backgroundColor: '#000000',
    show: false,
    webPreferences: {
      preload: path.join(__dirname, '../preload/index.js'),
      sandbox: false
    }
  })
  loadRenderer(mirrorWin, 'mirror')
  mirrorWin.once('ready-to-show', () => {
    mirrorWin?.show()
    mirrorWin?.focus()
  })
  const win = mirrorWin
  win.on('closed', () => {
    // a newer mirror window may already have replaced this one — only end the
    // session when OUR window was still the active mirror
    if (mirrorWin !== win) return
    mirrorWin = null
    if (sleepBlockerId !== null) {
      powerSaveBlocker.stop(sleepBlockerId)
      sleepBlockerId = null
    }
    server?.endSession(true)
  })
  mirrorSenderName = senderName
  sleepBlockerId = powerSaveBlocker.start('prevent-display-sleep')
}

function pushQr(): void {
  log('pairing qr:', currentQrPayload())
  mainWin?.webContents.send('qr', currentQrPayload())
}

function state() {
  return {
    receiverName,
    receiverId: identity.receiverId,
    qr: currentQrPayload(),
    devices: store.listDevices(),
    settings: store.getSettings(),
    displays: screen.getAllDisplays().map((d, i) => ({
      id: String(d.id),
      label: `显示器 ${i + 1}（${d.size.width}×${d.size.height}）`
    })),
    ips: localIPv4(),
    port: server.port
  }
}

function sendToMirror(channel: string, ...args: unknown[]): void {
  if (mirrorWin && !mirrorWin.isDestroyed()) mirrorWin.webContents.send(channel, ...args)
}

async function main(): Promise<void> {
  await app.whenReady()
  initLog(path.join(app.getPath('userData'), 'logs'))
  log('mp2tv starting')

  identity = await loadOrCreateIdentity(app.getPath('userData'))
  log('receiverId', identity.receiverId)
  store = new Store(app.getPath('userData'))
  pairing = new Pairing()

  powerMonitor.on('lock-screen', () => {
    locked = true
    log('screen locked')
  })
  powerMonitor.on('unlock-screen', () => {
    locked = false
    log('screen unlocked')
  })

  server = new ReceiverServer({
    identity,
    store,
    pairing,
    isLocked: () => locked,
    receiverName
  })
  await server.start()
  mdns.start(receiverName, server.port, identity.receiverId)
  log('pairing qr:', currentQrPayload())

  server.on('paired', (name: string) => {
    mainWin?.webContents.send('paired', name)
    mainWin?.webContents.send('devices', store.listDevices())
  })
  server.on('qrChanged', pushQr)
  server.on('devicesChanged', () => mainWin?.webContents.send('devices', store.listDevices()))
  server.on('sessionStart', (senderName: string) => {
    mirrorReady = false
    mediaBacklog.length = 0
    createMirrorWindow(senderName)
  })
  server.on('sessionResume', () => sendToMirror('session:resume'))
  server.on('sessionReconnecting', () => sendToMirror('session:reconnecting'))
  server.on('sessionEnded', () => {
    if (mirrorWin && !mirrorWin.isDestroyed()) mirrorWin.close()
    mirrorWin = null
  })
  server.on('media', (f) => {
    if (!mirrorWin || mirrorWin.isDestroyed()) return
    if (!mirrorReady) {
      // renderer hasn't registered its IPC listener yet; keep frames so the
      // first SPS/keyframe isn't lost (bounded: drop non-key video on overflow)
      if (mediaBacklog.length > 300) {
        for (let i = mediaBacklog.length - 1; i >= 0; i--) {
          if (mediaBacklog[i].type === FRAME_VIDEO && !(mediaBacklog[i].payload[8] & 1)) {
            mediaBacklog.splice(i, 1)
          }
        }
      }
      mediaBacklog.push({ type: f.type, payload: f.payload })
      return
    }
    mirrorWin.webContents.send('media', f.type, f.payload)
  })

  // ---- IPC ----
  ipcMain.handle('app:getState', () => state())
  ipcMain.handle('qr:refresh', () => {
    pairing.rotate()
    return currentQrPayload()
  })
  ipcMain.handle('device:unpair', (_e, senderId: string) => {
    server.removeDevice(senderId)
    return store.listDevices()
  })
  ipcMain.handle('settings:set', (_e, patch: { displayId?: string | null; autostart?: boolean }) => {
    const s = store.setSettings(patch)
    if (patch.autostart !== undefined) applyAutostart(s.autostart)
    return s
  })
  ipcMain.handle('logs:export', async () => {
    const src = getLogFile()
    if (!src || !mainWin) return null
    const r = await dialog.showSaveDialog(mainWin, {
      defaultPath: 'mp2tv.log',
      filters: [{ name: '日志', extensions: ['log', 'txt'] }]
    })
    if (!r.canceled && r.filePath) {
      fs.copyFileSync(src, r.filePath)
      shell.showItemInFolder(r.filePath)
      return r.filePath
    }
    return null
  })
  ipcMain.handle('mirror:ready', () => {
    sendToMirror('session:start', { senderName: mirrorSenderName })
    mirrorReady = true
    for (const f of mediaBacklog) sendToMirror('media', f.type, f.payload)
    mediaBacklog.length = 0
  })
  ipcMain.handle('session:stop', () => server.endSession(true))
  ipcMain.handle('session:command', (_e, action: string) => server.sendCommand(action))
  ipcMain.handle('window:toggleFullscreen', () => {
    if (!mirrorWin) return
    if (mirrorWin.isFullScreen()) {
      const wa = targetDisplay().workAreaSize
      const w = Math.min(480, wa.width)
      const h = Math.min(854, wa.height)
      mirrorWin.setFullScreen(false)
      mirrorWin.setSize(w, h)
      mirrorWin.center()
    } else {
      mirrorWin.setBounds(targetDisplay().bounds)
      mirrorWin.setFullScreen(true)
    }
    sendToMirror('window:state', { fullscreen: mirrorWin.isFullScreen() })
  })
  ipcMain.handle('window:windowed', () => {
    if (mirrorWin?.isFullScreen()) {
      const wa = targetDisplay().workAreaSize
      mirrorWin.setFullScreen(false)
      mirrorWin.setSize(Math.min(480, wa.width), Math.min(854, wa.height))
      mirrorWin.center()
      sendToMirror('window:state', { fullscreen: false })
    }
  })
  ipcMain.handle('window:setPin', (_e, on: boolean) => mirrorWin?.setAlwaysOnTop(on))
  ipcMain.handle('window:closeMirror', () => mirrorWin?.close())

  // autostart from saved settings
  applyAutostart(store.getSettings().autostart)

  // no default menu: Ctrl+R reload would silently kill the mirror window
  Menu.setApplicationMenu(null)

  createMainWindow()

  tray = new Tray(nativeImage.createFromPath(path.join(__dirname, '../../assets/icon.png')))
  tray.setToolTip('mp2tv')
  tray.setContextMenu(
    Menu.buildFromTemplate([
      { label: '打开 mp2tv', click: () => (mainWin ? mainWin.show() : createMainWindow()) },
      { type: 'separator' },
      {
        label: '退出',
        click: () => {
          quitting = true
          app.quit()
        }
      }
    ])
  )
  tray.on('click', () => (mainWin ? mainWin.show() : createMainWindow()))

  // QR expires after 5 min — push a fresh one periodically so an open main window stays valid
  setInterval(() => {
    if (pairing.isExpired() && mainWin && !mainWin.isDestroyed() && mainWin.isVisible()) pushQr()
  }, 30000)

  app.on('window-all-closed', () => {
    /* tray app: keep running */
  })
}

if (!gotLock) {
  app.quit()
} else {
  app.on('before-quit', () => {
    quitting = true
    server?.stop()
    mdns.stop()
  })

  app.on('second-instance', () => mainWin?.show())

  main().catch((e) => {
    console.error(e)
    app.quit()
  })
}
