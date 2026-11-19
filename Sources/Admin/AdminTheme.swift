import AppKit
import SwiftUI

// The main app's look (Sources/AutoApplicator/Theme.swift, Components.swift), as much of it as this tool needs: a white
// page, white cards with a hairline edge, one bright green for the main button and whatever is selected.

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) { self.init(nsColor: NSColor(hex: hex, alpha: alpha)) }

    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

enum Palette {
    static let canvas = Color.adaptive(0xFFFFFF, 0x131313)
    static let surface = Color.adaptive(0xFFFFFF, 0x1F1F1F)
    static let sunken = Color.adaptive(0xF5F6F8, 0x282828)
    static let line = Color.adaptive(0xEBEBEB, 0x333333)
    static let lineStrong = Color.adaptive(0xDADCE0, 0x454545)
    static let edge = Color.adaptive(0xE3E3E3, 0x383838)
    static let ink = Color.adaptive(0x000000, 0xFFFFFF)
    static let text = Color.adaptive(0x1E1E23, 0xEDEDED)
    static let textSoft = Color.adaptive(0x737373, 0xA8A8A8)
    static let textFaint = Color.adaptive(0x9A9A9A, 0x707070)
    static let green = Color(hex: 0x03C75A)
    static let greenDeep = Color.adaptive(0x009F4B, 0x2FD67A)
    static let greenPressed = Color(hex: 0x03A94D)
    static let greenWash = Color.adaptive(0xEAF9F0, 0x15291D)
    static let blue = Color.adaptive(0x2F7DF6, 0x5A9BFF)
    static let blueWash = Color.adaptive(0xEDF4FF, 0x17233A)
    static let amber = Color.adaptive(0xF08C00, 0xFFA733)
    static let amberWash = Color.adaptive(0xFFF4E2, 0x2D2312)
    static let red = Color.adaptive(0xEE5353, 0xFF6B6B)
    static let redWash = Color.adaptive(0xFDEDED, 0x2F1819)
}

enum Tone {
    case neutral, green, blue, amber, red

    var color: Color {
        switch self {
        case .neutral: Palette.textSoft
        case .green: Palette.greenDeep
        case .blue: Palette.blue
        case .amber: Palette.amber
        case .red: Palette.red
        }
    }

    var wash: Color {
        switch self {
        case .neutral: Palette.sunken
        case .green: Palette.greenWash
        case .blue: Palette.blueWash
        case .amber: Palette.amberWash
        case .red: Palette.redWash
        }
    }
}

enum Typo {
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy) }
    static func heading(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy) }
    static let body = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 13, weight: .bold)
    static let small = Font.system(size: 12)
    static let eyebrow = Font.system(size: 12, weight: .bold)
    static let code = Font.system(size: 11.5, design: .monospaced)
}

/// A content box: white, a 1-pt grey edge, 8-pt corners.
struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.surface).shadow(color: .black.opacity(0.04), radius: 2, y: 1)
            }
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.edge))
    }
}

/// A small coloured label: "Revoked", "Running now".
struct Pill: View {
    var text: String
    var tone: Tone = .neutral
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(tone.wash))
    }
}

/// The green button.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7.5)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isEnabled ? (configuration.isPressed ? Palette.greenPressed : Palette.green) : Palette.textFaint.opacity(0.5)))
            .contentShape(Rectangle())
    }
}

/// A white button with a grey edge (red text for the ones that take something away).
struct SecondaryButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(destructive ? Palette.red : Palette.text)
            .opacity(isEnabled ? 1 : 0.45)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(configuration.isPressed ? Palette.line : Palette.surface))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.lineStrong))
            .contentShape(Rectangle())
    }
}

/// A card's heading with a line of explanation under it.
struct CardTitle: View {
    var title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Typo.heading(15)).foregroundStyle(Palette.ink)
            if let detail { Text(detail).font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// "Region    us-east-1": a labelled value, which can be selected to copy.
struct Fact: View {
    var label: String
    var value: String
    var code = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(Typo.small).foregroundStyle(Palette.textSoft).frame(width: 130, alignment: .leading)
            Text(value).font(code ? Typo.code : Typo.body).foregroundStyle(Palette.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

extension Date {
    /// "2 hours ago".
    var ago: String {
        if abs(timeIntervalSinceNow) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
