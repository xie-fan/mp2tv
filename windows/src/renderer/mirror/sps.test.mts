import { test } from 'node:test'
import assert from 'node:assert/strict'
import { splitAnnexB, joinAnnexB, ensureLowLatencySps } from './sps.ts'

const sc4 = (...b: number[]) => new Uint8Array([0, 0, 0, 1, ...b])
const sc3 = (...b: number[]) => new Uint8Array([0, 0, 1, ...b])
const nalsOf = (au: Uint8Array) => splitAnnexB(au).map((n) => [...n])

test('splitAnnexB keeps the last NAL payload intact', () => {
  // two NALs; second ends with 0xdeadbeef — trailing bytes must not be eaten
  const au = new Uint8Array([...sc4(0x67, 1, 2, 3), ...sc4(0x65, 9, 8, 0xde, 0xad, 0xbe, 0xef)])
  const nals = splitAnnexB(au)
  assert.equal(nals.length, 2)
  assert.deepEqual([...nals[0]], [0x67, 1, 2, 3])
  assert.deepEqual([...nals[1]], [0x65, 9, 8, 0xde, 0xad, 0xbe, 0xef])
})

test('split->join->split preserves NAL contents', () => {
  // join always emits 4-byte start codes, so byte-identity only holds
  // at the NAL level, not for the raw AU
  const au = new Uint8Array([
    ...sc3(0x67, 10, 20),
    ...sc4(0x68, 30),
    ...sc3(0x65, 1, 2, 3, 4, 5)
  ])
  assert.deepEqual(nalsOf(joinAnnexB(splitAnnexB(au))), nalsOf(au))
})

test('mixed 3/4-byte start codes', () => {
  const au = new Uint8Array([...sc4(0x67, 1), ...sc3(0x41, 2, 3)])
  const nals = splitAnnexB(au)
  assert.equal(nals.length, 2)
  assert.deepEqual([...nals[1]], [0x41, 2, 3])
})

test('truncated SPS does not hang and is reported unpatchable', () => {
  // valid-looking SPS header that ends mid-field: parser must not loop forever
  const sps = sc4(0x67, 0x64, 0x00, 0x1f, 0xf4, 0x05, 0xa8) // profile+flags+level then garbage tail
  const au = new Uint8Array([...sps, ...sc4(0x65, 1, 2, 3)])
  const t0 = Date.now()
  const r = ensureLowLatencySps(au)
  assert.ok(Date.now() - t0 < 2000, 'ensureLowLatencySps hung')
  // either null (cannot patch) or a result — never a crash
  assert.ok(r === null || typeof r.spsKey === 'string')
})

// synthesize a minimal valid baseline-profile SPS without a VUI section —
// the shape typical hardware encoders emit and the patcher must handle
function makeSpsNoVui(): Uint8Array {
  const bytes: number[] = []
  let cur = 0
  let cnt = 0
  const u = (v: number, n: number) => {
    for (let i = n - 1; i >= 0; i--) {
      cur = (cur << 1) | ((v >> i) & 1)
      if (++cnt === 8) { bytes.push(cur); cur = 0; cnt = 0 }
    }
  }
  const ue = (v: number) => {
    const c = v + 1
    const bits = Math.floor(Math.log2(c)) + 1
    u(0, bits - 1)
    u(c, bits)
  }
  u(0x42, 8); u(0x00, 8); u(0x1f, 8) // profile baseline, level 3.1
  ue(0) // sps id
  ue(0) // log2_max_frame_num_minus4
  ue(0) // pic_order_cnt_type
  ue(0) // log2_max_pic_order_cnt_lsb_minus4
  ue(1) // max_num_ref_frames
  u(0, 1) // gaps_in_frame_num
  ue(59) // pic_width_in_mbs_minus1 -> 960
  ue(33) // pic_height_in_map_units_minus1 -> 544
  u(1, 1) // frame_mbs_only
  u(1, 1) // direct_8x8_inference
  u(0, 1) // frame_cropping
  u(0, 1) // vui_parameters_present <- the bit the patcher flips
  u(1, 1) // rbsp stop
  while (cnt) u(0, 1)
  return Uint8Array.from([0x67, ...bytes])
}

test('SPS without VUI gets patched with bitstream_restriction', () => {
  const sps = makeSpsNoVui()
  const au = new Uint8Array([...sc4(...sps), ...sc4(0x65, 0xaa, 0xbb)])
  const r = ensureLowLatencySps(au)
  assert.ok(r !== null, 'patchable SPS rejected')
  assert.equal(r.changed, true)
  assert.ok(r.spsKey.length > 0)
  const nals = splitAnnexB(r.au)
  assert.equal(nals.length, 2)
  assert.equal(nals[0][0] & 0x1f, 7)
  assert.equal(nals[1][0] & 0x1f, 5)
  // patched SPS must still parse: run it through ensureLowLatencySps again —
  // a proper BR section reads back as already-low-latency (changed=false)
  const again = ensureLowLatencySps(r.au)
  assert.ok(again !== null)
  assert.equal(again.changed, false)
})
