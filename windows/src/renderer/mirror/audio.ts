// PCM s16le 48kHz stereo player backed by an AudioWorklet FIFO.
// Also exposes the audio playhead in stream pts (microseconds) so the video
// side can lip-sync to it.

const WORKLET_SOURCE = `
class PcmPlayer extends AudioWorkletProcessor {
  constructor() {
    super()
    this.q = []
    this.qLen = 0
    // pts (us) of the sample currently leaving the speakers; advances even
    // while underrun silence is emitted so the video clock stays sane
    this.nowPts = -1
    this.port.onmessage = (e) => {
      const m = e.data
      if (m.clear) {
        this.q = []
        this.qLen = 0
        this.nowPts = -1
        return
      }
      this.q.push(m)
      this.qLen += m.frames
      // cap the buffer at ~300ms: drop the oldest chunks on overflow
      while (this.qLen > 14400 && this.q.length > 1) {
        this.qLen -= this.q[0].frames
        this.q.shift()
      }
    }
  }
  process(_inputs, outputs) {
    const out = outputs[0]
    const n = out[0].length
    let i = 0
    while (i < n && this.qLen > 0) {
      const head = this.q[0]
      const take = Math.min(n - i, head.frames - head.off)
      for (let ch = 0; ch < out.length; ch++) {
        const src = head.data[Math.min(ch, head.data.length - 1)]
        out[ch].set(src.subarray(head.off, head.off + take), i)
      }
      head.off += take
      this.qLen -= take
      i += take
      this.nowPts = head.ptsUs + (head.off / 48000) * 1e6
      if (head.off >= head.frames) this.q.shift()
    }
    if (i < n) {
      for (const ch of out) ch.fill(0, i)
      if (this.nowPts >= 0) this.nowPts += ((n - i) / 48000) * 1e6
    }
    this.port.postMessage({ pts: this.nowPts, queued: this.qLen })
    return true
  }
}
registerProcessor('pcm-player', PcmPlayer)
`

export class PcmPlayer {
  private ctx: AudioContext | null = null
  private gain: GainNode | null = null
  private node: AudioWorkletNode | null = null
  private nowPts = -1
  private muted = false

  async init(): Promise<void> {
    if (this.ctx) return
    this.ctx = new AudioContext({ sampleRate: 48000, latencyHint: 'interactive' })
    const url = URL.createObjectURL(new Blob([WORKLET_SOURCE], { type: 'application/javascript' }))
    await this.ctx.audioWorklet.addModule(url)
    URL.revokeObjectURL(url)
    this.gain = this.ctx.createGain()
    this.node = new AudioWorkletNode(this.ctx, 'pcm-player', {
      numberOfInputs: 0,
      numberOfOutputs: 1,
      outputChannelCount: [2]
    })
    this.node.port.onmessage = (e) => {
      this.nowPts = e.data.pts
    }
    this.node.connect(this.gain).connect(this.ctx.destination)
    if (this.muted) this.gain.gain.value = 0
  }

  /** pts in microseconds, data = s16le interleaved stereo */
  feed(ptsUs: number, data: Uint8Array): void {
    if (!this.node) return
    const frames = data.byteLength >> 2
    // IPC payloads can sit at odd byte offsets; copy to a fresh aligned buffer
    const i16 = new Int16Array(data.slice().buffer, 0, frames * 2)
    const l = new Float32Array(frames)
    const r = new Float32Array(frames)
    for (let i = 0; i < frames; i++) {
      l[i] = i16[i * 2] / 32768
      r[i] = i16[i * 2 + 1] / 32768
    }
    this.node.port.postMessage({ data: [l, r], frames, off: 0, ptsUs }, [l.buffer, r.buffer])
  }

  /** pts of the sample currently leaving the speakers, or null before audio starts */
  playedPts(): number | null {
    return this.nowPts >= 0 ? this.nowPts : null
  }

  diag(): string {
    return `ctx=${this.ctx?.state} nowPts=${this.nowPts.toFixed(0)}`
  }

  setMuted(m: boolean): void {
    this.muted = m
    if (this.gain) this.gain.gain.value = m ? 0 : 1
  }

  reset(): void {
    this.nowPts = -1
    this.node?.port.postMessage({ clear: true })
  }

  close(): void {
    this.node?.disconnect()
    this.gain?.disconnect()
    this.ctx?.close()
    this.ctx = null
    this.node = null
    this.gain = null
  }
}
