import Foundation

/// The five face measurements, lettered as on the results screen.
enum Letter: String, CaseIterable, Identifiable {
    case a = "A", b = "B", c = "C", d = "D", e = "E"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .a: "Eye spacing"
        case .b: "Face width"
        case .c: "Face length"
        case .d: "Nose length"
        case .e: "Nose depth"
        }
    }

    var onFace: String {
        switch self {
        case .a: "Pupil to pupil"
        case .b: "Across the cheekbones"
        case .c: "Nose bridge to chin"
        case .d: "Nose bridge to nose tip"
        case .e: "Nose tip in front of the cheeks"
        }
    }

    var onMask: String {
        switch self {
        case .a: "centre to centre of the eye holes"
        case .b: "inside width at cheekbone level"
        case .c: "inside, nose bridge to chin"
        case .d: "inside, nose bridge to nose tip"
        case .e: "depth of the nose space inside"
        }
    }

    /// Padding layers inside this distance: width has one on each side, length one at the chin. Padding
    /// shifts both ends of A, D and E equally, and eye holes must line up with the eyes anyway.
    var paddingLayers: Float {
        switch self {
        case .b: 2
        case .c: 1
        case .a, .d, .e: 0
        }
    }

    /// "3.6 mm narrower": how this distance on the mask compares with what the face needs.
    func difference(_ mm: Float) -> String {
        let words: (more: String, less: String) = switch self {
        case .a, .b: ("wider", "narrower")
        case .c, .d: ("longer", "shorter")
        case .e: ("deeper", "shallower")
        }
        return "\(abs(mm).rounded1.mmText) mm \(mm > 0 ? words.more : words.less)"
    }
}

enum MaskType: String, CaseIterable, Identifiable {
    case eye, half, full, wrap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .eye: "Eye mask"
        case .half: "Half mask"
        case .full: "Full face"
        case .wrap: "Wraparound"
        }
    }

    var subtitle: String {
        switch self {
        case .eye: "Around the eyes"
        case .half: "Forehead to nose"
        case .full: "Forehead to chin"
        case .wrap: "Past the cheekbones"
        }
    }

    var phrase: String {
        switch self {
        case .eye: "an eye mask"
        case .half: "a half mask"
        case .full: "a full-face mask"
        case .wrap: "a wraparound mask"
        }
    }

    /// The measurement to scale by. Face width only works for masks that wrap past the cheekbones;
    /// a shallower mask can be narrower inside than the face.
    var main: Letter {
        switch self {
        case .eye, .half: .a
        case .full: .c
        case .wrap: .b
        }
    }

    var checks: [Letter] {
        switch self {
        case .eye: []
        case .half: [.d, .e]
        case .full: [.a, .e]
        case .wrap: [.c, .a, .e]
        }
    }
}

/// Scale advice for one mask, from the face measurements and what the user measured inside the mask (mm).
struct MaskSizing {
    struct Check {
        let letter: Letter
        let status: String
        let isProblem: Bool
    }

    let face: [Letter: Float]
    let type: MaskType
    let padding: Float
    let mask: [Letter: Float]

    func target(_ l: Letter) -> Float? { face[l].map { $0 + l.paddingLayers * padding } }

    func scale(_ l: Letter) -> Float? {
        guard let t = target(l), let m = mask[l], m > 0 else { return nil }
        return (t / m * 100).rounded1
    }

    var mainScale: Float? { scale(type.main) }

    /// "Your 119 mm + 4 mm padding = 123 mm, ÷ 116 mm on the mask"
    var working: String? {
        let l = type.main
        guard let f = face[l], let m = mask[l], let t = target(l), m > 0 else { return nil }
        let pad = l.paddingLayers == 0 ? "" : (l.paddingLayers == 2 ? " + 2 × " : " + ") + "\(padding.mmText) mm padding = \(t.mmText) mm"
        return "Your \(f.mmText) mm\(pad), ÷ \(m.mmText) mm on the mask"
    }

    var looksWrong: Bool { mainScale.map { $0 < 50 || $0 > 200 } ?? false }

    var checks: [Check] {
        type.checks.map { l in
            guard let main = mainScale, let f = face[l], let m = mask[l], m > 0, let s = scale(l) else {
                return Check(letter: l, status: "Optional", isProblem: false)
            }
            if l == .e {  // a minimum: the nose space must be at least as deep as the nose
                let need = (f / m * 100).rounded1
                return main < need
                    ? Check(letter: l, status: "Too shallow: needs at least \(need.pctText)", isProblem: true)
                    : Check(letter: l, status: "Clears your nose at \(main.pctText)", isProblem: false)
            }
            let diff = abs(s / main - 1) * 100
            let verdict = diff <= 3 ? "agrees" : diff > 5 ? "disagrees by \(Int(diff.rounded()))%" : "close enough"
            return Check(letter: l, status: "Suggests \(s.pctText) · \(verdict)", isProblem: diff > 5)
        }
    }

    /// When a check points more than 5% away from the main measurement, the mask was made for a face with
    /// different proportions. The scale still stays even, so the mask keeps the look its designer gave it
    /// (scaling width and height separately would change it); this says what matching either one costs.
    var disagreement: String? {
        guard let main = mainScale else { return nil }
        let worst = type.checks.filter { $0 != .e }
            .compactMap { l in scale(l).map { (letter: l, scale: $0, diff: abs($0 / main - 1) * 100) } }
            .filter { $0.diff > 5 }
            .max { $0.diff < $1.diff }
        let m = type.main
        guard let worst, let maskMain = mask[m], let maskOther = mask[worst.letter],
              let needMain = target(m), let needOther = target(worst.letter) else { return nil }
        let o = worst.letter
        return "\(m.rawValue) and \(o.rawValue) disagree by \(Int(worst.diff.rounded()))%, so this mask was made for a face with different proportions. Keep the scale even so the mask keeps its look, and choose which to match: at \(main.pctText) its \(o.name.lowercased()) (\(o.rawValue)) is \(o.difference(maskOther * main / 100 - needOther)) than you need; at \(worst.scale.pctText) its \(m.name.lowercased()) (\(m.rawValue)) is \(m.difference(maskMain * worst.scale / 100 - needMain)) than you need."
    }

    var noseWarning: String? {
        guard let main = mainScale, type.checks.contains(.e), let f = face[.e], let m = mask[.e], m > 0 else { return nil }
        let need = (f / m * 100).rounded1
        guard main < need else { return nil }
        return "At \(main.pctText) the nose space is \((m * main / 100).rounded1.mmText) mm deep, and your nose needs \(f.mmText) mm. Scale to at least \(need.pctText)."
    }

    var hardwareNote: String? {
        guard let main = mainScale, abs(main - 100) >= 1 else { return nil }
        return "Scaling to \(main.pctText) also resizes magnet pockets, strap slots and screw holes: a 6 mm magnet pocket becomes \((6 * main / 100).rounded1.mmText) mm and a 2 mm wall becomes \((2 * main / 100).rounded1.mmText) mm. Check the designer's notes for hardware sizes before printing."
    }
}

extension Float {
    var rounded1: Float { (self * 10).rounded() / 10 }
    /// "106" or "106.3"
    var mmText: String { self == rounded() ? String(format: "%.0f", self) : String(format: "%.1f", self) }
    var pctText: String { mmText + "%" }
}
