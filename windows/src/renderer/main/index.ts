import QRCode from 'qrcode'
import type { Mp2tvApi } from '../../shared/api'

declare global {
  interface Window {
    mp2tv: Mp2tvApi
  }
}

interface PairedDevice {
  senderId: string
  name: string
  platform: string
}

interface DisplayInfo {
  id: string
  label: string
}

interface State {
  receiverName: string
  receiverId: string
  qr: string
  devices: PairedDevice[]
  settings: { displayId: string | null; autostart: boolean }
  displays: DisplayInfo[]
  ips: string[]
  port: number
}

const api = window.mp2tv
const $ = <T extends HTMLElement>(sel: string): T => document.querySelector(sel)!

let toastTimer: number | undefined
function toast(text: string): void {
  const el = $('#toast')
  el.textContent = text
  el.style.display = 'block'
  clearTimeout(toastTimer)
  toastTimer = window.setTimeout(() => (el.style.display = 'none'), 4000)
}

async function renderQr(payload: string): Promise<void> {
  $('#qr').setAttribute('src', await QRCode.toDataURL(payload, { width: 440, margin: 1 }))
}

function renderDevices(devices: PairedDevice[]): void {
  const box = $('#devices')
  box.innerHTML = ''
  if (!devices.length) {
    box.innerHTML = '<div class="empty">暂无已配对手机</div>'
    return
  }
  for (const d of devices) {
    const row = document.createElement('div')
    row.className = 'row'
    const name = document.createElement('span')
    name.className = 'name'
    name.textContent = d.name
    const meta = document.createElement('span')
    meta.className = 'meta'
    meta.textContent = d.platform
    const del = document.createElement('button')
    del.className = 'danger'
    del.textContent = '删除'
    del.onclick = async () => {
      if (confirm(`删除「${d.name}」？该手机之后将无法投屏。`)) {
        renderDevices((await api.invoke('device:unpair', d.senderId)) as PairedDevice[])
      }
    }
    row.append(name, meta, del)
    box.append(row)
  }
}

function renderDisplays(displays: DisplayInfo[], selected: string | null): void {
  const sel = $('#displaySel') as HTMLSelectElement
  sel.innerHTML = ''
  for (const d of displays) {
    const o = document.createElement('option')
    o.value = d.id
    o.textContent = d.label
    sel.append(o)
  }
  sel.value = selected ?? displays[0]?.id ?? ''
  sel.onchange = () => api.invoke('settings:set', { displayId: sel.value })
}

async function init(): Promise<void> {
  const s = (await api.invoke('app:getState')) as State
  $('#whoami').textContent = `${s.receiverName} · ${s.ips.join(' / ')}:${s.port}`
  renderQr(s.qr)
  renderDevices(s.devices)
  renderDisplays(s.displays, s.settings.displayId)
  const as = $('#autostart') as HTMLInputElement
  as.checked = s.settings.autostart
  as.onchange = () => api.invoke('settings:set', { autostart: as.checked })

  $('#refreshQr').onclick = async () => renderQr((await api.invoke('qr:refresh')) as string)
  $('#exportLogs').onclick = () => api.invoke('logs:export')

  api.on('paired', (name) => toast(`已与 ${name} 配对`))
  api.on('devices', (devices) => renderDevices(devices as PairedDevice[]))
  api.on('qr', (payload) => renderQr(payload as string))
}

init()
