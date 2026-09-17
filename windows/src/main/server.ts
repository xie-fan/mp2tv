import crypto from 'node:crypto'
import tls from 'node:tls'
import { EventEmitter } from 'node:events'
import { Framer, encodeControl, encodeFrame, FRAME_VIDEO, FRAME_AUDIO, FRAME_CONTROL, DEFAULT_PORT, PROTOCOL_VERSION, type Frame } from './protocol'
import { Pairing } from './pairing'
import { Store } from './store'
import { Identity } from './identity'
import { log } from './log'

const PING_INTERVAL_MS = 2000
const DEAD_TIMEOUT_MS = 6000
const RECONNECT_GRACE_MS = 10000

interface Session {
  socket: tls.TLSSocket | null
  senderId: string
  senderName: string
  lastSeen: number
  reconnectTimer: NodeJS.Timeout | null
}

interface ServerDeps {
  identity: Identity
  store: Store
  pairing: Pairing
  isLocked: () => boolean
  receiverName: string
}

export class ReceiverServer extends EventEmitter {
  port = 0
  private server: tls.Server | null = null
  private session: Session | null = null
  private pingTimer: NodeJS.Timeout | null = null
  private deadCheckTimer: NodeJS.Timeout | null = null
  private superseded = new Set<tls.TLSSocket>()

  constructor(private deps: ServerDeps) {
    super()
  }

  start(): Promise<number> {
    const { identity } = this.deps
    this.server = tls.createServer(
      {
        key: identity.keyPem,
        cert: identity.certPem,
        minVersion: 'TLSv1.3',
        maxVersion: 'TLSv1.3'
      },
      (sock) => this.onConnection(sock)
    )
    return new Promise((resolve, reject) => {
      const tryListen = (port: number): void => {
        this.server!.once('error', (err: NodeJS.ErrnoException) => {
          if (port !== 0 && err.code === 'EADDRINUSE') {
            tryListen(0)
          } else {
            reject(err)
          }
        })
        this.server!.listen(port, () => {
          this.port = (this.server!.address() as { port: number }).port
          log('TLS listening on port', this.port)
          resolve(this.port)
        })
      }
      tryListen(DEFAULT_PORT)
    })
  }

  private onConnection(sock: tls.TLSSocket): void {
    log('connection from', sock.remoteAddress)
    const framer = new Framer()
    sock.on('data', (d) => {
      let frames: Frame[]
      try {
        frames = framer.push(d)
      } catch (e) {
        log('frame error, closing', e)
        sock.destroy()
        return
      }
      for (const f of frames) this.onFrame(sock, f)
    })
    sock.on('error', (e) => log('socket error', e.message))
    sock.on('close', () => this.onSocketClose(sock))
  }

  private onFrame(sock: tls.TLSSocket, f: Frame): void {
    if (f.type === FRAME_CONTROL) {
      let msg: Record<string, unknown>
      try {
        msg = JSON.parse(f.payload.toString('utf8'))
      } catch {
        return
      }
      this.onControl(sock, msg)
      return
    }
    const s = this.session
    if (s && s.socket === sock) {
      s.lastSeen = Date.now()
      if (f.type === FRAME_VIDEO || f.type === FRAME_AUDIO) {
        this.emit('media', f)
      }
    }
  }

  private onControl(sock: tls.TLSSocket, msg: Record<string, unknown>): void {
    switch (msg.t) {
      case 'pair':
        return this.onPair(sock, msg)
      case 'hello':
        return this.onHello(sock, msg)
      case 'unpair':
        return this.onUnpair(sock, msg)
      case 'ping':
        this.touch(sock)
        return
      case 'stop':
        if (this.session?.socket === sock) {
          const reason = typeof msg.reason === 'string' ? msg.reason : 'user'
          log('session stopped by sender:', reason)
          this.endSession()
        }
        sock.end()
        return
    }
  }

  private touch(sock: tls.TLSSocket): void {
    if (this.session?.socket === sock) this.session.lastSeen = Date.now()
  }

  private onPair(sock: tls.TLSSocket, msg: Record<string, unknown>): void {
    const reply = (ok: boolean, extra: Record<string, unknown> = {}): void => {
      sock.end(encodeControl({ t: 'pairResult', ok, ...extra }))
    }
    if (msg.v !== PROTOCOL_VERSION) return reply(false, { reason: 'versionMismatch' })
    if (typeof msg.code !== 'string' || !this.deps.pairing.verify(msg.code)) {
      return reply(false, { reason: 'codeInvalid' })
    }
    const senderId = String(msg.senderId ?? '')
    if (!senderId) return reply(false, { reason: 'codeInvalid' })
    const token = crypto.randomBytes(32)
    this.deps.store.addDevice({
      senderId,
      name: String(msg.senderName ?? '手机'),
      platform: String(msg.platform ?? 'unknown'),
      tokenHash: crypto.createHash('sha256').update(token).digest('hex'),
      pairedAt: Date.now()
    })
    this.deps.pairing.markUsed()
    this.deps.pairing.rotate()
    this.emit('paired', String(msg.senderName ?? '手机'))
    this.emit('qrChanged')
    log('paired with', msg.senderName, senderId)
    reply(true, {
      receiverId: this.deps.identity.receiverId,
      receiverName: this.deps.receiverName,
      token: token.toString('base64url')
    })
  }

  private onHello(sock: tls.TLSSocket, msg: Record<string, unknown>): void {
    const reply = (ok: boolean, extra: Record<string, unknown> = {}): void => {
      const data = encodeControl({ t: 'helloResult', ok, ...extra })
      if (ok) sock.write(data)
      else sock.end(data)
    }
    if (msg.v !== PROTOCOL_VERSION) return reply(false, { reason: 'versionMismatch' })
    const senderId = String(msg.senderId ?? '')
    const dev = this.deps.store.verifyToken(senderId, String(msg.token ?? ''))
    if (!dev) return reply(false, { reason: 'notPaired' })
    if (this.deps.isLocked()) return reply(false, { reason: 'receiverLocked' })

    const cur = this.session
    if (cur && cur.senderId !== senderId) {
      return reply(false, { reason: 'busy', busyWith: cur.senderName })
    }
    if (cur) {
      // same senderId reconnecting: drop old socket, keep session
      if (cur.socket && cur.socket !== sock) {
        this.superseded.add(cur.socket)
        cur.socket.destroy()
      }
      if (cur.reconnectTimer) {
        clearTimeout(cur.reconnectTimer)
        cur.reconnectTimer = null
      }
      cur.socket = sock
      cur.lastSeen = Date.now()
      cur.senderName = String(msg.senderName ?? dev.name)
      reply(true)
      log('session resumed by', cur.senderName)
      this.emit('sessionResume')
      return
    }

    this.session = {
      socket: sock,
      senderId,
      senderName: String(msg.senderName ?? dev.name),
      lastSeen: Date.now(),
      reconnectTimer: null
    }
    if (dev.name !== this.session.senderName) {
      dev.name = this.session.senderName
    }
    reply(true)
    this.startTimers()
    log('session started by', this.session.senderName)
    this.emit('sessionStart', this.session.senderName)
  }

  private onUnpair(sock: tls.TLSSocket, msg: Record<string, unknown>): void {
    const senderId = String(msg.senderId ?? '')
    if (this.deps.store.verifyToken(senderId, String(msg.token ?? ''))) {
      this.deps.store.removeDevice(senderId)
      this.emit('devicesChanged')
      log('unpaired', senderId)
    }
    sock.end()
  }

  private onSocketClose(sock: tls.TLSSocket): void {
    if (this.superseded.delete(sock)) return
    const s = this.session
    if (!s || s.socket !== sock) return
    s.socket = null
    log('session socket closed, waiting for reconnect')
    this.emit('sessionReconnecting')
    s.reconnectTimer = setTimeout(() => {
      log('reconnect grace expired')
      this.endSession()
    }, RECONNECT_GRACE_MS)
  }

  private startTimers(): void {
    this.stopTimers()
    this.pingTimer = setInterval(() => {
      const s = this.session
      if (s?.socket) s.socket.write(encodeControl({ t: 'ping' }))
    }, PING_INTERVAL_MS)
    this.deadCheckTimer = setInterval(() => {
      const s = this.session
      if (s?.socket && Date.now() - s.lastSeen > DEAD_TIMEOUT_MS) {
        log('session timed out')
        s.socket.destroy()
      }
    }, 1000)
  }

  private stopTimers(): void {
    if (this.pingTimer) clearInterval(this.pingTimer)
    if (this.deadCheckTimer) clearInterval(this.deadCheckTimer)
    this.pingTimer = null
    this.deadCheckTimer = null
  }

  endSession(sendStop = false): void {
    const s = this.session
    if (!s) return
    this.session = null
    this.stopTimers()
    if (s.reconnectTimer) clearTimeout(s.reconnectTimer)
    if (s.socket) {
      this.superseded.add(s.socket)
      if (sendStop) s.socket.end(encodeControl({ t: 'stop', reason: 'user' }))
      else s.socket.destroy()
    }
    this.emit('sessionEnded')
  }

  sendCommand(action: string): void {
    this.session?.socket?.write(encodeControl({ t: 'command', action }))
  }

  removeDevice(senderId: string): void {
    this.deps.store.removeDevice(senderId)
    if (this.session?.senderId === senderId) this.endSession(true)
    this.emit('devicesChanged')
  }

  stop(): void {
    this.endSession(true)
    this.stopTimers()
    this.server?.close()
  }
}
