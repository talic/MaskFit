import simd

/// Face measurements in millimetres. Letters match the results screen.
struct FaceMeasurements: Equatable {
    var a: Float  // eye spacing: eyeball centre to eyeball centre (distance PD)
    var b: Float  // face width across the cheekbones
    var c: Float  // face length: nose bridge (sellion) to chin (menton)
    var d: Float  // nose length: nose bridge to nose tip (pronasale)
    var e: Float  // nose depth: nose tip in front of the cheeks
    var bAtMeshEdge: Bool  // B was taken at the mesh boundary, so the true width may be larger
    var bridgeY: Float     // height of the nose bridge point used, metres in face space
}

/// Finds landmarks on a face mesh or fused point cloud in ARKit face-anchor space:
/// metres, +x toward the face's own left, +y up, +z out of the face.
/// Pure geometry so it can be checked off-device (see Check/).
struct FaceMeasurer {
    private let boundary: Set<Int>

    init(triangleIndices: [Int]) {
        var edgeUses: [UInt64: Int] = [:]
        for t in stride(from: 0, to: triangleIndices.count - 2, by: 3) {
            let tri = [triangleIndices[t], triangleIndices[t + 1], triangleIndices[t + 2]]
            for (i, j) in [(0, 1), (1, 2), (2, 0)] {
                let lo = UInt64(min(tri[i], tri[j])), hi = UInt64(max(tri[i], tri[j]))
                edgeUses[lo << 32 | hi, default: 0] += 1
            }
        }
        var boundary = Set<Int>()
        for (edge, uses) in edgeUses where uses == 1 {
            boundary.insert(Int(edge >> 32))
            boundary.insert(Int(edge & 0xFFFF_FFFF))
        }
        self.boundary = boundary
    }

    /// `bridgeY` fixes the nose bridge's height (e.g. from ARKit's mesh, whose bridge doesn't wander); its depth
    /// still comes from `vertices`. Without it the bridge is the deepest point of the smoothed profile.
    func measure(vertices v: [SIMD3<Float>], leftEye: SIMD3<Float>, rightEye: SIMD3<Float>, bridgeY: Float? = nil) -> FaceMeasurements? {
        let eyes = (leftEye + rightEye) / 2
        let midline = v.filter { abs($0.x - eyes.x) < 0.003 }
        guard
            let tip = midline.filter({ $0.y > eyes.y - 0.08 && $0.y < eyes.y - 0.01 }).max(by: { $0.z < $1.z }),
            let bridge = bridgeY.map({ Self.surface(midline, x: eyes.x, y: $0) }) ?? Self.deepest(midline, x: eyes.x, from: eyes.y - 0.012, to: eyes.y + 0.025),
            // Front of the chin, then its lowest point within 22 mm behind that, which keeps the jaw underside out.
            let chinFront = midline.filter({ $0.y < tip.y - 0.055 }).max(by: { $0.z < $1.z }),
            let chin = midline.filter({ $0.y < chinFront.y && $0.z > chinFront.z - 0.022 }).min(by: { $0.y < $1.y })
        else { return nil }

        // Widest points at cheekbone height, no more than 45 mm behind the eye centres: the cheekbone arch
        // sits there, while depth scans also reach the sides of the head and the ears further back.
        let band = v.indices.filter { v[$0].y > eyes.y - 0.035 && v[$0].y < eyes.y - 0.005 && v[$0].z > eyes.z - 0.045 }
        guard let l = band.max(by: { v[$0].x < v[$1].x }), let r = band.min(by: { v[$0].x < v[$1].x }) else { return nil }

        // Cheek surface 35 mm either side of the nose, at nose-tip height; front-most point wins.
        func cheekZ(_ side: Float) -> Float? {
            let spot = SIMD2(eyes.x + side * 0.035, tip.y + 0.005)
            return v.filter { simd_distance(SIMD2($0.x, $0.y), spot) < 0.006 }.map(\.z).max()
        }
        guard let zl = cheekZ(1), let zr = cheekZ(-1) else { return nil }

        let mm: Float = 1000
        return FaceMeasurements(
            a: simd_distance(leftEye, rightEye) * mm,
            b: simd_distance(v[l], v[r]) * mm,
            c: simd_distance(bridge, chin) * mm,
            d: simd_distance(bridge, tip) * mm,
            e: (tip.z - (zl + zr) / 2) * mm,
            bAtMeshEdge: boundary.contains(l) || boundary.contains(r),
            bridgeY: bridge.y
        )
    }

    /// Midline surface point at height `y`: median depth of points within 1.5 mm.
    private static func surface(_ midline: [SIMD3<Float>], x: Float, y: Float) -> SIMD3<Float>? {
        let z = midline.filter { abs($0.y - y) < 0.0015 }.map(\.z).sorted()
        return z.isEmpty ? nil : SIMD3(x, y, z[z.count / 2])
    }

    /// Nose bridge: the deepest point of the side profile between `from` and `to` (heights). The bridge is a
    /// shallow curve, so the single deepest point jumps around with noise; instead take the median depth per
    /// millimetre of height and average over ±2 mm before looking for the deepest spot.
    private static func deepest(_ midline: [SIMD3<Float>], x: Float, from lo: Float, to hi: Float) -> SIMD3<Float>? {
        var bins: [Int: [Float]] = [:]
        for p in midline where p.y > lo && p.y < hi { bins[Int((p.y - lo) / 0.001), default: []].append(p.z) }
        let profile = bins.map { (y: $0.key, z: $0.value.sorted()[$0.value.count / 2]) }
        let smooth = profile.map { bin in
            let near = profile.filter { abs($0.y - bin.y) <= 2 }.map(\.z)
            return (y: bin.y, z: near.reduce(0, +) / Float(near.count))
        }
        guard let best = smooth.min(by: { $0.z < $1.z }) else { return nil }
        return SIMD3(x, lo + (Float(best.y) + 0.5) * 0.001, best.z)
    }
}
