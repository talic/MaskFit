// Mask analysis for the MaskFit web page. Reads a mask STL, finds on its inside the same landmarks the phone
// finds on the face (MaskFit/FaceMeasurer.swift), and works out the scale (MaskFit/MaskSizing.swift).
// The inside of a mask is a negative of a face, so seen from where the face sits it's a face-shaped depth map.
// Pure functions with no DOM, so web/check.mjs can run them in Node.
// Mask frame: millimetres, +x across, +y up, +z out of the face, like ARKit's face space.

// ---- Reading meshes

/** `{ tris, note }` from an STL or 3MF file's bytes. A 3MF's objects are placed as on the plate (its build
 *  transforms), and of several objects the one with the most triangles is used. */
export async function readMesh(buf) {
  if (new DataView(buf).getUint32(0, true) !== 0x04034b50) return { tris: readSTL(buf), note: '' }
  const zip = unzip(buf)
  const models = new Map()
  for (const name of zip.keys()) if (/\.model$/i.test(name)) models.set(name, parseModel(new TextDecoder().decode(await inflate(buf, zip.get(name)))))
  const rels = zip.has('_rels/.rels') ? new TextDecoder().decode(await inflate(buf, zip.get('_rels/.rels'))) : ''
  const root = models.get(rels.match(/Target="\/?([^"]+\.model)"/i)?.[1]) ?? models.get('3D/3dmodel.model')
  if (!root) throw new Error("This 3MF file has no 3D model in it.")
  // Bambu Studio keeps modifiers and negative parts (shapes cut out of the model) as parts too; only normal
  // parts are the mask. ponytail: PrusaSlicer marks them differently (Slic3r_PE_model.config); not handled.
  const skip = new Set()
  if (zip.has('Metadata/model_settings.config')) {
    const config = new TextDecoder().decode(await inflate(buf, zip.get('Metadata/model_settings.config')))
    for (const [, id, body] of config.matchAll(/<object id="([^"]+)"[^>]*>([\s\S]*?)<\/object>/g)) {
      for (const [, part, type] of body.matchAll(/<part id="([^"]+)" subtype="([^"]+)"/g)) if (type !== 'normal_part') skip.add(`${id}/${part}`)
    }
  }

  const meshes = root.items.map(item => {
    const out = []
    const emit = (model, id, place, depth) => {
      const obj = model.objects.get(id)
      if (!obj || depth > 16) return
      for (const t of obj.triangles) for (const v of t) out.push(...place(obj.vertices[v]))
      for (const c of obj.components) {
        if (skip.has(`${id}/${c.objectid}`)) continue
        const t = transform(c.transform)
        emit(c.path ? models.get(c.path) ?? model : model, c.objectid, p => place(t(p)), depth + 1)
      }
    }
    emit(root, item.objectid, transform(item.transform), 0)
    return out
  })
  const biggest = best(meshes, m => m.length)
  if (!biggest?.length) throw new Error("This 3MF file has no triangles in it.")
  return {
    tris: Float32Array.from(biggest),
    note: meshes.length > 1 ? `Used the largest of the ${meshes.length} objects in this file. ` : '',
  }
}

/** A zip's entries by name: compression method, compressed size and where the local header starts. */
function unzip(buf) {
  const dv = new DataView(buf), bytes = new Uint8Array(buf)
  let end = buf.byteLength - 22
  while (end >= 0 && dv.getUint32(end, true) !== 0x06054b50) end--
  if (end < 0) throw new Error("This doesn't look like a 3MF file.")
  let p = dv.getUint32(end + 16, true), n = dv.getUint16(end + 10, true)
  if (p === 0xffffffff && dv.getUint32(end - 20, true) === 0x07064b50) {
    // Zip64: a locator just before the end record points to a bigger end record with 64-bit fields.
    const z = Number(dv.getBigUint64(end - 12, true))
    n = Number(dv.getBigUint64(z + 32, true)); p = Number(dv.getBigUint64(z + 48, true))
  }
  const files = new Map()
  for (let i = 0; i < n; i++) {
    const nameLength = dv.getUint16(p + 28, true), extraLength = dv.getUint16(p + 30, true)
    const entry = { method: dv.getUint16(p + 10, true), size: dv.getUint32(p + 20, true), local: dv.getUint32(p + 42, true) }
    // Zip64 keeps sizes and offsets that don't fit in 32 bits in an extra field, in this order.
    for (let x = p + 46 + nameLength; x < p + 46 + nameLength + extraLength; x += 4 + dv.getUint16(x + 2, true)) {
      if (dv.getUint16(x, true) !== 1) continue
      let at = x + 4
      if (dv.getUint32(p + 24, true) === 0xffffffff) at += 8
      if (entry.size === 0xffffffff) { entry.size = Number(dv.getBigUint64(at, true)); at += 8 }
      if (entry.local === 0xffffffff) entry.local = Number(dv.getBigUint64(at, true))
    }
    files.set(new TextDecoder().decode(bytes.subarray(p + 46, p + 46 + nameLength)).replace(/^\//, ''), entry)
    p += 46 + nameLength + extraLength + dv.getUint16(p + 32, true)
  }
  return files
}

async function inflate(buf, { method, size, local }) {
  const dv = new DataView(buf), start = local + 30 + dv.getUint16(local + 26, true) + dv.getUint16(local + 28, true)
  const data = new Uint8Array(buf, start, size)
  if (method === 0) return data
  if (method !== 8) throw new Error('This 3MF file uses a compression this page can’t read.')
  return new Uint8Array(await new Response(new Blob([data]).stream().pipeThrough(new DecompressionStream('deflate-raw'))).arrayBuffer())
}

const attr = (tag, name) => tag.match(new RegExp(`(?:^|\\s)${name}="([^"]*)"`))?.[1]

/** A 3MF model file's objects (mesh and/or components) and build items, with vertices in millimetres. */
function parseModel(xml) {
  const unit = { micron: 0.001, millimeter: 1, centimeter: 10, inch: 25.4, foot: 304.8, meter: 1000 }[attr(xml.match(/<model\b[^>]*>/)?.[0] ?? '', 'unit')] ?? 1
  const objects = new Map()
  for (const [, head, body] of xml.matchAll(/<object\b([^>]*)>([\s\S]*?)<\/object>/g)) {
    const vertices = [], triangles = [], components = []
    for (const [tag] of body.matchAll(/<vertex\b[^>]*>/g)) vertices.push(['x', 'y', 'z'].map(k => unit * attr(tag, k)))
    for (const [tag] of body.matchAll(/<triangle\b[^>]*>/g)) triangles.push(['v1', 'v2', 'v3'].map(k => +attr(tag, k)))
    for (const [tag] of body.matchAll(/<component\b[^>]*>/g)) {
      components.push({ objectid: attr(tag, 'objectid'), transform: attr(tag, 'transform'), path: attr(tag, 'p:path')?.replace(/^\//, '') })
    }
    objects.set(attr(head, 'id'), { vertices, triangles, components })
  }
  const items = [...xml.matchAll(/<item\b[^>]*>/g)].map(([tag]) => ({ objectid: attr(tag, 'objectid'), transform: attr(tag, 'transform') }))
  return { objects, items }
}

/** A 3MF transform, "m00 m01 m02 m10 m11 m12 m20 m21 m22 m30 m31 m32", applied to row-vector points. */
function transform(text) {
  if (!text) return p => p
  const m = text.trim().split(/\s+/).map(Number)
  return ([x, y, z]) => [x * m[0] + y * m[3] + z * m[6] + m[9], x * m[1] + y * m[4] + z * m[7] + m[10], x * m[2] + y * m[5] + z * m[8] + m[11]]
}

/** Triangles as a flat Float32Array, 9 numbers each, from a binary or ASCII STL. */
export function readSTL(buf) {
  const dv = new DataView(buf)
  if (buf.byteLength >= 84) {
    const n = dv.getUint32(80, true)
    if (84 + 50 * n === buf.byteLength) {
      const out = new Float32Array(n * 9)
      for (let t = 0; t < n; t++) for (let k = 0; k < 9; k++) out[t * 9 + k] = dv.getFloat32(96 + t * 50 + k * 4, true)
      return out
    }
  }
  const text = new TextDecoder().decode(buf)
  const out = []
  for (const m of text.matchAll(/vertex\s+(\S+)\s+(\S+)\s+(\S+)/g)) out.push(+m[1], +m[2], +m[3])
  if (!out.length || out.length % 9 || out.some(Number.isNaN)) throw new Error("This doesn't look like an STL file.")
  return Float32Array.from(out)
}

/** Binary STL of the triangles scaled evenly by `scale`, so the mask keeps its proportions. */
export function writeSTL(tris, scale = 1) {
  const n = tris.length / 9, buf = new ArrayBuffer(84 + 50 * n), dv = new DataView(buf), p = new Float32Array(9)
  dv.setUint32(80, n, true)
  for (let t = 0; t < n; t++) {
    for (let k = 0; k < 9; k++) p[k] = tris[t * 9 + k] * scale
    const nrm = norm(cross([p[3] - p[0], p[4] - p[1], p[5] - p[2]], [p[6] - p[0], p[7] - p[1], p[8] - p[2]]))
    const o = 84 + t * 50
    for (let k = 0; k < 3; k++) dv.setFloat32(o + k * 4, nrm[k], true)
    for (let k = 0; k < 9; k++) dv.setFloat32(o + 12 + k * 4, p[k], true)
  }
  return buf
}

// ---- Vectors

const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]
const mul = (a, s) => [a[0] * s, a[1] * s, a[2] * s]
const add = (a, b) => [a[0] + b[0], a[1] + b[1], a[2] + b[2]]
const norm = a => mul(a, 1 / (Math.hypot(...a) || 1))
const median = v => (v.length ? [...v].sort((a, b) => a - b)[v.length >> 1] : NaN)
const best = (v, key, sign = 1) => v.reduce((b, p) => (b === null || sign * key(p) > sign * key(b) ? p : b), null)

/** Eigenvectors of a symmetric 3×3 matrix by Jacobi rotations, smallest eigenvalue first. */
function eigen(m) {
  const a = m.map(r => [...r]), v = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
  for (let sweep = 0; sweep < 30; sweep++) {
    for (const [p, q] of [[0, 1], [0, 2], [1, 2]]) {
      if (Math.abs(a[p][q]) < 1e-12) continue
      const th = (a[q][q] - a[p][p]) / (2 * a[p][q])
      const t = (th >= 0 ? 1 : -1) / (Math.abs(th) + Math.hypot(th, 1)), c = 1 / Math.hypot(t, 1), s = t * c
      for (let k = 0; k < 3; k++) {
        for (const x of [a, v]) { const xp = x[k][p], xq = x[k][q]; x[k][p] = c * xp - s * xq; x[k][q] = s * xp + c * xq }
      }
      for (let k = 0; k < 3; k++) { const ap = a[p][k], aq = a[q][k]; a[p][k] = c * ap - s * aq; a[q][k] = s * ap + c * aq }
    }
  }
  return [0, 1, 2].map(i => ({ value: a[i][i], vector: [v[0][i], v[1][i], v[2][i]] })).sort((x, y) => x.value - y.value)
}

// ---- Frame and depth maps

/** Frame: `R` holds the mask's x, y and z axes in file coordinates, `c` its centre. */
const toModel = (fr, p) => add(fr.c, add(mul(fr.R[0], p[0]), add(mul(fr.R[1], p[1]), mul(fr.R[2], p[2]))))
const roll = (fr, angle) => {
  const [ex, ey, ez] = fr.R, c = Math.cos(angle), s = Math.sin(angle)
  return { c: fr.c, R: [add(mul(ex, c), mul(ey, s)), add(mul(ex, -s), mul(ey, c)), ez] }
}
const turnAround = fr => ({ c: fr.c, R: [mul(fr.R[0], -1), fr.R[1], mul(fr.R[2], -1)] })

function toFrame(tris, fr) {
  const out = new Float32Array(tris.length), [ex, ey, ez] = fr.R, [cx, cy, cz] = fr.c
  for (let i = 0; i < tris.length; i += 3) {
    const x = tris[i] - cx, y = tris[i + 1] - cy, z = tris[i + 2] - cz
    out[i] = x * ex[0] + y * ex[1] + z * ex[2]
    out[i + 1] = x * ey[0] + y * ey[1] + z * ey[2]
    out[i + 2] = x * ez[0] + y * ez[1] + z * ez[2]
  }
  return out
}

/** Depth maps looking along z, 500 pixels across the mask's larger side: `near` is the first surface seen from
 *  behind (the inside, where the face sits), `far` the first seen from the front. */
function raster(f) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity
  for (let i = 0; i < f.length; i += 3) {
    x0 = Math.min(x0, f[i]); x1 = Math.max(x1, f[i]); y0 = Math.min(y0, f[i + 1]); y1 = Math.max(y1, f[i + 1])
  }
  const px = Math.max(x1 - x0, y1 - y0) / 500
  x0 -= 2 * px; y0 -= 2 * px
  const w = Math.ceil((x1 - x0) / px) + 3, h = Math.ceil((y1 - y0) / px) + 3
  const near = new Float32Array(w * h).fill(Infinity), far = new Float32Array(w * h).fill(-Infinity)
  const put = (i, z) => { if (z < near[i]) near[i] = z; if (z > far[i]) far[i] = z }
  for (let o = 0; o < f.length; o += 9) {
    const ax = (f[o] - x0) / px, ay = (f[o + 1] - y0) / px, az = f[o + 2]
    const bx = (f[o + 3] - x0) / px, by = (f[o + 4] - y0) / px, bz = f[o + 5]
    const cx = (f[o + 6] - x0) / px, cy = (f[o + 7] - y0) / px, cz = f[o + 8]
    // Corners too, so triangles smaller than a pixel still mark it.
    put(Math.floor(ay) * w + Math.floor(ax), az); put(Math.floor(by) * w + Math.floor(bx), bz); put(Math.floor(cy) * w + Math.floor(cx), cz)
    const d = (bx - ax) * (cy - ay) - (cx - ax) * (by - ay)
    if (Math.abs(d) < 1e-12) continue
    const i0 = Math.ceil(Math.min(ax, bx, cx) - 0.5), i1 = Math.floor(Math.max(ax, bx, cx) - 0.5)
    const j0 = Math.ceil(Math.min(ay, by, cy) - 0.5), j1 = Math.floor(Math.max(ay, by, cy) - 0.5)
    for (let j = j0; j <= j1; j++) {
      const py = j + 0.5
      for (let i = i0; i <= i1; i++) {
        const qx = i + 0.5
        const wa = ((bx - qx) * (cy - py) - (cx - qx) * (by - py)) / d
        const wb = ((cx - qx) * (ay - py) - (ax - qx) * (cy - py)) / d
        if (wa < -1e-6 || wb < -1e-6 || wa + wb > 1 + 1e-6) continue
        put(j * w + i, wa * az + wb * bz + (1 - wa - wb) * cz)
      }
    }
  }
  return { w, h, x0, y0, px, near, far }
}

/** Calls `fn(x, y, near, far)` for every pixel the mask covers, in mask millimetres. */
function eachPixel(r, fn) {
  for (let j = 0; j < r.h; j++) for (let i = 0; i < r.w; i++) {
    const k = j * r.w + i
    if (r.near[k] !== Infinity) fn(r.x0 + (i + 0.5) * r.px, r.y0 + (j + 0.5) * r.px, r.near[k], r.far[k])
  }
}

/** Positive when +z points out of the face: the inside is hollow, so its middle is further from a viewer behind
 *  the mask than its edges are, and the front's middle (the nose) is nearer one in front. */
function outwardScore(r) {
  const mid = { near: [], far: [] }, edge = { near: [], far: [] }
  for (let j = 0; j < r.h; j++) for (let i = 0; i < r.w; i++) {
    const k = j * r.w + i, u = Math.abs(i / r.w - 0.5), v = Math.abs(j / r.h - 0.5)
    if (r.near[k] === Infinity) continue
    const into = u < 0.2 && v < 0.2 ? mid : u > 0.4 || v > 0.4 ? edge : null
    if (into) { into.near.push(r.near[k]); into.far.push(r.far[k]) }
  }
  const score = median(mid.near) - median(edge.near) + median(mid.far) - median(edge.far)
  return Number.isNaN(score) ? 0 : score
}

/** Gaps in the mask that don't reach its outline: eye holes, nostrils, mouth. */
function holes(r) {
  const { w, h, near } = r, mark = new Int32Array(w * h), out = []
  const fill = (start, id) => {
    const stack = [start], hole = { area: 0, x: 0, y: 0 }
    mark[start] = id
    while (stack.length) {
      const k = stack.pop(), i = k % w, j = (k - i) / w
      hole.area++; hole.x += i; hole.y += j
      for (const n of [i > 0 && k - 1, i < w - 1 && k + 1, j > 0 && k - w, j < h - 1 && k + w]) {
        if (n !== false && !mark[n] && near[n] === Infinity) { mark[n] = id; stack.push(n) }
      }
    }
    return hole
  }
  for (let k = 0; k < w * h; k++) {
    const i = k % w, j = (k - i) / w
    if ((i === 0 || j === 0 || i === w - 1 || j === h - 1) && !mark[k] && near[k] === Infinity) fill(k, -1)
  }
  for (let k = 0; k < w * h; k++) {
    if (mark[k] || near[k] !== Infinity) continue
    const hole = fill(k, out.length + 1)
    if (hole.area >= 4) {
      out.push({ area: hole.area * r.px ** 2, x: r.x0 + (hole.x / hole.area + 0.5) * r.px, y: r.y0 + (hole.y / hole.area + 0.5) * r.px })
    }
  }
  return out
}

/** The eye holes: the largest pair of holes of similar size whose midpoint sits on the mask's middle. */
function eyePair(r, hs) {
  let cx = 0, cy = 0, n = 0
  eachPixel(r, (x, y) => { cx += x; cy += y; n++ })
  cx /= n; cy /= n
  const size = Math.max(r.w, r.h) * r.px
  let pair = null
  for (let i = 0; i < hs.length; i++) for (let j = i + 1; j < hs.length; j++) {
    const a = hs[i], b = hs[j], d = Math.hypot(b.x - a.x, b.y - a.y)
    if (Math.min(a.area, b.area) < 0.5 * Math.max(a.area, b.area) || d < 0.1 * size || d > 0.7 * size) continue
    const along = (((a.x + b.x) / 2 - cx) * (b.x - a.x) + ((a.y + b.y) / 2 - cy) * (b.y - a.y)) / d
    if (Math.abs(along) > 0.15 * d) continue
    if (!pair || Math.min(a.area, b.area) > Math.min(pair[0].area, pair[1].area)) pair = a.x <= b.x ? [a, b] : [b, a]
  }
  return pair
}

/** True when the nose, the inside's furthest-forward spot near the midline, is above the eyes. */
function noseAbove(r, [a, b]) {
  const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2, d = Math.hypot(b.x - a.x, b.y - a.y)
  const z = { near: [-Infinity, -Infinity], far: [-Infinity, -Infinity] }
  eachPixel(r, (x, y, near, far) => {
    const dy = y - my
    if (Math.abs(x - mx) > 0.1 * d || Math.abs(dy) < 0.2 * d || Math.abs(dy) > 1.3 * d) return
    const side = dy > 0 ? 0 : 1
    z.near[side] = Math.max(z.near[side], near); z.far[side] = Math.max(z.far[side], far)
  })
  // The inside's nose pocket decides; a mask with a flat back has none, so then the front's nose does.
  const use = Math.abs(z.near[0] - z.near[1]) > 0.05 * d ? z.near : z.far
  return use[0] > use[1]
}

// ---- Landmarks

/** Nose bridge: the deepest point of the side profile between two heights, from the median depth per millimetre
 *  averaged over ±2 mm (FaceMeasurer.deepest). */
function deepest(mid, x, lo, hi) {
  const bins = new Map()
  for (const p of mid) if (p[1] > lo && p[1] < hi) { const k = Math.floor(p[1] - lo); if (!bins.has(k)) bins.set(k, []); bins.get(k).push(p[2]) }
  const profile = [...bins].map(([y, zs]) => ({ y, z: median(zs) }))
  const smooth = profile.map(b => {
    const near = profile.filter(o => Math.abs(o.y - b.y) <= 2)
    return { y: b.y, z: near.reduce((s, o) => s + o.z, 0) / near.length }
  })
  const low = best(smooth, o => o.z, -1)
  return low && [x, lo + low.y + 0.5, low.z]
}

/** FaceMeasurer.measure on the inside surface, in face-sized millimetres; each landmark separately. `pts` are the
 *  inside's depth-map points; `f` the triangles in the mask frame and `k` the face-size factor, for the side
 *  walls, which the depth map sees edge-on. */
function landmarks(pts, f, k, eyes) {
  const mid = pts.filter(p => Math.abs(p[0] - eyes.x) < 3)
  const tip = best(mid.filter(p => p[1] > eyes.y - 80 && p[1] < eyes.y - 10), p => p[2])
  const bridge = deepest(mid, eyes.x, eyes.y - 12, eyes.y + 25)
  // Front of the chin, then its lowest point within 22 mm behind that, which keeps the jaw underside out.
  const chinFront = tip && best(mid.filter(p => p[1] < tip[1] - 55), p => p[2])
  const chin = chinFront && best(mid.filter(p => p[1] < chinFront[1] && p[2] > chinFront[2] - 22), p => p[1], -1)
  // Cheek surface 35 mm either side of the nose, at nose-tip height; front-most point wins.
  const cheekZ = side => {
    const sx = eyes.x + side * 35, sy = tip[1] + 5
    const near = pts.filter(p => Math.hypot(p[0] - sx, p[1] - sy) < 6)
    return near.length ? Math.max(...near.map(p => p[2])) : null
  }
  const cheeks = tip && [cheekZ(1), cheekZ(-1)]
  const e = cheeks && cheeks[0] !== null && cheeks[1] !== null ? tip[2] - (cheeks[0] + cheeks[1]) / 2 : null

  // Room for the cheekbones: in the face's band (5–35 mm below the eyes, up to 45 mm behind them), per 1 mm of
  // depth, the gap between the innermost points of the left and right walls; the widest gap counts. The mask
  // reaches the cheekbones only if both walls go at least 15 mm behind the eyes.
  const bins = new Map()
  for (let i = 0; i < f.length; i += 3) {
    const p = [k * f[i], k * f[i + 1], k * f[i + 2]], dx = p[0] - eyes.x
    if (p[1] > eyes.y - 5 || p[1] < eyes.y - 35 || p[2] < eyes.z - 45 || p[2] > eyes.z || Math.abs(dx) < 25) continue
    const depth = Math.floor(eyes.z - p[2])
    if (!bins.has(depth)) bins.set(depth, { l: null, r: null })
    const bin = bins.get(depth)
    if (dx > 0 && (!bin.l || p[0] < bin.l[0])) bin.l = p
    if (dx < 0 && (!bin.r || p[0] > bin.r[0])) bin.r = p
  }
  const walls = [...bins].filter(([, b]) => b.l && b.r)
  const widest = best(walls, ([, b]) => b.l[0] - b.r[0])
  const reaches = walls.some(([depth]) => depth >= 15)

  return {
    tip, bridge, chin, cheeks, reaches,
    A: null,
    B: widest && reaches ? { value: widest[1].l[0] - widest[1].r[0], line: [widest[1].l, widest[1].r] } : null,
    C: bridge && chin ? { value: Math.hypot(...bridge.map((v, i) => v - chin[i])), line: [bridge, chin] } : null,
    D: bridge && tip ? { value: Math.hypot(...bridge.map((v, i) => v - tip[i])), line: [bridge, tip] } : null,
    E: e !== null ? { value: e, line: [tip, [tip[0], tip[1], tip[2] - e]] } : null,
  }
}

/** Everything the page shows about a mask. `flip` swaps front and back, `turns` adds quarter turns, for when the
 *  automatic orientation is wrong. Values are in the file's units (mm), lines in file coordinates. */
export function analyse(tris, { flip = false, turns = 0 } = {}) {
  // Area-weighted centre and spread; the least spread is front to back, the most usually top to bottom.
  let total = 0
  const c = [0, 0, 0], s = [[0, 0, 0], [0, 0, 0], [0, 0, 0]]
  for (let o = 0; o < tris.length; o += 9) {
    const a = [tris[o], tris[o + 1], tris[o + 2]], b = [tris[o + 3], tris[o + 4], tris[o + 5]], d = [tris[o + 6], tris[o + 7], tris[o + 8]]
    const area = Math.hypot(...cross([b[0] - a[0], b[1] - a[1], b[2] - a[2]], [d[0] - a[0], d[1] - a[1], d[2] - a[2]])) / 2
    const g = [(a[0] + b[0] + d[0]) / 3, (a[1] + b[1] + d[1]) / 3, (a[2] + b[2] + d[2]) / 3]
    total += area
    for (let i = 0; i < 3; i++) { c[i] += area * g[i]; for (let j = 0; j < 3; j++) s[i][j] += area * g[i] * g[j] }
  }
  for (let i = 0; i < 3; i++) c[i] /= total
  const cov = s.map((row, i) => row.map((v, j) => v / total - c[i] * c[j]))
  const [least, , most] = eigen(cov)
  let frame = { c, R: [cross(most.vector, least.vector), most.vector, least.vector] }

  let r = raster(toFrame(tris, frame))
  if (outwardScore(r) < 0 !== flip) r = raster(toFrame(tris, (frame = turnAround(frame))))
  let pair = eyePair(r, holes(r))
  if (pair) {
    frame = roll(frame, Math.atan2(pair[1].y - pair[0].y, pair[1].x - pair[0].x))
    r = raster(toFrame(tris, frame))
    pair = eyePair(r, holes(r))
    if (pair && noseAbove(r, pair)) frame = roll(frame, Math.PI)
  }
  if (turns % 4) frame = roll(frame, (turns * Math.PI) / 2)
  const f = toFrame(tris, frame)
  r = raster(f)
  pair = eyePair(r, holes(r))

  const lo = [Infinity, Infinity, Infinity], hi = [-Infinity, -Infinity, -Infinity]
  for (let i = 0; i < f.length; i++) { lo[i % 3] = Math.min(lo[i % 3], f[i]); hi[i % 3] = Math.max(hi[i % 3], f[i]) }
  const result = {
    frame,
    size: hi.map((v, i) => round1(v - lo[i])),
    mask: { A: null, B: null, C: null, D: null, E: null },
    lines: {},
    eyeHoles: null,
    type: 'full',
    problem: null,
  }
  if (!pair) {
    result.problem = "Couldn't find two eye holes, so the mask can't be measured automatically. Type its measurements instead."
    return result
  }

  // Scale to face size so FaceMeasurer's millimetre limits apply however big the file is.
  const a = Math.hypot(pair[1].x - pair[0].x, pair[1].y - pair[0].y), k = 63 / a
  const rim = pair.map(h => median(collect(r, (x, y) => Math.hypot(x - h.x, y - h.y) < 1.5 * Math.sqrt(h.area / Math.PI))))
  const eyes = { x: k * (pair[0].x + pair[1].x) / 2, y: k * (pair[0].y + pair[1].y) / 2, z: k * (rim[0] + rim[1]) / 2 - 12 }
  const pts = []
  eachPixel(r, (x, y, near) => pts.push([k * x, k * y, k * near]))
  const found = landmarks(pts, f, k, eyes)

  const out = p => toModel(frame, mul(p, 1 / k))
  result.eyeHoles = pair.map((h, i) => out([k * h.x, k * h.y, k * rim[i]]))
  result.mask.A = round1(a)
  result.lines.A = result.eyeHoles
  for (const l of ['B', 'C', 'D', 'E']) {
    if (!found[l]) continue
    result.mask[l] = round1(found[l].value / k)
    result.lines[l] = found[l].line.map(out)
  }
  const hasNose = found.tip && found.tip[1] < eyes.y - 25 && found.E && found.E.value >= 10
  result.type = found.reaches ? 'wrap' : found.C ? 'full' : hasNose ? 'half' : 'eye'
  result.reachesCheekbones = found.reaches
  return result
}

function collect(r, keep) {
  const out = []
  eachPixel(r, (x, y, near) => { if (keep(x, y)) out.push(near) })
  return out
}

// ---- Sizing: a port of MaskFit/MaskSizing.swift, same rules and wording.
// ponytail: two copies of the sizing rules (Swift and here). MaskSizing.swift is the source of truth; change both.

export const LETTERS = {
  A: { name: 'Eye spacing', onFace: 'Pupil to pupil', onMask: 'centre to centre of the eye holes', pad: 0, more: 'wider', less: 'narrower' },
  B: { name: 'Face width', onFace: 'Across the cheekbones', onMask: 'inside width at cheekbone level', pad: 2, more: 'wider', less: 'narrower' },
  C: { name: 'Face length', onFace: 'Nose bridge to chin', onMask: 'inside, nose bridge to chin', pad: 1, more: 'longer', less: 'shorter' },
  D: { name: 'Nose length', onFace: 'Nose bridge to nose tip', onMask: 'inside, nose bridge to nose tip', pad: 0, more: 'longer', less: 'shorter' },
  E: { name: 'Nose depth', onFace: 'Nose tip in front of the cheeks', onMask: 'depth of the nose space inside', pad: 0, more: 'deeper', less: 'shallower' },
}
/** "3.6 mm narrower": how a distance on the mask compares with what the face needs (Letter.difference). */
const difference = (l, mm) => `${mmText(round1(Math.abs(mm)))} mm ${mm > 0 ? LETTERS[l].more : LETTERS[l].less}`

export const TYPES = {
  eye: { title: 'Eye mask', subtitle: 'Around the eyes', phrase: 'an eye mask', main: 'A', checks: [] },
  half: { title: 'Half mask', subtitle: 'Forehead to nose', phrase: 'a half mask', main: 'A', checks: ['D', 'E'] },
  full: { title: 'Full face', subtitle: 'Forehead to chin', phrase: 'a full-face mask', main: 'C', checks: ['A', 'E'] },
  wrap: { title: 'Wraparound', subtitle: 'Past the cheekbones', phrase: 'a wraparound mask', main: 'B', checks: ['C', 'A', 'E'] },
}

export const round1 = v => Math.round(v * 10) / 10
export const mmText = v => (v === Math.round(v) ? v.toFixed(0) : v.toFixed(1))
const pctText = v => mmText(v) + '%'

/** Scale advice from the face and mask measurements (mm, by letter), the mask type and the padding (mm). */
export function sizing(face, mask, type, padding) {
  const t = TYPES[type], m = t.main
  const target = l => (face[l] == null ? null : face[l] + LETTERS[l].pad * padding)
  const scale = l => (target(l) == null || !(mask[l] > 0) ? null : round1((target(l) / mask[l]) * 100))
  const main = scale(m)
  const out = { main, scale, working: null, looksWrong: main !== null && (main < 50 || main > 200), checks: [], disagreement: null, alternative: null, noseWarning: null, hardwareNote: null }
  if (main === null) return out

  const pad = LETTERS[m].pad
  out.working = `Your ${mmText(face[m])} mm${pad === 0 ? '' : (pad === 2 ? ' + 2 × ' : ' + ') + `${mmText(padding)} mm padding = ${mmText(target(m))} mm`}, ÷ ${mmText(mask[m])} mm on the mask`

  out.checks = t.checks.map(l => {
    const s = scale(l)
    if (s === null) return { letter: l, status: 'Not measured', isProblem: false }
    if (l === 'E') {
      const need = round1((face.E / mask.E) * 100)
      return main < need
        ? { letter: l, status: `Too shallow: needs at least ${pctText(need)}`, isProblem: true }
        : { letter: l, status: `Clears your nose at ${pctText(main)}`, isProblem: false }
    }
    const diff = Math.abs(s / main - 1) * 100
    const verdict = diff <= 3 ? 'agrees' : diff > 5 ? `disagrees by ${Math.round(diff)}%` : 'close enough'
    return { letter: l, status: `Suggests ${pctText(s)} · ${verdict}`, isProblem: diff > 5 }
  })

  const worst = best(
    t.checks.filter(l => l !== 'E').map(l => ({ letter: l, scale: scale(l) })).filter(w => w.scale !== null)
      .map(w => ({ ...w, diff: Math.abs(w.scale / main - 1) * 100 })).filter(w => w.diff > 5),
    w => w.diff,
  )
  // The scale stays even so the mask keeps its designer's look; say what matching either measurement costs.
  if (worst) {
    const o = worst.letter, name = l => LETTERS[l].name.toLowerCase()
    out.alternative = { letter: o, scale: worst.scale }
    out.disagreement = `${m} and ${o} disagree by ${Math.round(worst.diff)}%, so this mask was made for a face with different proportions. Keep the scale even so the mask keeps its look, and choose which to match: at ${pctText(main)} its ${name(o)} (${o}) is ${difference(o, (mask[o] * main) / 100 - target(o))} than you need; at ${pctText(worst.scale)} its ${name(m)} (${m}) is ${difference(m, (mask[m] * worst.scale) / 100 - target(m))} than you need.`
  }

  if (t.checks.includes('E') && face.E != null && mask.E > 0) {
    const need = round1((face.E / mask.E) * 100)
    if (main < need) out.noseWarning = `At ${pctText(main)} the nose space is ${mmText(round1((mask.E * main) / 100))} mm deep, and your nose needs ${mmText(face.E)} mm. Scale to at least ${pctText(need)}.`
  }
  if (Math.abs(main - 100) >= 1) {
    out.hardwareNote = `Scaling to ${pctText(main)} also resizes magnet pockets, strap slots and screw holes: a 6 mm magnet pocket becomes ${mmText(round1((6 * main) / 100))} mm and a 2 mm wall becomes ${mmText(round1((2 * main) / 100))} mm. Check the designer's notes for hardware sizes before printing.`
  }
  return out
}
