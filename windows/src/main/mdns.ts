import { Bonjour, type Service } from 'bonjour-service'
import { PROTOCOL_VERSION } from './protocol'

export class MdnsAdvertiser {
  private bonjour: Bonjour | null = null
  private service: Service | null = null

  start(name: string, port: number, receiverId: string): void {
    this.stop()
    this.bonjour = new Bonjour()
    this.service = this.bonjour.publish({
      name,
      type: 'mp2tv',
      protocol: 'tcp',
      port,
      txt: { id: receiverId, v: String(PROTOCOL_VERSION) }
    })
  }

  stop(): void {
    try {
      this.service?.stop()
    } catch {
      /* ignore */
    }
    this.service = null
    this.bonjour?.destroy()
    this.bonjour = null
  }
}
