export const FRAME_CONTROL = 1
export const FRAME_VIDEO = 2
export const FRAME_AUDIO = 3
export const MAX_PAYLOAD = 8 * 1024 * 1024
export const PROTOCOL_VERSION = 1
export const DEFAULT_PORT = 46890

export interface Frame {
  type: number
  payload: Buffer
}

export class Framer {
  private buf: Buffer = Buffer.alloc(0)

  push(chunk: Buffer): Frame[] {
    this.buf = this.buf.length === 0 ? chunk : Buffer.concat([this.buf, chunk])
    const out: Frame[] = []
    while (this.buf.length >= 5) {
      const type = this.buf.readUInt8(0)
      const len = this.buf.readUInt32BE(1)
      if (len > MAX_PAYLOAD) throw new Error(`frame length ${len} over limit`)
      if (this.buf.length < 5 + len) break
      out.push({ type, payload: this.buf.subarray(5, 5 + len) })
      this.buf = this.buf.subarray(5 + len)
    }
    return out
  }
}

export function encodeFrame(type: number, payload: Buffer): Buffer {
  const head = Buffer.allocUnsafe(5)
  head.writeUInt8(type, 0)
  head.writeUInt32BE(payload.length, 1)
  return Buffer.concat([head, payload])
}

export function encodeControl(obj: Record<string, unknown>): Buffer {
  return encodeFrame(FRAME_CONTROL, Buffer.from(JSON.stringify(obj), 'utf8'))
}
