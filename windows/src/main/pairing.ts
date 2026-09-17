import crypto from 'node:crypto'
import os from 'node:os'
import { PROTOCOL_VERSION } from './protocol'

const CODE_TTL_MS = 5 * 60 * 1000

export class Pairing {
  private code: Buffer = Buffer.alloc(0)
  private expiresAt = 0
  private used = false

  constructor() {
    this.rotate()
  }

  rotate(): void {
    this.code = crypto.randomBytes(16)
    this.expiresAt = Date.now() + CODE_TTL_MS
    this.used = false
  }

  isExpired(): boolean {
    return this.used || Date.now() > this.expiresAt
  }

  qrPayload(port: number, fingerprintB64url: string, receiverName: string): string {
    if (this.isExpired()) this.rotate()
    const hosts = localIPv4().join(',')
    const c = this.code.toString('base64url')
    return `mp2tv://pair?v=${PROTOCOL_VERSION}&h=${hosts}&p=${port}&fp=${fingerprintB64url}&c=${c}&n=${encodeURIComponent(receiverName)}`
  }

  verify(codeB64url: string): boolean {
    if (this.isExpired()) return false
    let code: Buffer
    try {
      code = Buffer.from(codeB64url, 'base64url')
    } catch {
      return false
    }
    return code.length === this.code.length && crypto.timingSafeEqual(code, this.code)
  }

  markUsed(): void {
    this.used = true
  }
}

export function localIPv4(): string[] {
  const out: string[] = []
  for (const list of Object.values(os.networkInterfaces())) {
    for (const ni of list ?? []) {
      if (ni.family === 'IPv4' && !ni.internal) out.push(ni.address)
    }
  }
  return out
}
