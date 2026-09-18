// H.264 Annex B helpers + SPS low-latency rewrite.
// WebCodecs hardware decoders buffer frames unless the SPS declares
// bitstream_restriction with max_num_reorder_frames == 0 (or no B-frames are
// ever signalled). We inspect each keyframe's SPS and patch it when needed.

export function splitAnnexB(au: Uint8Array): Uint8Array[] {
  const nals: Uint8Array[] = []
  let i = 0
  const n = au.length
  const starts: number[] = []
  while (i + 2 < n) {
    if (au[i] === 0 && au[i + 1] === 0 && (au[i + 2] === 1 || (au[i + 2] === 0 && i + 3 < n && au[i + 3] === 1))) {
      const sc = au[i + 2] === 1 ? 3 : 4
      starts.push(i + sc)
      i += sc
    } else {
      i++
    }
  }
  for (let k = 0; k < starts.length; k++) {
    const start = starts[k]
    let end = k + 1 < starts.length ? starts[k + 1] : n
    // trim the start code + a leading zero_byte belonging to next start code
    // (the last NAL has no following start code — its payload must stay intact)
    if (k + 1 < starts.length) {
      end -= end > start && au[end - 4] === 0 && au[end - 3] === 0 && au[end - 2] === 0 && au[end - 1] === 1 ? 4 : 3
    }
    if (end > start) nals.push(au.subarray(start, end))
  }
  return nals
}

export function joinAnnexB(nals: Uint8Array[]): Uint8Array {
  let total = 0
  for (const nal of nals) total += 4 + nal.length
  const out = new Uint8Array(total)
  let o = 0
  for (const nal of nals) {
    out.set([0, 0, 0, 1], o)
    o += 4
    out.set(nal, o)
    o += nal.length
  }
  return out
}

export function nalType(nal: Uint8Array): number {
  return nal.length > 0 ? nal[0] & 0x1f : -1
}

function ebspToRbsp(ebsp: Uint8Array): Uint8Array {
  const out = new Uint8Array(ebsp.length)
  let o = 0
  for (let i = 0; i < ebsp.length; i++) {
    if (i >= 2 && ebsp[i] === 3 && ebsp[i - 1] === 0 && ebsp[i - 2] === 0) continue
    out[o++] = ebsp[i]
  }
  return out.subarray(0, o)
}

function rbspToEbsp(rbsp: Uint8Array): Uint8Array {
  const out: number[] = []
  let zeros = 0
  for (const b of rbsp) {
    if (zeros >= 2 && b <= 3) {
      out.push(3)
      zeros = 0
    }
    out.push(b)
    zeros = b === 0 ? zeros + 1 : 0
  }
  return Uint8Array.from(out)
}

class BitReader {
  pos = 0
  constructor(private buf: Uint8Array) {}
  u(n: number): number {
    let v = 0
    for (let i = 0; i < n; i++) {
      if (this.pos >= this.buf.length * 8) throw new Error('SPS overrun')
      v = (v << 1) | ((this.buf[this.pos >> 3] >> (7 - (this.pos & 7))) & 1)
      this.pos++
    }
    return v
  }
  ue(): number {
    let zeros = 0
    while (this.u(1) === 0) zeros++
    return zeros === 0 ? 0 : (1 << zeros) - 1 + this.u(zeros)
  }
  se(): number {
    const k = this.ue()
    return k % 2 === 0 ? -(k / 2) : (k + 1) / 2
  }
  get exhausted(): boolean {
    return this.pos >= this.buf.length * 8
  }
}

class BitWriter {
  bytes: number[] = []
  private cur = 0
  private cnt = 0
  u(v: number, n: number): void {
    for (let i = n - 1; i >= 0; i--) {
      this.cur = (this.cur << 1) | ((v >> i) & 1)
      this.cnt++
      if (this.cnt === 8) {
        this.bytes.push(this.cur)
        this.cur = 0
        this.cnt = 0
      }
    }
  }
  ue(v: number): void {
    const c = v + 1
    const bits = Math.floor(Math.log2(c)) + 1
    this.u(0, bits - 1)
    this.u(c, bits)
  }
  copyFrom(r: BitReader, n: number): void {
    for (let i = 0; i < n; i++) this.u(r.u(1), 1)
  }
  /** rbsp_trailing_bits: stop bit + zero pad to byte boundary */
  trailing(): void {
    this.u(1, 1)
    while (this.cnt !== 0) this.u(0, 1)
  }
  toBytes(): Uint8Array {
    return Uint8Array.from(this.bytes)
  }
}

function skipScalingList(r: BitReader, size: number): void {
  let lastScale = 8
  let nextScale = 8
  for (let j = 0; j < size; j++) {
    if (nextScale !== 0) {
      const delta = r.se()
      nextScale = (lastScale + delta + 256) % 256
    }
    lastScale = nextScale === 0 ? lastScale : nextScale
  }
}

function skipHrd(r: BitReader): void {
  const cpbCnt = r.ue() + 1
  r.u(8) // bit_rate_scale + cpb_size_scale
  for (let i = 0; i < cpbCnt; i++) {
    r.ue()
    r.ue()
    r.u(1)
  }
  r.u(20) // delay lengths + time_offset_length
}

interface SpsInfo {
  /** bit position just after vui_parameters_present_flag */
  vuiFlagPos: number
  vuiPresent: boolean
  /** bit position of bitstream_restriction_flag (inside VUI), -1 if no VUI */
  brFlagPos: number
  brPresent: boolean
  maxNumReorderFrames: number
  maxDecFrameBuffering: number
  maxNumRefFrames: number
  /** true if bits after bitstream_restriction block are only rbsp_trailing_bits */
  cleanTail: boolean
}

function parseSps(rbsp: Uint8Array): SpsInfo {
  const r = new BitReader(rbsp)
  const profile = r.u(8)
  r.u(8) // constraint flags + reserved
  r.u(8) // level_idc
  r.ue() // seq_parameter_set_id
  if ([100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].includes(profile)) {
    const chroma = r.ue()
    if (chroma === 3) r.u(1)
    r.ue() // bit_depth_luma_minus8
    r.ue() // bit_depth_chroma_minus8
    r.u(1) // qpprime
    if (r.u(1)) {
      // seq_scaling_matrix_present
      const count = chroma !== 3 ? 8 : 12
      for (let i = 0; i < count; i++) {
        if (r.u(1)) skipScalingList(r, i < 6 ? 16 : 64)
      }
    }
  }
  r.ue() // log2_max_frame_num_minus4
  const poc = r.ue()
  if (poc === 0) r.ue()
  else if (poc === 1) {
    r.u(1)
    r.se()
    r.se()
    const n = r.ue()
    for (let i = 0; i < n; i++) r.se()
  }
  const maxNumRefFrames = r.ue()
  r.u(1) // gaps
  r.ue() // pic_width_in_mbs_minus1
  r.ue() // pic_height_in_map_units_minus1
  if (r.u(1) === 0) r.u(1) // frame_mbs_only -> mb_adaptive
  r.u(1) // direct_8x8
  if (r.u(1)) {
    r.ue()
    r.ue()
    r.ue()
    r.ue()
  }

  const info: SpsInfo = {
    vuiFlagPos: r.pos + 1,
    vuiPresent: false,
    brFlagPos: -1,
    brPresent: false,
    maxNumReorderFrames: -1,
    maxDecFrameBuffering: -1,
    maxNumRefFrames,
    cleanTail: true
  }

  if (r.u(1) === 0) return info
  info.vuiPresent = true

  if (r.u(1)) {
    const ar = r.u(8)
    if (ar === 255) r.u(32)
  }
  if (r.u(1)) r.u(1)
  if (r.u(1)) {
    r.u(4)
    if (r.u(1)) r.u(24)
  }
  if (r.u(1)) {
    r.ue()
    r.ue()
  }
  if (r.u(1)) {
    r.u(32)
    r.u(32)
    r.u(1)
  }
  const nalHrd = r.u(1)
  if (nalHrd) skipHrd(r)
  const vclHrd = r.u(1)
  if (vclHrd) skipHrd(r)
  if (nalHrd || vclHrd) r.u(1) // low_delay_hrd
  r.u(1) // pic_struct

  info.brFlagPos = r.pos
  if (r.u(1)) {
    info.brPresent = true
    r.u(1) // motion_vectors_over_pic_boundaries
    r.ue() // max_bytes_per_pic_denom
    r.ue() // max_bits_per_mb_denom
    r.ue() // log2_max_mv_length_horizontal
    r.ue() // log2_max_mv_length_vertical
    info.maxNumReorderFrames = r.ue()
    info.maxDecFrameBuffering = r.ue()
  }

  // what remains should only be rbsp_trailing_bits: a 1 followed by 0s
  if (!r.exhausted) {
    if (r.u(1) !== 1) info.cleanTail = false
    while (!r.exhausted) {
      if (r.u(1) !== 0) info.cleanTail = false
    }
  }
  return info
}

function writeBrFields(w: BitWriter, maxDecFrameBuffering: number): void {
  w.u(1, 1) // motion_vectors_over_pic_boundaries_flag
  w.ue(0) // max_bytes_per_pic_denom
  w.ue(0) // max_bits_per_mb_denom
  w.ue(0) // log2_max_mv_length_horizontal
  w.ue(0) // log2_max_mv_length_vertical
  w.ue(0) // max_num_reorder_frames
  w.ue(Math.max(1, maxDecFrameBuffering))
}

function writeMinimalVui(w: BitWriter, maxDecFrameBuffering: number): void {
  for (let i = 0; i < 8; i++) w.u(0, 1) // all *_present_flag = 0
  w.u(1, 1) // bitstream_restriction_flag
  writeBrFields(w, maxDecFrameBuffering)
}

/**
 * Returns the AU with a patched SPS when needed, or the original AU.
 * Returns null when the SPS cannot be patched safely (caller may fall back
 * to software decoding).
 */
export function ensureLowLatencySps(au: Uint8Array): { au: Uint8Array; spsKey: string; changed: boolean } | null {
  const nals = splitAnnexB(au)
  const spsIdx = nals.findIndex((nal) => nalType(nal) === 7)
  if (spsIdx < 0) return { au, spsKey: '', changed: false }
  const sps = nals[spsIdx]
  const spsKey = Array.from(sps.subarray(0, Math.min(sps.length, 48)))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('')
  const rbsp = ebspToRbsp(sps.subarray(1))

  let info: SpsInfo
  try {
    info = parseSps(rbsp)
  } catch {
    return null
  }
  if (!info.cleanTail) return null
  if (info.brPresent && info.maxNumReorderFrames === 0) {
    return { au, spsKey, changed: false }
  }

  const r = new BitReader(rbsp)
  const w = new BitWriter()
  if (!info.vuiPresent) {
    // copy up to and including the vui flag position, flip it to 1
    w.copyFrom(r, info.vuiFlagPos - 1)
    r.u(1)
    w.u(1, 1)
    writeMinimalVui(w, info.maxNumRefFrames)
  } else {
    // copy everything before bitstream_restriction_flag, then write flag + fields
    w.copyFrom(r, info.brFlagPos)
    w.u(1, 1)
    writeBrFields(w, info.brPresent ? info.maxDecFrameBuffering : info.maxNumRefFrames)
  }
  w.trailing()

  const ebsp = rbspToEbsp(w.toBytes())
  const newSps = new Uint8Array(1 + ebsp.length)
  newSps[0] = sps[0]
  newSps.set(ebsp, 1)
  const out = [...nals]
  out[spsIdx] = newSps
  return { au: joinAnnexB(out), spsKey, changed: true }
}

/** "avc1.PPCCLL" codec string from an SPS NAL */
export function codecString(sps: Uint8Array): string | null {
  if (sps.length < 4) return null
  const h = (b: number): string => b.toString(16).padStart(2, '0')
  return `avc1.${h(sps[1])}${h(sps[2])}${h(sps[3])}`
}
