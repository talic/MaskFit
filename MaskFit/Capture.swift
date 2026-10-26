import ARKit
import AVFoundation

/// Development recorder: saves raw depth frames with every camera and head detail to Documents/capture,
/// so the depth-to-face alignment can be tuned on the Mac. Pull it with:
///   xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
///     --domain-identifier com.armintalic.MaskFit --source Documents/capture --destination <folder>
/// ponytail: remove before release; it writes ~50 MB per scan.
enum Capture {
    struct Frame: Codable {
        var time: Double
        var depthLag: Double                // frame time minus depth capture time
        var width: Int
        var height: Int
        var cameraToFace: [Float]           // 4x4, pose at depth capture time, column-major
        var cameraTransform: [Float]        // 4x4 at frame time
        var faceTransform: [Float]          // 4x4 at frame time
        var cameraIntrinsics: [Float]       // 3x3 colour camera
        var imageResolution: [Float]
        var calibIntrinsics: [Float]?       // 3x3 depth calibration
        var calibReference: [Float]?
        var calibExtrinsics: [Float]?       // 4x3
        var distortionCenter: [Float]?
        var distortionTable: [Float]?
        var mesh: [Float]                   // ARKit face mesh, face space
        var triangles: [Int16]
        var leftEye: [Float]
        var rightEye: [Float]
    }

    static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("capture")
    }

    static func reset() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    static func write(index: Int, frame: DepthFrame, depthData: AVDepthData, camera: ARCamera, face: ARFaceAnchor,
                      time: TimeInterval, depthLag: TimeInterval, eyes: (SIMD3<Float>, SIMD3<Float>)) {
        let cal = depthData.cameraCalibrationData
        let meta = Frame(
            time: time, depthLag: depthLag, width: frame.width, height: frame.height,
            cameraToFace: flat(frame.cameraToFace), cameraTransform: flat(camera.transform), faceTransform: flat(face.transform),
            cameraIntrinsics: flat(camera.intrinsics),
            imageResolution: [Float(camera.imageResolution.width), Float(camera.imageResolution.height)],
            calibIntrinsics: cal.map { flat($0.intrinsicMatrix) },
            calibReference: cal.map { [Float($0.intrinsicMatrixReferenceDimensions.width), Float($0.intrinsicMatrixReferenceDimensions.height)] },
            calibExtrinsics: cal.map { m in [m.extrinsicMatrix.columns.0, m.extrinsicMatrix.columns.1, m.extrinsicMatrix.columns.2, m.extrinsicMatrix.columns.3].flatMap { [$0.x, $0.y, $0.z] } },
            distortionCenter: cal.map { [Float($0.lensDistortionCenter.x), Float($0.lensDistortionCenter.y)] },
            distortionTable: cal?.lensDistortionLookupTable.map { data in data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } },
            mesh: face.geometry.vertices.flatMap { [$0.x, $0.y, $0.z] }, triangles: face.geometry.triangleIndices,
            leftEye: [eyes.0.x, eyes.0.y, eyes.0.z], rightEye: [eyes.1.x, eyes.1.y, eyes.1.z])
        let name = String(format: "frame_%03d", index)
        try? JSONEncoder().encode(meta).write(to: folder.appendingPathComponent(name + ".json"))
        try? frame.depth.withUnsafeBytes { Data($0) }.write(to: folder.appendingPathComponent(name + ".bin"))
    }

    static func writePoses(_ poses: [(t: TimeInterval, face: simd_float4x4, camera: simd_float4x4)]) {
        let rows = poses.map { [$0.t] + (flat($0.face) + flat($0.camera)).map(Double.init) }
        try? JSONEncoder().encode(rows).write(to: folder.appendingPathComponent("poses.json"))
    }

    private static func flat(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    private static func flat(_ m: simd_float3x3) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2].flatMap { [$0.x, $0.y, $0.z] }
    }
}
