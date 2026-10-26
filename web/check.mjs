// Checks web/mask.js on a mask with known measurements, made from the CC0 test head in Check/head.json.
// Run from the MaskFit folder:   node web/check.mjs
// Or print what it finds on a real mask:   node web/check.mjs mask.stl   (or mask.3mf)
import { readFileSync } from 'node:fs'
import { readMesh, readSTL, writeSTL, analyse, sizing } from './mask.js'

const show = r => `${r.type} · ${r.size.join(' × ')} mm · ${Object.entries(r.mask).map(([l, v]) => `${l} ${v ?? '–'}`).join('  ')}${r.problem ? `\n${r.problem}` : ''}`

if (process.argv[2]) {
  const buf = readFileSync(process.argv[2])
  console.time('read in')
  const { tris, note } = await readMesh(buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength))
  console.timeEnd('read in')
  console.time('analysed in')
  const r = analyse(tris)
  console.timeEnd('analysed in')
  console.log(`${tris.length / 9} triangles. ${note}`)
  console.log(show(r))
  process.exit(0)
}

const sub = (a, b) => a.map((v, i) => v - b[i])
const add = (a, b) => a.map((v, i) => v + b[i])
const mul = (a, s) => a.map(v => v * s)
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
const unit = a => mul(a, 1 / Math.hypot(...a))
const dot = (a, b) => a.reduce((s, v, i) => s + v * b[i], 0)

const head = JSON.parse(readFileSync(new URL('../Check/head.json', import.meta.url)))
const known = head.expected, padding = 4, shrink = 0.8
const V = head.vertices.map(p => mul(p, 1000)), T = head.triangles
const eyes = [head.leftEye, head.rightEye].map(p => mul(p, 1000))

// The mask's inside is the face moved out by the padding, with 24 mm eye holes.
const N = V.map(() => [0, 0, 0])
for (let t = 0; t < T.length; t += 3) {
  const n = cross(sub(V[T[t + 1]], V[T[t]]), sub(V[T[t + 2]], V[T[t]]))
  for (let k = 0; k < 3; k++) N[T[t + k]] = add(N[T[t + k]], n)
}
const outward = N.reduce((s, n, i) => s + (V[i][2] > 80 ? n[2] : 0), 0) > 0 ? 1 : -1
const inside = V.map((p, i) => add(p, mul(unit(N[i]), outward * padding)))

// Turned, shrunk and moved, as a downloaded file might be.
const [rx, ry, rz] = [0.7, -1.1, 2.3]
const turn = p => {
  let [x, y, z] = p
  ;[y, z] = [y * Math.cos(rx) - z * Math.sin(rx), y * Math.sin(rx) + z * Math.cos(rx)]
  ;[x, z] = [x * Math.cos(ry) + z * Math.sin(ry), -x * Math.sin(ry) + z * Math.cos(ry)]
  ;[x, y] = [x * Math.cos(rz) - y * Math.sin(rz), x * Math.sin(rz) + y * Math.cos(rz)]
  return [x, y, z]
}
const tris = []
for (let t = 0; t < T.length; t += 3) {
  // The head's eye sockets have an inner layer about 30 mm back that a mask wouldn't; it goes too.
  const g = mul(add(add(V[T[t]], V[T[t + 1]]), V[T[t + 2]]), 1 / 3), d = Math.min(...eyes.map(e => Math.hypot(g[0] - e[0], g[1] - e[1])))
  if (d < 12 || (d < 25 && g[2] < 45)) continue
  for (let k = 0; k < 3; k++) tris.push(...add(mul(turn(inside[T[t + k]]), shrink), [10, -20, 5]))
}
const mask = Float32Array.from(tris)

let failed = 0
const check = (name, ok, detail) => {
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${name.padEnd(34)} ${detail}`)
  if (!ok) failed++
}
const within = (v, lo, hi) => v !== null && v >= lo && v <= hi

const r = analyse(mask)
console.log(show(r))
const up = turn([0, 1, 0]), out = turn([0, 0, 1])
check('orientation', dot(r.frame.R[1], up) > 0.95 && dot(r.frame.R[2], out) > 0.9,
  `up · ${dot(r.frame.R[1], up).toFixed(3)}, out · ${dot(r.frame.R[2], out).toFixed(3)}`)
const at = l => r.mask[l] === null ? null : r.mask[l] / shrink
check('A eye holes', within(at('A'), known.A - 1, known.A + 1), `${at('A')?.toFixed(1)} vs ${known.A}`)
check('B inside width (+ 2 × padding)', within(at('B'), known.B + 2 * padding - 8, known.B + 2 * padding + 8), `${at('B')?.toFixed(1)} vs ${known.B} + ${2 * padding}`)
check('C bridge to chin (+ padding)', within(at('C'), known.C - 2, known.C + padding + 3), `${at('C')?.toFixed(1)} vs ${known.C} + ≤${padding}`)
check('D bridge to nose tip', within(at('D'), known.D - 3, known.D + 3), `${at('D')?.toFixed(1)} vs ${known.D}`)
check('E nose depth', within(at('E'), known.E - 3, known.E + 3), `${at('E')?.toFixed(1)} vs ${known.E}`)
check('type', r.type === 'wrap', r.type)

const s = sizing(known, r.mask, 'full', padding)
check('full-face scale', within(s.main, 122, 128), `${s.main}% · ${s.working}`)

// Scale the file by that, read it back: C on the mask should now be the face's C plus padding.
const scaled = readSTL(writeSTL(mask, s.main / 100))
const again = analyse(scaled)
check('C after scaling', within(again.mask.C, known.C + padding - 1.5, known.C + padding + 1.5), `${again.mask.C} vs ${known.C + padding}`)

// Same case and wording as Check/main.swift, so the two copies of the sizing rules stay in step.
const advice = sizing({ A: 64, B: 145, C: 119, D: 44, E: 33 }, { C: 116, A: 57 }, 'full', 4)
const swift = 'choose which to match: at 106% its eye spacing (A) is 3.6 mm narrower than you need; at 112.3% its face length (C) is 7.3 mm longer than you need.'
check('even-scale advice matches the app', advice.disagreement?.endsWith(swift) && advice.alternative?.scale === 112.3, advice.disagreement ?? 'none')

process.exit(failed ? 1 : 0)
