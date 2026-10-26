import ARKit
import SwiftUI

@main
struct MaskFitApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

enum Device {
    static var model: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static var isAppClip: Bool { Bundle.main.bundleIdentifier?.hasSuffix(".Clip") == true }

    @MainActor static var summary: String {
        let tracking = ARFaceTrackingConfiguration.isSupported ? "supported" : "NOT supported"
        return "\(model) · iOS \(UIDevice.current.systemVersion) · \(isAppClip ? "App Clip" : "full app") · face tracking \(tracking)"
    }
}

struct ContentView: View {
    @State private var scanner = SweepScanner()

    var body: some View {
        if ProcessInfo.processInfo.arguments.contains("-demoResults") {
            // Launch argument for checking the results screen (and screenshots) without scanning.
            ResultsView(summary: .demo) {}
        } else if !ARFaceTrackingConfiguration.isSupported {
            ContentUnavailableView("Face tracking unavailable", systemImage: "faceid",
                                   description: Text("This needs an iPhone with Face ID.\n\(Device.summary)"))
        } else if let summary = scanner.summary {
            ResultsView(summary: summary) { scanner = SweepScanner() }
        } else {
            ScanScreen(scanner: scanner).id(ObjectIdentifier(scanner))
        }
    }
}

struct ScanScreen: View {
    let scanner: SweepScanner

    var body: some View {
        ZStack {
            SweepView(scanner: scanner).ignoresSafeArea()
            ProgressRing(covered: scanner.covered)
                .frame(width: 310, height: 310)
                .animation(.easeOut(duration: 0.25), value: scanner.covered)
            VStack(spacing: 12) {
                Text(scanner.hint)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: .rect(cornerRadius: 14))
                Spacer()
                if !scanner.started {
                    Button(action: scanner.start) {
                        Text("Start").font(.headline).frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 14))
                } else {
                    VStack(spacing: 8) {
                        HStack(spacing: 0) {
                            ForEach(scanner.live) { value in
                                VStack(spacing: 2) {
                                    HStack(spacing: 3) {
                                        Text(value.id).font(.caption.weight(.bold).monospaced())
                                        if value.settled {
                                            Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.tint)
                                        }
                                    }
                                    Text(value.mm.map { String(format: "%.1f", $0) } ?? "–")
                                        .font(.callout.monospacedDigit())
                                }
                                .frame(maxWidth: .infinity)
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel("\(value.name) \(value.mm.map { String(format: "%.1f millimetres", $0) } ?? "not measured yet")\(value.settled ? ", settled" : "")")
                            }
                        }
                        Text(scanner.debug)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .padding(12)
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
                }
            }
            .padding()
        }
    }
}

/// Face ID-style ring: a tick lights up once the head has been turned that way.
struct ProgressRing: View {
    let covered: [Bool]

    var body: some View {
        GeometryReader { geo in
            let radius = min(geo.size.width, geo.size.height) / 2
            ZStack {
                ForEach(covered.indices, id: \.self) { i in
                    Capsule()
                        .fill(covered[i] ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.45)))
                        .frame(width: 5, height: covered[i] ? 22 : 16)
                        .offset(y: -radius + 11)
                        .rotationEffect(.degrees((Double(i) + 0.5) * 360 / Double(covered.count)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Scan coverage \(covered.filter { $0 }.count * 100 / max(1, covered.count)) percent")
    }
}
