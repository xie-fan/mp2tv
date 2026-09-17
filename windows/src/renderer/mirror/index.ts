import { VideoPipeline } from './decoder'
import { PcmPlayer } from './audio'
import type { Mp2tvApi } from '../../shared/api'

declare global {
  interface Window {
    mp2tv: Mp2tvApi
  }
}

const api = window.mp2tv
const $ = <T extends HTMLElement>(sel: string): T => document.querySelector(sel)!
const canvas = $('#screen') as HTMLCanvasElement
const ctx2d = canvas.getContext('2d')!
const bar = $('#bar')
const overlay = $('#overlay')
const btnMute = $('#btnMute') as HTMLButtonElement
const btnMode = $('#btnMode') as HTMLButtonElement
const btnPin = $('#btnPin') as HTMLButtonElement
const btnStop = $('#btnStop') as HTMLButtonElement

const FRAME_VIDEO = 2
const FRAME_AUDIO = 3

const pipeline = new VideoPipeline()
const player = new PcmPlayer()

let senderName = ''
let muted = false
let pinned = false
let fullscreen = true

interface QItem {
  frame: VideoFrame
  ptsUs: number
  rotation: number
}
const vq: QItem[] = []
let shown: VideoFrame | null = null
let currentRotation = 0

// free-run clock used until audio starts flowing
let firstVideoPts = -1
let firstVideoLocal = 0

function log(msg: string): void {
  console.log('[mirror]', msg)
}

pipeline.onLog = log
pipeline.onError = () => api.invoke('session:command', 'keyframe')
pipeline.onOutput = (d) => {
  vq.push(d)
  // bound the queue: drop oldest undisplayed frames when falling behind
  while (vq.length > 8) {
    vq.shift()!.frame.close()
  }
}

function audioNowPts(): number | null {
  return player.playedPts()
}

function videoNowPts(): number {
  const a = audioNowPts()
  if (a !== null) return a + 15_000 // show slightly ahead of the audio playhead
  if (firstVideoPts < 0) return -1
  return firstVideoPts + (performance.now() - firstVideoLocal) * 1000 - 150_000
}

function drawFrame(item: QItem): void {
  const { frame, rotation } = item
  const w = frame.displayWidth
  const h = frame.displayHeight
  const rot = rotation % 4
  const swap = rot === 1 || rot === 3
  if (canvas.width !== (swap ? h : w) || canvas.height !== (swap ? w : h)) {
    canvas.width = swap ? h : w
    canvas.height = swap ? w : h
  }
  ctx2d.save()
  ctx2d.translate(canvas.width / 2, canvas.height / 2)
  ctx2d.rotate((rot * Math.PI) / 2)
  ctx2d.drawImage(frame, -w / 2, -h / 2, w, h)
  ctx2d.restore()
}

function renderLoop(): void {
  const now = videoNowPts()
  if (now >= 0) {
    let due: QItem | null = null
    while (vq.length && vq[0].ptsUs <= now) {
      due?.frame.close()
      due = vq.shift()!
    }
    if (!due && vq.length >= 8) {
      // audio clock stalled or lagging far behind the stream: stay live by
      // showing the newest queued frame rather than freezing
      while (vq.length > 1) vq.shift()!.frame.close()
      due = vq.shift()!
    }
    if (due) {
      shown?.close()
      shown = due.frame
      currentRotation = due.rotation
      drawFrame(due)
    }
  }
  requestAnimationFrame(renderLoop)
}

let mediaCount = 0
async function onMedia(type: number, payload: Uint8Array): Promise<void> {
  if (++mediaCount <= 3 || mediaCount % 300 === 0)
    log(`media #${mediaCount} type=${type} len=${payload.byteLength} ${player.diag()} vq=${vq.length}`)
  if (type === FRAME_VIDEO) {
    const dv = new DataView(payload.buffer, payload.byteOffset, payload.byteLength)
    const ptsUs = Number(dv.getBigUint64(0))
    const flags = dv.getUint8(8)
    const rotation = dv.getUint8(9)
    const au = payload.subarray(10)
    if (firstVideoPts < 0) {
      firstVideoPts = ptsUs
      firstVideoLocal = performance.now()
    }
    pipeline.feed(au, (flags & 1) !== 0, ptsUs, rotation)
  } else if (type === FRAME_AUDIO) {
    const dv = new DataView(payload.buffer, payload.byteOffset, payload.byteLength)
    const ptsUs = Number(dv.getBigUint64(0))
    await player.init()
    player.feed(ptsUs, payload.subarray(8))
  }
}

// ---------- control bar ----------

let hideTimer: number | undefined
function pokeBar(): void {
  bar.classList.add('show')
  document.body.classList.remove('hidecursor')
  clearTimeout(hideTimer)
  hideTimer = window.setTimeout(() => {
    bar.classList.remove('show')
    document.body.classList.add('hidecursor')
  }, 3000)
}

document.addEventListener('mousemove', pokeBar)
document.addEventListener('mousedown', pokeBar)
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && fullscreen) api.invoke('window:windowed')
})
document.addEventListener('dblclick', () => api.invoke('window:toggleFullscreen'))

function refreshButtons(): void {
  btnMute.textContent = muted ? '取消静音' : '静音'
  btnMute.classList.toggle('on', muted)
  btnMode.textContent = fullscreen ? '窗口模式' : '全屏模式'
  btnPin.style.display = fullscreen ? 'none' : ''
  btnPin.textContent = pinned ? '取消置顶' : '置顶'
  btnPin.classList.toggle('on', pinned)
}

btnMute.onclick = () => {
  muted = !muted
  player.setMuted(muted)
  refreshButtons()
}
btnMode.onclick = () => api.invoke('window:toggleFullscreen')
btnPin.onclick = () => {
  pinned = !pinned
  api.invoke('window:setPin', pinned)
  refreshButtons()
}
btnStop.onclick = () => api.invoke('session:stop')

// ---------- session events ----------

api.on('session:start', (info) => {
  senderName = String((info as { senderName: string }).senderName)
  $('#who').textContent = senderName
  overlay.classList.remove('show')
  vq.forEach((v) => v.frame.close())
  vq.length = 0
  shown?.close()
  shown = null
  firstVideoPts = -1
  player.reset()
  pipeline.reset()
  pokeBar()
})
api.on('session:reconnecting', () => overlay.classList.add('show'))
api.on('session:resume', () => overlay.classList.remove('show'))
api.on('window:state', (st) => {
  fullscreen = (st as { fullscreen: boolean }).fullscreen
  refreshButtons()
})
api.on('media', (type, payload) => {
  void onMedia(type as number, payload as Uint8Array)
})

refreshButtons()
renderLoop()
log('mirror window ready')
api.invoke('mirror:ready')
