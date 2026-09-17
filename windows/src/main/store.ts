import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'

export interface PairedDevice {
  senderId: string
  name: string
  platform: string
  tokenHash: string
  pairedAt: number
}

export interface Settings {
  displayId: string | null
  autostart: boolean
}

interface StoreData {
  devices: PairedDevice[]
  settings: Settings
}

export class Store {
  private file: string
  private data: StoreData = { devices: [], settings: { displayId: null, autostart: true } }

  constructor(userDataDir: string) {
    this.file = path.join(userDataDir, 'store.json')
    try {
      if (fs.existsSync(this.file)) {
        const j = JSON.parse(fs.readFileSync(this.file, 'utf8'))
        this.data = { devices: j.devices ?? [], settings: { ...this.data.settings, ...j.settings } }
      }
    } catch {
      /* corrupt store -> start fresh */
    }
  }

  private save(): void {
    fs.writeFileSync(this.file, JSON.stringify(this.data, null, 2))
  }

  listDevices(): PairedDevice[] {
    return this.data.devices
  }

  addDevice(d: PairedDevice): void {
    this.data.devices = this.data.devices.filter((x) => x.senderId !== d.senderId)
    this.data.devices.push(d)
    this.save()
  }

  removeDevice(senderId: string): void {
    this.data.devices = this.data.devices.filter((x) => x.senderId !== senderId)
    this.save()
  }

  verifyToken(senderId: string, tokenB64: string): PairedDevice | null {
    const dev = this.data.devices.find((x) => x.senderId === senderId)
    if (!dev) return null
    let hash: string
    try {
      hash = crypto.createHash('sha256').update(Buffer.from(tokenB64, 'base64url')).digest('hex')
    } catch {
      return null
    }
    return hash === dev.tokenHash ? dev : null
  }

  getSettings(): Settings {
    return this.data.settings
  }

  setSettings(patch: Partial<Settings>): Settings {
    this.data.settings = { ...this.data.settings, ...patch }
    this.save()
    return this.data.settings
  }
}
