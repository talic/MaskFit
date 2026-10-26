import simd

/// Camera intrinsics in depth-map pixels.
struct Intrinsics {
    var fx: Float, fy: Float, cx: Float, cy: Float
}

/// One depth map and where the camera was relative to the face when it was taken.
struct DepthFrame {
    let width: Int
    let height: Int
    let depth: [Float]  // metres along the optical axis, row-major; 0 or NaN = no reading
    let intrinsics: Intrinsics
    let cameraToFace: simd_float4x4  // ARKit camera space (x right, y up, looking down -z) to face-anchor space

    /// Every `step`-th valid point that lands inside `region`, in face-anchor space.
    func points(convention: PixelConvention, region: Box, step: Int) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        for v in stride(from: 0, to: height, by: step) {
            for u in stride(from: 0, to: width, by: step) {
                if let p = point(u: u, v: v, convention: convention), all(p .>= region.lo), all(p .<= region.hi) { out.append(p) }
            }
        }
        return out
    }

    /// The same frame with its pose adjusted by `correction` (applied in face space).
    func corrected(by correction: simd_float4x4) -> DepthFrame {
        DepthFrame(width: width, height: height, depth: depth, intrinsics: intrinsics, cameraToFace: correction * cameraToFace)
    }

    /// Point for pixel (u, v) in face-anchor space, or nil without a valid reading.
    func point(u: Int, v: Int, convention: PixelConvention) -> SIMD3<Float>? {
        let d = depth[v * width + u]
        guard d > 0.1, d < 0.8 else { return nil }
        var x = (Float(u) + 0.5 - intrinsics.cx) * d / intrinsics.fx
        var y = (Float(v) + 0.5 - intrinsics.cy) * d / intrinsics.fy
        if convention == .mirrorX || convention == .mirrorXFlipY { x = -x }
        if convention == .flipY || convention == .mirrorXFlipY { y = -y }
        // Image rows run down, ARKit's camera y runs up, and the camera looks down -z.
        let p = cameraToFace * SIMD4(x, -y, -d, 1)
        return SIMD3(p.x, p.y, p.z)
    }
}

/// How depth-map pixels line up with ARKit's camera axes. The front camera's depth map may be
/// mirrored or flipped relative to ARCamera, so the scanner tries each and keeps the one that lands on the face.
enum PixelConvention: String, CaseIterable {
    case standard, mirrorX, flipY, mirrorXFlipY
}

typealias Box = (lo: SIMD3<Float>, hi: SIMD3<Float>)

/// Depth points from many frames merged into 1.5 mm cells in face-anchor space.
struct FaceCloud {
    static let cell: Float = 0.0015
    private var cells: [Int: (sum: SIMD3<Float>, count: Int32)] = [:]

    var cellCount: Int { cells.count }

    /// Box around the face mesh, with room for the real face to sit a little outside ARKit's estimate.
    static func region(around mesh: [SIMD3<Float>]) -> Box {
        let lo = mesh.reduce(SIMD3(repeating: .infinity)) { simd_min($0, $1) }
        let hi = mesh.reduce(SIMD3(repeating: -.infinity)) { simd_max($0, $1) }
        return (lo - SIMD3(0.015, 0.015, 0.01), hi + SIMD3(0.015, 0.015, 0.015))
    }

    /// Adds every `step`-th pixel that lands inside `region`.
    mutating func add(_ frame: DepthFrame, convention: PixelConvention, region: Box, step: Int = 2) {
        for v in stride(from: 0, to: frame.height, by: step) {
            for u in stride(from: 0, to: frame.width, by: step) {
                guard let p = frame.point(u: u, v: v, convention: convention),
                      all(p .>= region.lo), all(p .<= region.hi) else { continue }
                let key = Self.key(p)
                let old = cells[key]
                cells[key] = ((old?.sum ?? .zero) + p, (old?.count ?? 0) + 1)
            }
        }
    }

    /// Averaged cell positions seen at least `minCount` times; fewer sightings are usually noise.
    func points(minCount: Int32 = 3) -> [SIMD3<Float>] {
        cells.values.compactMap { $0.count >= minCount ? $0.sum / Float($0.count) : nil }
    }

    /// Median distance in mm from sampled depth points to the nearest mesh vertex, and how many points
    /// were sampled. Small with many points when depth and mesh agree; a wrong convention misses the face.
    static func alignment(_ frame: DepthFrame, convention: PixelConvention, mesh: [SIMD3<Float>], region: Box)
        -> (errorMM: Float, points: Int)?
    {
        let step = max(1, Int((Float(frame.width * frame.height) / 4000).squareRoot()))
        var distances: [Float] = []
        for v in stride(from: 0, to: frame.height, by: step) {
            for u in stride(from: 0, to: frame.width, by: step) {
                guard let p = frame.point(u: u, v: v, convention: convention),
                      all(p .>= region.lo), all(p .<= region.hi) else { continue }
                distances.append(mesh.map { simd_distance_squared($0, p) }.min()!.squareRoot())
            }
        }
        guard distances.count >= 30 else { return nil }
        return (distances.sorted()[distances.count / 2] * 1000, distances.count)
    }

    /// The convention whose points land on the mesh, once one clearly beats the others (among those keeping
    /// at least half the best point count). A face is nearly symmetric, so a mirrored map looks right from
    /// straight on and only stands out once the head is turned; until then this returns nil.
    static func clearConvention(_ frame: DepthFrame, mesh: [SIMD3<Float>], region: Box)
        -> (convention: PixelConvention, errorMM: Float)?
    {
        let scored = PixelConvention.allCases.compactMap { c in alignment(frame, convention: c, mesh: mesh, region: region).map { (c, $0) } }
        guard let most = scored.map(\.1.points).max() else { return nil }
        let ranked = scored.filter { $0.1.points * 2 >= most }.sorted { $0.1.errorMM < $1.1.errorMM }
        guard let best = ranked.first, best.1.errorMM < 6 else { return nil }
        if ranked.count > 1, best.1.errorMM > 0.6 * ranked[1].1.errorMM { return nil }
        return (best.0, best.1.errorMM)
    }

    private static func key(_ p: SIMD3<Float>) -> Int {
        let i = SIMD3<Int32>(p / cell, rounding: .down) &+ 512
        return Int(i.x) | Int(i.y) << 10 | Int(i.z) << 20
    }
}

/// The face mesh plus triangle centres and edge midpoints, so nearest-point distances measure the surface
/// rather than the spacing between ARKit's vertices.
func densified(_ mesh: [SIMD3<Float>], triangles: [Int]) -> [SIMD3<Float>] {
    var dense = mesh
    for t in stride(from: 0, to: triangles.count - 2, by: 3) {
        let (a, b, c) = (mesh[triangles[t]], mesh[triangles[t + 1]], mesh[triangles[t + 2]])
        dense += [(a + b + c) / 3, (a + b) / 2, (b + c) / 2, (c + a) / 2]
    }
    return dense
}

/// Nearest-neighbour lookup over a point set, bucketed into a coarse grid.
struct PointGrid {
    private let cell: Float
    private var buckets: [Int: [SIMD3<Float>]] = [:]

    init(_ points: [SIMD3<Float>], cell: Float = 0.006) {
        self.cell = cell
        for p in points { buckets[key(SIMD3<Int32>(p / cell, rounding: .down)), default: []].append(p) }
    }

    /// Nearest point within one cell's distance, searching the 27 surrounding cells.
    func nearest(to p: SIMD3<Float>) -> SIMD3<Float>? {
        let c = SIMD3<Int32>(p / cell, rounding: .down)
        var best: SIMD3<Float>?
        var bestD = cell * cell
        for dx: Int32 in -1 ... 1 { for dy: Int32 in -1 ... 1 { for dz: Int32 in -1 ... 1 {
            for q in buckets[key(c &+ SIMD3(dx, dy, dz))] ?? [] {
                let d = simd_distance_squared(p, q)
                if d < bestD { bestD = d; best = q }
            }
        } } }
        return best
    }

    private func key(_ i: SIMD3<Int32>) -> Int {
        let j = i &+ 512
        return Int(j.x) | Int(j.y) << 10 | Int(j.z) << 20
    }
}

/// Rigid correction (in face space) that moves `points` onto `target`: iterated closest points, each step a
/// small-angle least-squares solve. ARKit's head pose is a few mm and degrees off and the error changes with
/// head angle, so frames are snapped onto the scan so far before merging. Returns nil if too few points match.
func register(_ points: [SIMD3<Float>], onto target: PointGrid, iterations: Int = 12) -> (correction: simd_float4x4, rmsMM: Float)? {
    var total = matrix_identity_float4x4
    var moved = points
    var rms: Float = 0
    for _ in 0 ..< iterations {
        // Normal equations for [ω, t] minimising Σ |p + ω×p + t − q|².
        var ata = [Double](repeating: 0, count: 36), atb = [Double](repeating: 0, count: 6)
        var pairs = 0
        var sq: Float = 0
        for p in moved {
            guard let q = target.nearest(to: p) else { continue }
            let r = q - p
            pairs += 1
            sq += simd_length_squared(r)
            // Rows of the 3x6 Jacobian [−[p]×  I].
            let rows: [[Double]] = [
                [0, Double(p.z), Double(-p.y), 1, 0, 0],
                [Double(-p.z), 0, Double(p.x), 0, 1, 0],
                [Double(p.y), Double(-p.x), 0, 0, 0, 1],
            ]
            for (row, b) in zip(rows, [r.x, r.y, r.z]) {
                for i in 0 ..< 6 {
                    atb[i] += row[i] * Double(b)
                    for j in 0 ..< 6 { ata[i * 6 + j] += row[i] * row[j] }
                }
            }
        }
        guard pairs >= 100, let x = solve6(ata, atb) else { return nil }
        rms = (sq / Float(pairs)).squareRoot() * 1000
        let w = SIMD3(Float(x[0]), Float(x[1]), Float(x[2]))
        let angle = simd_length(w)
        var step = angle > 1e-9 ? simd_float4x4(simd_quatf(angle: angle, axis: w / angle)) : matrix_identity_float4x4
        step.columns.3 = SIMD4(Float(x[3]), Float(x[4]), Float(x[5]), 1)
        total = step * total
        moved = moved.map { let h = step * SIMD4($0, 1); return SIMD3(h.x, h.y, h.z) }
    }
    return (total, rms)
}

/// Solves a 6x6 system by Gaussian elimination with partial pivoting.
private func solve6(_ a: [Double], _ b: [Double]) -> [Double]? {
    var m = a, v = b
    for col in 0 ..< 6 {
        let pivot = (col ..< 6).max { abs(m[$0 * 6 + col]) < abs(m[$1 * 6 + col]) }!
        guard abs(m[pivot * 6 + col]) > 1e-12 else { return nil }
        if pivot != col {
            for j in 0 ..< 6 { m.swapAt(col * 6 + j, pivot * 6 + j) }
            v.swapAt(col, pivot)
        }
        for row in col + 1 ..< 6 {
            let f = m[row * 6 + col] / m[col * 6 + col]
            for j in col ..< 6 { m[row * 6 + j] -= f * m[col * 6 + j] }
            v[row] -= f * v[col]
        }
    }
    var x = [Double](repeating: 0, count: 6)
    for row in (0 ..< 6).reversed() {
        x[row] = (v[row] - (row + 1 ..< 6).reduce(0) { $0 + m[row * 6 + $1] * x[$1] }) / m[row * 6 + row]
    }
    return x
}
