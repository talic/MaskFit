// Checks the measurement and depth-fusion maths against a head with known measurements, on the Mac.
// Run from the MaskFit folder:
//   swiftc -O MaskFit/FaceMeasurer.swift MaskFit/DepthFusion.swift MaskFit/MaskSizing.swift Check/main.swift -o /tmp/facecheck && /tmp/facecheck Check
// head.json comes from Tools/export_face.py; synth.json/.bin from Check/make_synth.py (both need Blender and the CC0 head).
import Foundation
import simd

struct Head: Decodable {
    let vertices: [[Float]]
    let triangles: [Int]
    let leftEye: [Float]
    let rightEye: [Float]
    let expected: [String: Float]
}

struct Synth: Decodable {
    struct Frame: Decodable { let yaw: Float; let pitch: Float; let cameraToFace: [Float] }
    let width: Int, height: Int
    let fx: Float, fy: Float, cx: Float, cy: Float
    let frames: [Frame]
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let vec = { (p: [Float]) in SIMD3(p[0], p[1], p[2]) }
let mat = { (m: [Float]) in simd_float4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                          SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])) }

// Replay mode: a folder of frames recorded on the phone (Capture.swift) through each registration option.
if FileManager.default.fileExists(atPath: dir.appendingPathComponent("frame_000.json").path) {
    struct Recorded: Decodable {
        let width: Int, height: Int
        let cameraToFace: [Float], calibIntrinsics: [Float]?, calibReference: [Float]?
        let cameraIntrinsics: [Float], imageResolution: [Float]
        let mesh: [Float], triangles: [Int16], leftEye: [Float], rightEye: [Float]
    }
    struct Rec { let frame: DepthFrame; let mesh: [SIMD3<Float>]; let triangles: [Int]; let eyes: (SIMD3<Float>, SIMD3<Float>) }
    var recs: [Rec] = []
    while let json = try? Data(contentsOf: dir.appendingPathComponent(String(format: "frame_%03d.json", recs.count))) {
        let r = try JSONDecoder().decode(Recorded.self, from: json)
        let bin = try Data(contentsOf: dir.appendingPathComponent(String(format: "frame_%03d.bin", recs.count)))
        let (k, ref) = r.calibIntrinsics.map { ($0, r.calibReference!) } ?? (r.cameraIntrinsics, r.imageResolution)
        let sx = Float(r.width) / ref[0], sy = Float(r.height) / ref[1]
        let frame = DepthFrame(width: r.width, height: r.height, depth: bin.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) },
                               intrinsics: Intrinsics(fx: k[0] * sx, fy: k[4] * sy, cx: k[6] * sx, cy: k[7] * sy),
                               cameraToFace: mat(r.cameraToFace))
        let mesh = stride(from: 0, to: r.mesh.count, by: 3).map { SIMD3(r.mesh[$0], r.mesh[$0 + 1], r.mesh[$0 + 2]) }
        recs.append(Rec(frame: frame, mesh: mesh, triangles: r.triangles.map(Int.init), eyes: (vec(r.leftEye), vec(r.rightEye))))
    }
    let n = Float(recs.count)
    let eyes = (recs.map(\.eyes.0).reduce(.zero, +) / n, recs.map(\.eyes.1).reduce(.zero, +) / n)
    let meshMeasures = recs.compactMap { FaceMeasurer(triangleIndices: $0.triangles).measure(vertices: $0.mesh, leftEye: $0.eyes.0, rightEye: $0.eyes.1) }
    let bridgeY = meshMeasures.map(\.bridgeY).sorted()[meshMeasures.count / 2]
    func show(_ name: String, _ cloud: FaceCloud) {
        let pts = cloud.points(minCount: Int32(max(3, recs.count / 10)))  // same rules as the app
        let m = FaceMeasurer(triangleIndices: []).measure(vertices: pts, leftEye: eyes.0, rightEye: eyes.1, bridgeY: bridgeY)
        print(String(format: "%-22@ %7d cells %7d counted  ", name as NSString, cloud.cellCount, pts.count)
              + (m.map { String(format: "A %.1f  B %.1f  C %.1f  D %.1f  E %.1f", $0.a, $0.b, $0.c, $0.d, $0.e) } ?? "landmarks not found"))
    }
    let med = { (k: KeyPath<FaceMeasurements, Float>) -> Float in let v = meshMeasures.map { $0[keyPath: k] }.sorted(); return v[v.count / 2] }
    print("\(recs.count) recorded frames")
    print(String(format: "%-22@ %@A %.1f  B %.1f  C %.1f  D %.1f  E %.1f", "ARKit mesh (median)" as NSString,
                 String(repeating: " ", count: 33), med(\.a), med(\.b), med(\.c), med(\.d), med(\.e)))

    // A: ARKit head pose only (what the phone did).
    var plain = FaceCloud()
    for r in recs { plain.add(r.frame, convention: .standard, region: FaceCloud.region(around: r.mesh), step: 2) }
    show("ARKit pose only", plain)

    // B: each frame snapped onto ARKit's face mesh (densified with triangle centres and edge midpoints).
    var toMesh = FaceCloud()
    for r in recs {
        let region = FaceCloud.region(around: r.mesh)
        let reg = register(r.frame.points(convention: .standard, region: region, step: 6), onto: PointGrid(densified(r.mesh, triangles: r.triangles)))
        toMesh.add(reg.map { r.frame.corrected(by: $0.correction) } ?? r.frame, convention: .standard, region: region, step: 2)
    }
    show("Snapped to ARKit mesh", toMesh)

    // C: each frame snapped onto the scan so far (the first frame anchors it).
    var model = FaceCloud()
    var log: [String] = []
    for (i, r) in recs.enumerated() {
        let region = FaceCloud.region(around: r.mesh)
        var frame = r.frame
        if i > 0, let reg = register(frame.points(convention: .standard, region: region, step: 4), onto: PointGrid(model.points(minCount: 1))) {
            frame = frame.corrected(by: reg.correction)
            let t = reg.correction.columns.3
            log.append(String(format: "%.1fmm/%.1f", simd_length(SIMD3(t.x, t.y, t.z)) * 1000, reg.rmsMM))
        }
        model.add(frame, convention: .standard, region: region, step: 2)
    }
    show("Snapped to scan so far", model)
    if CommandLine.arguments.count > 2 {  // dump the merged points and mean eyes for plotting
        let pts = model.points(minCount: 3) + [eyes.0, eyes.1]
        try pts.flatMap { [$0.x, $0.y, $0.z] }.withUnsafeBytes { Data($0) }.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
    print("per-frame shift/rms: " + log.joined(separator: " "))
    exit(0)
}
let head = try JSONDecoder().decode(Head.self, from: Data(contentsOf: dir.appendingPathComponent("head.json")))
let mesh = head.vertices.map(vec)
let (leftEye, rightEye) = (vec(head.leftEye), vec(head.rightEye))
var pass = true

func report(_ title: String, _ m: FaceMeasurements?) {
    print("\n" + title)
    guard let m else { print("  landmarks not found"); pass = false; return }
    for (key, got) in [("A", m.a), ("B", m.b), ("C", m.c), ("D", m.d), ("E", m.e)] {
        let want = head.expected[key]!
        print("  \(key)", String(format: "%6.1f mm   expected %6.1f   diff %+5.1f", got, want, got - want))
        pass = pass && abs(got - want) <= 3
    }
}

// 1. Landmarks on the face mesh.
let onMesh = FaceMeasurer(triangleIndices: head.triangles).measure(vertices: mesh, leftEye: leftEye, rightEye: rightEye)
report("Face mesh", onMesh)

// 2. Synthetic depth maps fused into a point cloud.
let synth = try JSONDecoder().decode(Synth.self, from: Data(contentsOf: dir.appendingPathComponent("synth.json")))
let raw = try Data(contentsOf: dir.appendingPathComponent("synth.bin"))
let samples = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
let size = synth.width * synth.height
let k = Intrinsics(fx: synth.fx, fy: synth.fy, cx: synth.cx, cy: synth.cy)
let frames = synth.frames.enumerated().map { i, f in
    let m = f.cameraToFace
    let matrix = simd_float4x4(SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                               SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15]))
    return DepthFrame(width: synth.width, height: synth.height, depth: Array(samples[i * size ..< (i + 1) * size]),
                      intrinsics: k, cameraToFace: matrix)
}
let region = FaceCloud.region(around: mesh)

// The scanner must pick the right pixel convention, including for a mirrored depth map. From straight on
// a mirrored face looks right, so it must hold off there and decide once the head is turned.
func mirror(_ f: DepthFrame) -> DepthFrame {
    DepthFrame(width: f.width, height: f.height,
               depth: (0 ..< f.height).flatMap { v in f.depth[v * f.width ..< (v + 1) * f.width].reversed() },
               intrinsics: Intrinsics(fx: k.fx, fy: k.fy, cx: Float(f.width) - k.cx, cy: k.cy),
               cameraToFace: f.cameraToFace)
}
let cases: [(String, DepthFrame, PixelConvention?)] = [
    ("straight on", frames[0], nil), ("straight on, mirrored", mirror(frames[0]), nil),
    ("turned 20°", frames[1], .standard), ("turned 20°, mirrored", mirror(frames[1]), .mirrorX),
]
for (name, frame, want) in cases {
    let got = FaceCloud.clearConvention(frame, mesh: mesh, region: region)
    let ok = got?.convention == want || (want == nil && got?.convention == .standard)
    print("Convention, \(name): \(got.map { "\($0.convention) (\(String(format: "%.1f", $0.errorMM)) mm)" } ?? "undecided")\(ok ? "" : "   <- want \(want.map { "\($0)" } ?? "undecided")")")
    pass = pass && ok
}

var cloud = FaceCloud()
for f in frames { cloud.add(f, convention: .standard, region: region, step: 1) }
let points = cloud.points(minCount: 2)
print("\nFused \(frames.count) frames into \(cloud.cellCount) cells, \(points.count) seen twice or more")
report("Fused depth points", FaceMeasurer(triangleIndices: []).measure(vertices: points, leftEye: leftEye, rightEye: rightEye, bridgeY: onMesh?.bridgeY))

// 3. Mask sizing advice, same cases as the results-screen mockup.
print("\nMask sizing")
func expect(_ ok: Bool, _ what: String) {
    print(ok ? "  ok    " : "  WRONG ", what)
    pass = pass && ok
}
let face: [Letter: Float] = [.a: 64, .b: 145, .c: 119, .d: 44, .e: 33]
let full = MaskSizing(face: face, type: .full, padding: 4, mask: [.c: 116, .a: 57])
expect(full.mainScale == 106 && full.working == "Your 119 mm + 4 mm padding = 123 mm, ÷ 116 mm on the mask", "full face: C 116 mm -> 106%")
expect(full.checks.map(\.status) == ["Suggests 112.3% · disagrees by 6%", "Optional"], "full face: A check disagrees")
expect(full.disagreement?.contains("width (across the eyes) to 112.3% and the height (top to bottom) to 106%") == true, "full face: uneven-scale advice")
expect(full.hardwareNote?.contains("6 mm magnet pocket becomes 6.4 mm") == true, "hardware note")
let wrap = MaskSizing(face: face, type: .wrap, padding: 4, mask: [.b: 140, .a: 60, .c: 120])
expect(wrap.mainScale == 109.3 && wrap.working == "Your 145 mm + 2 × 4 mm padding = 153 mm, ÷ 140 mm on the mask", "wraparound: B gets padding on both sides")
expect(wrap.checks.map(\.status) == ["Suggests 102.5% · disagrees by 6%", "Suggests 106.7% · agrees", "Optional"], "wraparound: checks")
let half = MaskSizing(face: face, type: .half, padding: 6, mask: [.a: 62, .d: 40, .e: 28])
expect(half.mainScale == 103.2 && half.working == "Your 64 mm, ÷ 62 mm on the mask", "half mask: no padding on eye spacing")
expect(half.noseWarning == "At 103.2% the nose space is 28.9 mm deep, and your nose needs 33 mm. Scale to at least 117.9%.", "half mask: nose warning")
expect(MaskSizing(face: face, type: .eye, padding: 4, mask: [.a: 30]).looksWrong, "eye mask: 213% flagged as a likely mis-measure")
expect(MaskSizing(face: face, type: .eye, padding: 4, mask: [:]).mainScale == nil, "no mask measurement: no scale")

print(pass ? "\nPASS (all within 3 mm)" : "\nFAIL")
exit(pass ? 0 : 1)
