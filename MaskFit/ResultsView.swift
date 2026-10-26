import SwiftUI
import UIKit

/// Results: the measurements on a reference head and mask, and scale advice for a mask the user measures.
struct ResultsView: View {
    let summary: SweepScanner.Summary
    let scanAgain: () -> Void

    @State private var type = MaskType.full
    @State private var selected = MaskType.full.main
    @State private var padding: Float = 4
    @State private var inputs: [Letter: String] = [:]
    @State private var copied = false
    @FocusState private var focused: Letter?

    /// Face measurements from the depth scan, or ARKit's mesh where the scan found none; to 0.1 mm.
    private var face: [Letter: Float] {
        var out: [Letter: Float] = [:]
        for row in summary.rows {
            if let letter = Letter(rawValue: row.id), let mm = row.depth ?? row.mesh { out[letter] = mm.rounded1 }
        }
        return out
    }

    private var sizing: MaskSizing {
        MaskSizing(face: face, type: type, padding: padding,
                   mask: inputs.compactMapValues { Float($0.replacingOccurrences(of: ",", with: ".")) })
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("\(Int(summary.coverage * 100))% sweep · \(summary.points.formatted()) depth points")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if summary.timedOut {
                        Callout(title: "The scan didn't fully settle",
                                text: "Some measurements were still changing when it stopped. Scan again, turning your head slowly all the way round.")
                    }
                    diagrams
                    measurements
                    sizeAMask.id("sizing")
                    tips.id("tips")
                    actions
                    details
                }
                .padding()
            }
            .onAppear {
                // Development: `-demoResults -demoScroll <sizing|measure|tips>` opens scrolled to a section
                // with sample mask measurements, for checking the screen in the Simulator.
                let args = ProcessInfo.processInfo.arguments
                guard let i = args.firstIndex(of: "-demoScroll"), i + 1 < args.count else { return }
                inputs = [.c: "128", .a: "57", .e: "34"]
                DispatchQueue.main.async { proxy.scrollTo(args[i + 1], anchor: .top) }
            }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Your measurements")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil }
                }
            }
            .onChange(of: focused) { _, field in
                if let field { selected = field }
            }
        }
    }

    // MARK: Sections

    private var diagrams: some View {
        let side = selected == .e
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                DiagramPanel(caption: side ? "Your face, side" : "Your face", image: side ? "face_side" : "face_front",
                             dims: side ? Diagram.faceSide : Diagram.faceFront, selected: selected,
                             description: side ? "Side view of a head" : "Front view of a head")
                DiagramPanel(caption: side ? "The mask, cut in half" : "The mask", image: side ? "mask_section" : "mask_front",
                             dims: side ? Diagram.maskSection : Diagram.maskFront, selected: selected,
                             description: side ? "A full-face mask cut in half" : "Front view of a full-face mask")
            }
            Text("Same letter, same spot. Mask sizes are taken on the inside surface, the side that touches your face. Pick a measurement below to highlight it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private var measurements: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Measurements").font(.headline)
            ForEach(Letter.allCases) { letter in
                Button { selected = letter } label: {
                    MeasurementRow(letter: letter, value: face[letter], selected: letter == selected,
                                   tag: letter == type.main ? "Main" : type.checks.contains(letter) ? "Check" : nil)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(letter == selected ? .isSelected : [])
            }
        }
    }

    private var sizeAMask: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Size a mask").font(.headline)
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("1 · What kind of mask?").font(.subheadline.weight(.semibold))
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(MaskType.allCases) { option in
                            OptionButton(title: option.title, subtitle: option.subtitle, on: option == type) {
                                type = option
                                selected = option.main
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("2 · Padding inside the mask").font(.subheadline.weight(.semibold))
                    HStack(spacing: 8) {
                        ForEach([(Float(2), "None", "2 mm air gap"), (4, "Thin foam", "4 mm"), (6, "Thick foam", "6 mm")], id: \.0) { option in
                            OptionButton(title: option.1, subtitle: option.2, on: option.0 == padding) { padding = option.0 }
                        }
                    }
                    Text("If the designer says they already left room for padding, pick None.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("3 · Measure the mask").font(.subheadline.weight(.semibold)).id("measure")
                    Text("Main measurement for \(type.phrase): \(type.main.rawValue) · \(type.main.name).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    maskField(type.main, large: true)
                    Text("Measure it in Bambu Studio with the Measure tool, on the inside surface.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                if let scale = sizing.mainScale {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SCALE THE MASK TO").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(scale.pctText)
                            .font(.system(size: 52, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(.tint)
                        if let working = sizing.working {
                            Text(working).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Text("Enter the mask measurement to see the scale.").font(.subheadline).foregroundStyle(.secondary)
                }
                if sizing.looksWrong {
                    Callout(title: nil, text: "That's a big change. Check you measured the inside of the mask, in millimetres.")
                }
                if !type.checks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Divider()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Check measurements (optional)").font(.subheadline.weight(.semibold))
                            Text("Add one to catch a mask made for a face with different proportions.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(sizing.checks, id: \.letter) { check in
                            VStack(alignment: .leading, spacing: 4) {
                                maskField(check.letter, large: false)
                                Text(check.status)
                                    .font(.footnote.weight(check.isProblem ? .semibold : .regular))
                                    .foregroundStyle(check.isProblem ? Color.warning : .secondary)
                            }
                        }
                    }
                }
                if let text = sizing.disagreement { Callout(title: "Measurements disagree", text: text) }
                if let text = sizing.noseWarning { Callout(title: "Your nose won't clear", text: text) }
                if let text = sizing.hardwareNote {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Hardware changes size too").font(.subheadline.weight(.semibold))
                            Text(text).font(.subheadline).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "wrench.and.screwdriver")
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 10))
                }
                Text("In Bambu Studio: select the mask, press S for Scale, keep the lock on so all three axes match, then enter the percentage.")
                    .font(.subheadline)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemGroupedBackground), in: .rect(cornerRadius: 10))
            }
            .card()
        }
    }

    private var tips: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Before you print").font(.headline)
            Label {
                Text("**Measure the inside surface.** That's the side that touches your face. Measuring the outside makes the mask print too small.")
            } icon: {
                Image(systemName: "ruler")
            }
            Label {
                Text("**Print a test strip first.** In Bambu Studio, use Cut to print just the band at eye level, then try it on.")
            } icon: {
                Image(systemName: "scissors")
            }
        }
        .font(.subheadline)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                UIPasteboard.general.string = Letter.allCases.map { "\($0.rawValue) \($0.name): \(face[$0].map { String(format: "%.1f", $0) } ?? "–") mm" }.joined(separator: "\n")
                copied = true
            } label: {
                Text(copied ? "Copied" : "Copy measurements").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            Button(action: scanAgain) {
                Text("Scan again").font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
        }
    }

    /// Development details: depth vs ARKit mesh, and the scan's own numbers.
    private var details: some View {
        DisclosureGroup("Scan details") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(summary.rows) { row in
                    HStack {
                        Text("\(row.id) \(row.name)")
                        Spacer()
                        Text("depth \(row.depth?.mmText ?? "–") · mesh \(row.mesh?.mmText ?? "–")").monospacedDigit()
                    }
                }
                Text("\(Device.summary)\n\(summary.depthInfo) · \(summary.convention) · fit \(summary.alignmentMM.isNaN ? "–" : String(format: "%.1f mm", summary.alignmentMM))\(summary.timedOut ? " · timed out" : "")")
                    .foregroundStyle(.secondary)
                Button("Copy as CSV") { UIPasteboard.general.string = csv }
            }
            .font(.footnote)
            .padding(.top, 8)
        }
        .font(.subheadline)
    }

    private func maskField(_ letter: Letter, large: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(letter.rawValue) on your mask: \(letter.onMask)").font(large ? .subheadline : .footnote)
            HStack(spacing: 10) {
                TextField(large ? "e.g. 116" : "Optional", text: Binding(get: { inputs[letter] ?? "" }, set: { inputs[letter] = $0 }))
                    .keyboardType(.decimalPad)
                    .focused($focused, equals: letter)
                    .font(.system(large ? .title2 : .body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .frame(height: large ? 52 : 44)
                    .background(Color(.systemBackground), in: .rect(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(.separator)))
                    .accessibilityLabel("\(letter.rawValue), \(letter.onMask), in millimetres")
                Text("mm").foregroundStyle(.secondary)
            }
        }
    }

    /// One header line and one data line, so scans from several people paste into one sheet.
    private var csv: String {
        let ids = summary.rows.map(\.id)
        let f = { (v: Float?) in v.map { String(format: "%.1f", $0) } ?? "" }
        let header = ["date", "device", "build"] + ids + ids.map { "mesh" + $0 }
            + ["points", "coverage", "fitMM", "orientation", "depth", "timedOut"]
        let row = [ISO8601DateFormatter().string(from: .now), Device.model, Device.isAppClip ? "clip" : "app"]
            + summary.rows.map { f($0.depth) } + summary.rows.map { f($0.mesh) }
            + ["\(summary.points)", String(format: "%.2f", summary.coverage), f(summary.alignmentMM.isNaN ? nil : summary.alignmentMM),
               summary.convention, summary.depthInfo, summary.timedOut ? "1" : "0"]
        return header.joined(separator: ",") + "\n" + row.joined(separator: ",")
    }
}

// MARK: Pieces

private struct MeasurementRow: View {
    let letter: Letter
    let value: Float?
    let selected: Bool
    let tag: String?

    var body: some View {
        HStack(spacing: 12) {
            Text(letter.rawValue)
                .font(.subheadline.weight(.semibold).monospaced())
                .frame(width: 32, height: 32)
                .background(selected ? Color.accentColor : Color(.tertiarySystemFill), in: .circle)
                .foregroundStyle(selected ? .white : .primary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(letter.name).font(.subheadline.weight(.semibold))
                    if let tag {
                        Text(tag)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(tag == "Main" ? Color.accentColor : Color(.tertiarySystemFill), in: .capsule)
                            .foregroundStyle(tag == "Main" ? .white : .primary)
                    }
                }
                Text(letter.onFace).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Text(value.map { String(format: "%.1f mm", $0) } ?? "–").font(.body.monospacedDigit())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minHeight: 64)
        .background(selected ? Color.accentColor.opacity(0.12) : Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? Color.accentColor : Color(.separator)))
        .contentShape(.rect)
    }
}

private struct OptionButton: View {
    let title: String
    let subtitle: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .padding(.horizontal, 10)
            .background(on ? Color.accentColor.opacity(0.12) : Color(.systemBackground), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? Color.accentColor : Color(.separator)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct Callout: View {
    let title: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title { Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.warning) }
            Text(text).font(.subheadline)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.warning.opacity(0.12), in: .rect(cornerRadius: 10))
    }
}

/// One render with its lettered dimension lines drawn on top.
private struct DiagramPanel: View {
    let caption: String
    let image: String
    let dims: [Diagram.Dim]
    let selected: Letter
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption).font(.footnote.weight(.semibold))
            Image(uiImage: Bundle.main.path(forResource: image, ofType: "webp").flatMap(UIImage.init(contentsOfFile:)) ?? UIImage())
                .resizable()
                .aspectRatio(Diagram.size.width / Diagram.size.height, contentMode: .fit)
                .overlay { Canvas { context, size in Diagram.draw(dims, selected: selected, in: context, size: size) } }
                .background(Color(white: 0.957))
                .clipShape(.rect(cornerRadius: 10))
                .accessibilityElement()
                .accessibilityLabel("\(description), with measurement \(selected.rawValue) highlighted")
        }
        .frame(maxWidth: .infinity)
    }
}

/// Dimension lines for the renders made by Tools/render.py, in the renders' 540×690 pixel space, placed
/// on the head's computed landmarks (pupils, cheekbones, nose bridge, nose tip, chin).
enum Diagram {
    struct Dim {
        let letter: Letter
        let lines: [(CGPoint, CGPoint)]
        var dashed: [(CGPoint, CGPoint)] = []
        let badge: CGPoint
    }

    static let size = CGSize(width: 540, height: 690)

    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    /// A horizontal dimension from x0 to x1 at y, with end ticks.
    private static func across(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat) -> [(CGPoint, CGPoint)] {
        [(p(x0, y), p(x1, y)), (p(x0, y - 16), p(x0, y + 16)), (p(x1, y - 16), p(x1, y + 16))]
    }

    /// A vertical dimension from y0 to y1 at x, with end ticks.
    private static func down(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) -> [(CGPoint, CGPoint)] {
        [(p(x, y0), p(x, y1)), (p(x - 16, y0), p(x + 16, y0)), (p(x - 16, y1), p(x + 16, y1))]
    }

    static let faceFront: [Dim] = [
        Dim(letter: .b, lines: across(104, 436, 352), badge: p(140, 352)),
        Dim(letter: .c, lines: down(270, 323, 595), badge: p(270, 548)),
        Dim(letter: .d, lines: down(228, 323, 409), dashed: [(p(244, 323), p(266, 323)), (p(244, 409), p(266, 409))], badge: p(228, 366)),
        Dim(letter: .a, lines: across(196, 344, 331), badge: p(270, 288)),
    ]

    static let maskFront: [Dim] = [
        Dim(letter: .b, lines: across(90, 450, 352), badge: p(128, 352)),
        Dim(letter: .c, lines: down(270, 323, 607), badge: p(270, 558)),
        Dim(letter: .d, lines: down(228, 323, 412), dashed: [(p(244, 323), p(266, 323)), (p(244, 412), p(266, 412))], badge: p(228, 367)),
        Dim(letter: .a, lines: across(196, 344, 331), badge: p(270, 288)),
    ]

    static let faceSide: [Dim] = [
        Dim(letter: .e, lines: across(396, 458, 397), dashed: [(p(396, 335), p(396, 460))], badge: p(358, 397)),
    ]

    static let maskSection: [Dim] = [
        Dim(letter: .e, lines: across(405, 466, 399), dashed: [(p(405, 337), p(405, 462))], badge: p(367, 399)),
    ]

    static func draw(_ dims: [Dim], selected: Letter, in context: GraphicsContext, size: CGSize) {
        let s = size.width / Self.size.width
        let at = { (q: CGPoint) in CGPoint(x: q.x * s, y: q.y * s) }
        let ink = Color(red: 0.23, green: 0.25, blue: 0.29)
        // The panel stays light in dark mode, so these colours are fixed rather than adaptive.
        for dim in dims.sorted(by: { $1.letter == selected && $0.letter != selected }) {
            let on = dim.letter == selected
            let colour = on ? Color.accentColor : ink.opacity(0.55)
            for (a, b) in dim.lines {
                context.stroke(Path { $0.move(to: at(a)); $0.addLine(to: at(b)) }, with: .color(colour),
                               style: StrokeStyle(lineWidth: (on ? 7 : 3.5) * s, lineCap: .round))
            }
            for (a, b) in dim.dashed {
                context.stroke(Path { $0.move(to: at(a)); $0.addLine(to: at(b)) }, with: .color(colour),
                               style: StrokeStyle(lineWidth: (on ? 4 : 3) * s, dash: [6 * s, 7 * s]))
            }
            let r = 26 * s
            let badge = Path(ellipseIn: CGRect(x: at(dim.badge).x - r, y: at(dim.badge).y - r, width: 2 * r, height: 2 * r))
            context.fill(badge, with: .color(on ? .accentColor : .white))
            context.stroke(badge, with: .color(on ? .white : ink.opacity(0.55)), lineWidth: (on ? 4 : 3.5) * s)
            context.draw(Text(dim.letter.rawValue)
                .font(.system(size: 32 * s, weight: .semibold, design: .monospaced))
                .foregroundStyle(on ? Color.white : ink), at: at(dim.badge))
        }
    }
}

private extension View {
    func card() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
    }
}

extension Color {
    /// Warning text and tint: dark orange in light mode, light orange in dark mode, both readable as text.
    static let warning = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.62, blue: 0.4, alpha: 1)
            : UIColor(red: 0.71, green: 0.25, blue: 0.05, alpha: 1)
    })
}
