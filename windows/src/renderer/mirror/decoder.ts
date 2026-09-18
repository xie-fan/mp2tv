import { ensureLowLatencySps, splitAnnexB, nalType, codecString } from './sps'

export interface DecodedVideo {
  frame: VideoFrame
  ptsUs: number
  rotation: number
}

/**
 * WebCodecs H.264 pipeline. Annex B input, SPS patched for low latency,
 * reconfigures when SPS changes, falls back to software if hardware stalls.
 */
export class VideoPipeline {
  private decoder: VideoDecoder | null = null
  private spsKey = ''
  private codec = ''
  private hardware = true
  private waitingKeyframe = true
  private stallTimer: number | undefined
  private configured = false
  private outCount = 0
  private fedCount = 0

  onOutput: ((d: DecodedVideo) => void) | null = null
  onError: (() => void) | null = null
  onLog: ((msg: string) => void) | null = null

  private log(msg: string): void {
    this.onLog?.(msg)
  }

  private configure(): void {
    this.decoder?.close()
    this.decoder = new VideoDecoder({
      output: (frame) => {
        if (this.outCount++ === 0) this.log(`first decoded frame ${frame.displayWidth}x${frame.displayHeight}`)
        const rotation = this.rotations.get(frame.timestamp) ?? 0
        this.rotations.delete(frame.timestamp)
        this.onOutput?.({ frame, ptsUs: frame.timestamp, rotation })
        if (this.stallTimer !== undefined) {
          clearTimeout(this.stallTimer)
          this.stallTimer = undefined
        }
      },
      error: (e) => {
        this.log(`decoder error: ${e.message}`)
        this.configured = false
        this.waitingKeyframe = true
        // force reconfigure on the next keyframe — otherwise an unchanged
        // spsKey would skip configure() and freeze the picture permanently
        this.spsKey = ''
        this.onError?.()
      }
    })
    this.decoder.configure({
      codec: this.codec,
      optimizeForLatency: true,
      hardwareAcceleration: this.hardware ? 'prefer-hardware' : 'prefer-software'
    })
    this.configured = true
    this.waitingKeyframe = true
    this.log(`decoder configured ${this.codec} hw=${this.hardware}`)
  }

  private rotations = new Map<number, number>()

  feed(auIn: Uint8Array, key: boolean, ptsUs: number, rotation: number): void {
    const patched = ensureLowLatencySps(auIn)
    if (!patched) {
      this.log('SPS rewrite failed; falling back to software decode')
    }
    const au = patched?.au ?? auIn
    // inspect SPS on every AU — a key AU may not contain it and a
    // non-key AU may carry it ahead of the keyframe
    const sps = splitAnnexB(au).find((n) => nalType(n) === 7)
    if (sps) {
      const key2 = Array.from(sps.subarray(0, Math.min(sps.length, 48)))
        .map((b) => b.toString(16).padStart(2, '0'))
        .join('')
      if (key2 !== this.spsKey) {
        const codec = codecString(sps)
        if (codec) {
          this.spsKey = key2
          this.codec = codec
          // unpatchable SPS: hardware decoders would buffer frames — use software
          if (patched === null) this.hardware = false
          try {
            this.configure()
          } catch (e) {
            this.log(`decoder configure failed: ${e}`)
          }
        }
      }
    }
    if (!this.decoder || !this.configured || this.codec === '') {
      if (++this.fedCount <= 5) this.log(`skip AU: configured=${this.configured} codec='${this.codec}' key=${key}`)
      return
    }
    if (this.waitingKeyframe && !key) return
    if (key) this.waitingKeyframe = false
    if (++this.fedCount <= 5) this.log(`decode AU key=${key} len=${au.length}`)

    this.rotations.set(ptsUs, rotation)
    this.decoder.decode(
      new EncodedVideoChunk({
        type: key ? 'key' : 'delta',
        timestamp: ptsUs,
        data: au
      })
    )
    // detect stalled hardware decoder: frames go in, nothing comes out
    if (this.stallTimer === undefined && this.decoder.decodeQueueSize > 0) {
      this.stallTimer = window.setTimeout(() => {
        this.stallTimer = undefined
        if (this.hardware && this.decoder && this.decoder.decodeQueueSize > 4) {
          this.log('hardware decoder stalled, falling back to software')
          this.hardware = false
          this.configure()
          this.waitingKeyframe = true
          this.onError?.()
        }
      }, 800)
    }
  }

  reset(): void {
    this.log(`pipeline reset (state=${this.decoder?.state})`)
    this.waitingKeyframe = true
    if (this.decoder && this.decoder.state === 'configured') {
      try {
        this.decoder.reset()
        this.configured = false
      } catch {
        /* ignore */
      }
    }
  }

  close(): void {
    if (this.stallTimer !== undefined) clearTimeout(this.stallTimer)
    this.rotations.clear()
    try {
      this.decoder?.close()
    } catch {
      /* ignore */
    }
    this.decoder = null
    this.configured = false
  }
}
