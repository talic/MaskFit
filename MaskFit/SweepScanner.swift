import ARKit
import AVFoundation
import Observation
import SceneKit
import SwiftUI

/// Face ID-style sweep: the user turns their head in a circle while TrueDepth depth maps are fused into a
/// point cloud in face space, and A–E are measured on that cloud until the numbers stop changing.
@Observable
final class SweepScanner: NSObject, ARSessionDelegate, ARSCNViewDelegate {
    struct Live: Identifiable {
        let id: String
        let name: String
        var mm: Float?
        var settled = false
    }

    struct Summary {
        struct Row: Identifiable {
            let id: String
            let name: String
            let depth: Float?  // measured on the fused depth points
            let mesh: Float?   // measured on ARKit's fitted face mesh, for comparison
        }
        let rows: [Row]
        let points: Int
        let coverage: Float
        let alignmentMM: Float
        let convention: String
        let depthInfo: String
        let timedOut: Bool
    }

    static let segments = 36
    static let names = [("A", "Eye spacing"), ("B", "Face width"), ("C", "Face length"), ("D", "Nose length"), ("E", "Nose depth")]
    static let keys: [KeyPath<FaceMeasurements, Float>] = [\.a, \.b, \.c, \.d, \.e]

    // Main thread; drives the UI.
    var started = false
    var hint = "Fit your face inside the circle, then tap Start"
    var covered = [Bool](repeating: false, count: segments)
    var live = names.map { Live(id: $0.0, name: $0.1) }
    var debug = "Waiting for depth"
    var summary: Summary?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var hintChanged: CFTimeInterval = 0
    @ObservationIgnored private var lastLog: CFTimeInterval = 0
    @ObservationIgnored weak var session: ARSession?
    /// Head and camera pose for every frame, so each depth map gets the pose from when it was captured.
    @ObservationIgnored private var poses: [(t: TimeInterval, face: simd_float4x4, camera: simd_float4x4)] = []

    // Processing queue only.
    private struct Work {
        var cloud = FaceCloud()
        // Measured as .standard on an iPhone 16 Pro Max; re-checked once the head turns.
        var convention = PixelConvention.standard
        var orientationChecked = false
        var fitMM = Float.nan  // how closely the last frame snapped onto ARKit's mesh
        var fused = 0
        var triangles: [Int] = []
        var covered = [Bool](repeating: false, count: SweepScanner.segments)
        var eyes = (SIMD3<Float>.zero, SIMD3<Float>.zero)
        var eyeFrames = 0
        var estimates: [FaceMeasurements] = []  // from the cloud, every 0.5 s
        var meshSamples: [FaceMeasurements] = []
        var meshMeasurer: FaceMeasurer?
        var lastDirection: SIMD3<Float>?
        var lastTime: TimeInterval = 0
        var start: TimeInterval?
        var lastEstimate: TimeInterval = 0
        var lastSnapshot: TimeInterval = 0
        var depthInfo = ""
        var recorded = 0
        var lastRecord: TimeInterval = 0
    }
    @ObservationIgnored private let queue = DispatchQueue(label: "MaskFit.sweep", qos: .userInitiated)
    @ObservationIgnored private var work = Work()

    // Processing queue → render thread.
    @ObservationIgnored private let snapshotLock = NSLock()
    @ObservationIgnored private var snapshot: [SIMD3<Float>]?

    // Render thread → processing queue: which ring segment the face points at on screen, and how far it's turned.
    @ObservationIgnored private let poseLock = NSLock()
    @ObservationIgnored private var screenPose: (segment: Int, turned: Float)?

    private struct Update {
        var hint: String
        var covered: [Bool]
        var live: [Live]
        var debug: String
        var summary: Summary?
    }

    // MARK: ARSessionDelegate (main thread)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard started, summary == nil, let face = frame.anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first else { return }
        poses.append((frame.timestamp, face.transform, frame.camera.transform))
        guard !busy, let depth = frame.capturedDepthData else { return }
        // Depth arrives at 15 Hz and can be older than the frame it comes with; a turning head smears
        // the cloud unless each depth map uses the head pose from its own capture time.
        let depthTime = frame.capturedDepthDataTimestamp
        let pose = poses.suffix(30).min { abs($0.t - depthTime) < abs($1.t - depthTime) }!
        let cameraToFace = pose.face.inverse * pose.camera
        let lag = frame.timestamp - depthTime
        busy = true
        let camera = frame.camera, time = frame.timestamp
        queue.async {
            let update = self.process(face, camera, depth, time, cameraToFace: cameraToFace, depthLag: lag)
            DispatchQueue.main.async { self.apply(update) }
        }
    }

    private func apply(_ u: Update) {
        busy = false
        guard summary == nil else { return }
        // Hold each prompt at least 0.8 s so a single odd frame doesn't make the text flicker.
        let now = CACurrentMediaTime()
        if u.hint != hint, now - hintChanged >= 0.8 {
            hint = u.hint
            hintChanged = now
            print("[MaskFit] hint: \(hint)")
        }
        covered = u.covered
        live = u.live
        debug = u.debug
        if now - lastLog >= 1 {
            lastLog = now
            print("[MaskFit] \(debug) · " + live.map { "\($0.id) \($0.mm.map { String(format: "%.1f", $0) } ?? "-")\($0.settled ? "✓" : "")" }.joined(separator: " "))
        }
        if let s = u.summary {
            session?.pause()
            summary = s
            Capture.writePoses(poses)
            print("[MaskFit] done, timedOut \(s.timedOut): " + s.rows.map { "\($0.id) \($0.depth.map { String(format: "%.1f", $0) } ?? "-")/\($0.mesh.map { String(format: "%.1f", $0) } ?? "-")" }.joined(separator: " "))
        }
    }

    func start() {
        started = true
        Capture.reset()
        hint = "Slowly move your head in a circle"
        hintChanged = CACurrentMediaTime()
        print("[MaskFit] start")
    }

    // MARK: ARSCNViewDelegate (render thread)

    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard anchor is ARFaceAnchor, let device = renderer.device, let mesh = ARSCNFaceGeometry(device: device) else { return nil }
        mesh.firstMaterial?.fillMode = .lines
        mesh.firstMaterial?.diffuse.contents = UIColor.white.withAlphaComponent(0.25)
        let node = SCNNode(geometry: mesh)
        let cloud = SCNNode()
        cloud.name = "cloud"
        node.addChildNode(cloud)
        return node
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let face = anchor as? ARFaceAnchor else { return }
        (node.geometry as? ARSCNFaceGeometry)?.update(from: face.geometry)

        // Where the face points in the preview, clockwise from up, so the ring follows the nose on screen
        // however the preview is mirrored.
        let origin = Self.position(face.transform)
        let ahead = face.transform * SIMD4<Float>(0, 0, 0.1, 1)
        let p0 = renderer.projectPoint(SCNVector3(origin.x, origin.y, origin.z))
        let p1 = renderer.projectPoint(SCNVector3(ahead.x, ahead.y, ahead.z))
        let angle = (atan2(Float(p1.x - p0.x), Float(p0.y - p1.y)) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        if let camera = renderer.pointOfView?.simdWorldPosition {
            let forward = simd_normalize(SIMD3(face.transform.columns.2.x, face.transform.columns.2.y, face.transform.columns.2.z))
            let turned = acos(min(1, simd_dot(forward, simd_normalize(camera - origin)))) * 180 / .pi
            poseLock.lock()
            screenPose = (Int(angle / (360 / Float(Self.segments))) % Self.segments, turned)
            poseLock.unlock()
        }

        snapshotLock.lock()
        let points = snapshot
        snapshot = nil
        snapshotLock.unlock()
        if let points, let cloud = node.childNode(withName: "cloud", recursively: false) {
            cloud.geometry = Self.pointGeometry(points)
        }
    }

    private static func pointGeometry(_ points: [SIMD3<Float>]) -> SCNGeometry {
        let source = SCNGeometrySource(vertices: points.map { SCNVector3($0.x, $0.y, $0.z) })
        let element = SCNGeometryElement(indices: Array(0 ..< Int32(points.count)), primitiveType: .point)
        element.pointSize = 3
        element.minimumPointScreenSpaceRadius = 1.5
        element.maximumPointScreenSpaceRadius = 3
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.diffuse.contents = UIColor(red: 0.35, green: 0.6, blue: 1, alpha: 1)
        material.lightingModel = .constant
        geometry.materials = [material]
        return geometry
    }

    // MARK: Processing queue

    private func process(_ face: ARFaceAnchor, _ camera: ARCamera, _ depthData: AVDepthData, _ t: TimeInterval,
                         cameraToFace: simd_float4x4, depthLag: TimeInterval) -> Update {
        if work.start == nil { work.start = t }
        let elapsed = t - work.start!
        let say = { (hint: String) in Update(hint: hint, covered: self.work.covered, live: self.liveValues(), debug: self.debugLine()) }

        guard face.isTracked else { return say("Face not found") }
        let c = Self.position(cameraToFace)
        let distance = simd_length(c)
        // TrueDepth is most accurate at 25–50 cm.
        if distance < 0.25 { return say("Move the phone a little further away") }
        if distance > 0.5 { return say("Bring the phone a little closer") }
        let shape = { (k: ARFaceAnchor.BlendShapeLocation) in face.blendShapes[k]?.floatValue ?? 0 }
        if shape(.jawOpen) > 0.08 || max(shape(.mouthSmileLeft), shape(.mouthSmileRight)) > 0.3 {
            return say("Relax your face, mouth closed")
        }
        let direction = c / distance
        defer { work.lastDirection = direction; work.lastTime = t }
        if let last = work.lastDirection, t > work.lastTime {
            let degreesPerSecond = acos(min(1, simd_dot(last, direction))) * 180 / .pi / Float(t - work.lastTime)
            if degreesPerSecond > 60 { return say("Slow down a little") }
        }

        let mesh = face.geometry.vertices
        let region = FaceCloud.region(around: mesh)
        let frame = depthFrame(depthData, camera: camera, cameraToFace: cameraToFace)
        let eyes = (Self.position(face.leftEyeTransform), Self.position(face.rightEyeTransform))
        if work.recorded < 40, t - work.lastRecord >= 0.5 {
            work.lastRecord = t
            Capture.write(index: work.recorded, frame: frame, depthData: depthData, camera: camera, face: face,
                          time: t, depthLag: depthLag, eyes: eyes)
            work.recorded += 1
        }
        if work.meshMeasurer == nil {
            work.triangles = face.geometry.triangleIndices.map(Int.init)
            work.meshMeasurer = FaceMeasurer(triangleIndices: work.triangles)
        }
        if let m = work.meshMeasurer?.measure(vertices: mesh, leftEye: eyes.0, rightEye: eyes.1) {
            work.meshSamples.append(m)
        }

        let dense = densified(mesh, triangles: work.triangles)

        // Confirm how depth pixels map onto the camera once the head is turned (a face looks right mirrored
        // from straight on); if another orientation clearly fits better, switch and start the cloud again.
        if !work.orientationChecked, acos(min(1, direction.z)) * 180 / .pi >= 12,
           let found = FaceCloud.clearConvention(frame, mesh: dense, region: region) {
            work.orientationChecked = true
            print("[MaskFit] depth orientation \(found.convention), fit \(String(format: "%.1f", found.errorMM)) mm after \(String(format: "%.1f", elapsed)) s")
            if found.convention != work.convention {
                work.convention = found.convention
                work.cloud = FaceCloud()
                work.estimates = []
            }
        }

        // ARKit's head pose is a few mm and degrees off, differently at each angle; snap the frame onto the
        // face mesh before merging so the frames stack instead of smearing.
        guard let snap = register(frame.points(convention: work.convention, region: region, step: 6), onto: PointGrid(dense)) else {
            return say("Hold the phone steady")
        }
        work.fitMM = snap.rmsMM
        work.cloud.add(frame.corrected(by: snap.correction), convention: work.convention, region: region, step: 2)
        work.fused += 1
        work.eyes.0 += eyes.0
        work.eyes.1 += eyes.1
        work.eyeFrames += 1

        poseLock.lock()
        let pose = screenPose
        poseLock.unlock()
        if let pose, pose.turned >= 15 { work.covered[pose.segment] = true }

        if t - work.lastEstimate >= 0.5 {
            work.lastEstimate = t
            let n = Float(work.eyeFrames)
            // The nose bridge's height comes from ARKit's mesh: on the scan the bridge is a shallow curve and
            // its deepest point wanders by several mm, dragging C and D with it.
            let bridgeY = work.meshSamples.map(\.bridgeY).sorted().dropFirst(work.meshSamples.count / 2).first
            if let m = FaceMeasurer(triangleIndices: []).measure(vertices: work.cloud.points(minCount: minSightings),
                                                                 leftEye: work.eyes.0 / n, rightEye: work.eyes.1 / n, bridgeY: bridgeY) {
                work.estimates.append(m)
            }
        }
        if t - work.lastSnapshot >= 0.3 {
            work.lastSnapshot = t
            let points = work.cloud.points(minCount: 2)
            snapshotLock.lock()
            snapshot = points
            snapshotLock.unlock()
        }

        let swept = coverage >= 0.75
        if (swept && settled.allSatisfy { $0 } && elapsed >= 6) || elapsed > 45 {
            return finish(timedOut: !(swept && settled.allSatisfy { $0 }))
        }
        return say(swept ? "Now look straight at the phone and hold still" : "Slowly move your head in a circle")
    }

    /// A cell counts once 10% of the frames so far have seen it (at least 3). The face's outer edges are only
    /// seen while the head is turned that way, so a fixed count lets thin, noisy edges stretch the outline.
    private var minSightings: Int32 { Int32(max(3, work.fused / 10)) }

    private var coverage: Float { Float(work.covered.filter { $0 }.count) / Float(Self.segments) }

    /// A letter has settled when its last six estimates (3 s) agree within 0.6 mm.
    private var settled: [Bool] {
        let recent = work.estimates.suffix(6)
        return Self.keys.map { key in
            let v = recent.map { $0[keyPath: key] }
            return v.count == 6 && v.max()! - v.min()! <= 0.6
        }
    }

    private func liveValues() -> [Live] {
        let flags = settled
        return Self.names.indices.map { i in
            Live(id: Self.names[i].0, name: Self.names[i].1, mm: work.estimates.last?[keyPath: Self.keys[i]], settled: flags[i])
        }
    }

    private func debugLine() -> String {
        let fit = work.fitMM.isNaN ? "–" : String(format: "%.1f mm", work.fitMM)
        return "\(work.depthInfo) · \(work.convention.rawValue)\(work.orientationChecked ? "" : "?") · fit \(fit) · \(work.cloud.cellCount) cells · ring \(Int(coverage * 100))%"
    }

    private func finish(timedOut: Bool) -> Update {
        let median = { (values: [Float]) -> Float? in values.isEmpty ? nil : values.sorted()[values.count / 2] }
        let recent = Array(work.estimates.suffix(6))
        let rows = Self.names.indices.map { i in
            Summary.Row(id: Self.names[i].0, name: Self.names[i].1,
                        depth: median(recent.map { $0[keyPath: Self.keys[i]] }),
                        mesh: median(work.meshSamples.map { $0[keyPath: Self.keys[i]] }))
        }
        let summary = Summary(rows: rows, points: work.cloud.points(minCount: minSightings).count, coverage: coverage,
                              alignmentMM: work.fitMM, convention: work.convention.rawValue,
                              depthInfo: work.depthInfo, timedOut: timedOut)
        return Update(hint: "", covered: work.covered, live: liveValues(), debug: debugLine(), summary: summary)
    }

    /// Copies the depth map out of the frame and works out its intrinsics in depth-map pixels.
    private func depthFrame(_ data: AVDepthData, camera: ARCamera, cameraToFace: simd_float4x4) -> DepthFrame {
        let depth = data.depthDataType == kCVPixelFormatType_DepthFloat32 ? data : data.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let map = depth.depthDataMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map), rowBytes = CVPixelBufferGetBytesPerRow(map)
        var values = [Float](repeating: 0, count: w * h)
        if let base = CVPixelBufferGetBaseAddress(map) {
            values.withUnsafeMutableBytes { dst in
                for v in 0 ..< h { memcpy(dst.baseAddress! + v * w * 4, base + v * rowBytes, w * 4) }
            }
        }
        // Prefer the depth map's own calibration; fall back to the colour camera's, scaled to the depth map.
        let k: simd_float3x3, refSize: CGSize, source: String
        if let calibration = depth.cameraCalibrationData {
            (k, refSize, source) = (calibration.intrinsicMatrix, calibration.intrinsicMatrixReferenceDimensions, "calib")
        } else {
            (k, refSize, source) = (camera.intrinsics, camera.imageResolution, "camera")
        }
        let sx = Float(w) / Float(refSize.width), sy = Float(h) / Float(refSize.height)
        work.depthInfo = "\(w)×\(h) \(source)"
        return DepthFrame(width: w, height: h, depth: values,
                          intrinsics: Intrinsics(fx: k[0][0] * sx, fy: k[1][1] * sy, cx: k[2][0] * sx, cy: k[2][1] * sy),
                          cameraToFace: cameraToFace)
    }

    private static func position(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }
}

struct SweepView: UIViewRepresentable {
    let scanner: SweepScanner

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView()
        view.delegate = scanner
        view.session.delegate = scanner
        scanner.session = view.session
        view.session.run(ARFaceTrackingConfiguration(), options: [.resetTracking, .removeExistingAnchors])
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {}

    static func dismantleUIView(_ view: ARSCNView, coordinator: ()) {
        view.session.pause()
    }
}
