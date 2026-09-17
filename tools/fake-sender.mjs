// 假手机：用于在没有 Android 端之前联调电脑端。
//
//   node tools/fake-sender.mjs pair --qr "mp2tv://pair?..."      # 配对（或手动传参）
//   node tools/fake-sender.mjs stream                             # 用 tools/fake-device.json 发起投屏
//   node tools/fake-sender.mjs stream --video x.h264 --audio x.pcm
//   node tools/fake-sender.mjs unpair
//
// 生成测试素材：
//   ffmpeg -f lavfi -i testsrc2=size=960x540:rate=30 -t 20 -c:v libx264 -bf 0 -tune zerolatency -pix_fmt yuv420p -f h264 tools/test.h264
//   ffmpeg -f lavfi -i sine=frequency=440 -t 20 -f s16le -ac 2 -ar 48000 tools/test.pcm

import tls from 'node:tls'
import crypto from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import url from 'node:url'

const DIR = path.dirname(url.fileURLToPath(import.meta.url))
const DEVICE_FILE = process.argv.includes('--device')
  ? path.resolve(process.argv[process.argv.indexOf('--device') + 1])
  : path.join(DIR, 'fake-device.json')
const FRAME_CONTROL = 1
const FRAME_VIDEO = 2
const FRAME_AUDIO = 3

function arg(name) {
  const i = process.argv.indexOf(`--${name}`)
  return i >= 0 ? process.argv[i + 1] : undefined
}

function frame(type, payload) {
  const head = Buffer.allocUnsafe(5)
  head.writeUInt8(type, 0)
  head.writeUInt32BE(payload.length, 1)
  return Buffer.concat([head, payload])
}
const control = (obj) => frame(FRAME_CONTROL, Buffer.from(JSON.stringify(obj), 'utf8'))

class Framer {
  buf = Buffer.alloc(0)
  push(d) {
    this.buf = this.buf.length ? Buffer.concat([this.buf, d]) : d
    const out = []
    while (this.buf.length >= 5) {
      const len = this.buf.readUInt32BE(1)
      if (this.buf.length < 5 + len) break
      out.push({ type: this.buf.readUInt8(0), payload: this.buf.subarray(5, 5 + len) })
      this.buf = this.buf.subarray(5 + len)
    }
    return out
  }
}

function connect(host, port, fp) {
  return new Promise((resolve, reject) => {
    const sock = tls.connect({ host, port, rejectUnauthorized: false }, () => {
      const cert = sock.getPeerCertificate()
      const actual = crypto.createHash('sha256').update(cert.raw).digest()
      const want = Buffer.from(fp, fp.includes('-') || fp.includes('_') ? 'base64url' : 'hex')
      if (!actual.equals(want)) {
        sock.destroy()
        return reject(new Error(`fingerprint mismatch: got ${actual.toString('hex')}`))
      }
      resolve(sock)
    })
    sock.once('error', reject)
  })
}

function parseQr(qr) {
  const u = new URL(qr)
  return {
    hosts: u.searchParams.get('h').split(','),
    port: Number(u.searchParams.get('p')),
    fp: u.searchParams.get('fp'),
    code: u.searchParams.get('c')
  }
}

function loadDevice() {
  if (!fs.existsSync(DEVICE_FILE)) throw new Error('先 pair：node tools/fake-sender.mjs pair --qr "..."')
  return JSON.parse(fs.readFileSync(DEVICE_FILE, 'utf8'))
}

function onceControl(sock, pred) {
  return new Promise((resolve) => {
    const framer = new Framer()
    sock.on('data', (d) => {
      for (const f of framer.push(d)) {
        if (f.type === FRAME_CONTROL) {
          const m = JSON.parse(f.payload.toString('utf8'))
          if (pred(m)) resolve(m)
        }
      }
    })
  })
}

// ---- annex b AU grouping ----
function readUe(buf, bitPos) {
  let zeros = 0
  const bit = (p) => (buf[p >> 3] >> (7 - (p & 7))) & 1
  while (bit(bitPos++) === 0) zeros++
  let v = 0
  for (let i = 0; i < zeros; i++) v = (v << 1) | bit(bitPos++)
  return (1 << zeros) - 1 + v
}

function splitAus(file) {
  const data = fs.readFileSync(file)
  const nals = []
  const starts = []
  for (let i = 0; i + 3 < data.length; i++) {
    if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 1) {
      starts.push([i, 3])
      i += 3
    } else if (data[i] === 0 && data[i + 1] === 0 && data[i + 2] === 0 && data[i + 3] === 1) {
      starts.push([i, 4])
      i += 4
    }
  }
  for (let k = 0; k < starts.length; k++) {
    const [pos, sc] = starts[k]
    const end = k + 1 < starts.length ? starts[k + 1][0] : data.length
    nals.push(data.subarray(pos + sc, end))
  }
  const aus = []
  let cur = []
  let curKey = false
  let prefix = [] // SPS/PPS/SEI attach to the *next* AU
  const flush = () => {
    if (cur.length) aus.push({ data: Buffer.concat(cur.map((n) => Buffer.concat([Buffer.from([0, 0, 0, 1]), n]))), key: curKey })
    cur = []
    curKey = false
  }
  for (const nal of nals) {
    const type = nal[0] & 0x1f
    if (type === 9) {
      flush()
      continue
    }
    if (type >= 1 && type <= 5) {
      const firstMb = readUe(nal, 8)
      if (firstMb === 0 && cur.length) flush()
      if (type === 5) curKey = true
      if (prefix.length) {
        cur = [...prefix, ...cur]
        prefix = []
      }
      cur.push(nal)
    } else {
      prefix.push(nal)
    }
  }
  if (prefix.length) cur = [...prefix, ...cur]
  flush()
  return aus
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

async function cmdPair() {
  const qr = arg('qr')
  if (!qr) throw new Error('pair 需要 --qr')
  const { hosts, port, fp, code } = parseQr(qr)
  const senderId = arg('senderId') ?? crypto.randomUUID()
  const senderName = arg('name') ?? '假手机'
  let lastErr
  for (const host of hosts) {
    try {
      const sock = await connect(host, port, fp)
      const resultP = onceControl(sock, (m) => m.t === 'pairResult')
      sock.write(control({ t: 'pair', code, senderId, senderName, platform: 'android', v: 1 }))
      const res = await resultP
      console.log('pairResult:', res)
      if (res.ok) {
        fs.writeFileSync(
          DEVICE_FILE,
          JSON.stringify({ host, port, fp, senderId, token: res.token, receiverName: res.receiverName }, null, 2)
        )
        console.log('saved ->', DEVICE_FILE)
      }
      sock.end()
      return
    } catch (e) {
      lastErr = e
    }
  }
  throw lastErr
}

async function cmdStream() {
  const dev = loadDevice()
  const videoFile = arg('video') ?? path.join(DIR, 'test.h264')
  const audioFile = arg('audio') ?? path.join(DIR, 'test.pcm')
  const aus = splitAus(videoFile)
  const pcm = fs.existsSync(audioFile) ? fs.readFileSync(audioFile) : null
  console.log(`video AUs: ${aus.length}, audio: ${pcm ? pcm.length : 0} bytes`)

  const sock = await connect(dev.host, dev.port, dev.fp)
  const framer = new Framer()
  let helloed = false
  sock.on('data', (d) => {
    for (const f of framer.push(d)) {
      if (f.type !== FRAME_CONTROL) continue
      const m = JSON.parse(f.payload.toString('utf8'))
      if (m.t === 'helloResult') {
        console.log('helloResult:', m)
        helloed = m.ok === true
      } else if (m.t === 'command') {
        console.log('command:', m)
      } else console.log('msg:', m)
    }
  })
  sock.on('close', () => console.log('disconnected'))
  sock.write(control({ t: 'hello', senderId: dev.senderId, token: dev.token, senderName: '假手机', v: 1 }))
  while (!helloed) await sleep(20)

  const ping = setInterval(() => sock.write(control({ t: 'ping' })), 2000)

  // stream: 30fps video + 10ms pcm chunks, looped
  const AU_US = 33333
  let pts = 0
  let ai = 0
  let apts = 0 // audio clock, kept in lockstep with video pts
  const CHUNK = 1920 // 480 stereo frames = 10ms of s16le 48kHz
  while (!sock.destroyed) {
    for (const au of aus) {
      if (sock.destroyed) break
      const payload = Buffer.allocUnsafe(10 + au.data.length)
      payload.writeBigUInt64BE(BigInt(pts), 0)
      payload.writeUInt8(au.key ? 1 : 0, 8)
      payload.writeUInt8(0, 9)
      au.data.copy(payload, 10)
      sock.write(frame(FRAME_VIDEO, payload))
      while (pcm && apts < pts + AU_US) {
        const p = Buffer.allocUnsafe(8 + CHUNK)
        p.writeBigUInt64BE(BigInt(Math.round(apts)), 0)
        pcm.copy(p, 8, ai, ai + CHUNK)
        sock.write(frame(FRAME_AUDIO, p))
        ai += CHUNK
        if (ai >= pcm.length) ai = 0
        apts += (CHUNK / 4) * (1e6 / 48000)
      }
      pts += AU_US
      await sleep(AU_US / 1000)
    }
  }
  clearInterval(ping)
}

async function cmdUnpair() {
  const dev = loadDevice()
  const sock = await connect(dev.host, dev.port, dev.fp)
  sock.end(control({ t: 'unpair', senderId: dev.senderId, token: dev.token }))
  console.log('unpair sent')
  fs.rmSync(DEVICE_FILE, { force: true })
}

const cmd = process.argv[2]
const fn = { pair: cmdPair, stream: cmdStream, unpair: cmdUnpair }[cmd]
if (!fn) {
  console.log('usage: fake-sender.mjs pair|stream|unpair [--qr ...] [--video f] [--audio f] [--name n]')
  process.exit(1)
}
fn().catch((e) => {
  console.error(e)
  process.exit(1)
})
