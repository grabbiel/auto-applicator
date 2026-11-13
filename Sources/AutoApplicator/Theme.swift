import AppKit
import Engine
import SwiftUI

// The look, after naver.com: a white page, content in white cards with a hairline edge and 8-pt corners, one bright
// green (#03C75A) for the search box, the main button and whatever is selected, heavy black headings and grey
// secondary text in SF Pro. Dark mode follows Naver's dark surfaces (#131313 page, #1F1F1F cards).

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
    static let raised = Color.adaptive(0xFFFFFF, 0x2D2D2D)
    /// Grey bars inside cards (Naver's sub-headers) and quiet backgrounds.
    static let sunken = Color.adaptive(0xF5F6F8, 0x282828)
    static let line = Color.adaptive(0xEBEBEB, 0x333333)
    static let lineStrong = Color.adaptive(0xDADCE0, 0x454545)
    /// A card's edge: Naver draws it as a 1-pt 10% black ring.
    static let edge = Color.adaptive(0xE3E3E3, 0x383838)
    static let ink = Color.adaptive(0x000000, 0xFFFFFF)
    static let text = Color.adaptive(0x1E1E23, 0xEDEDED)
    static let textSoft = Color.adaptive(0x737373, 0xA8A8A8)
    static let textFaint = Color.adaptive(0x9A9A9A, 0x707070)

    static let green = Color(hex: 0x03C75A)
    /// Green for text and small marks: dark enough to read on white.
    static let greenDeep = Color.adaptive(0x009F4B, 0x2FD67A)
    static let greenPressed = Color(hex: 0x03A94D)
    static let greenWash = Color.adaptive(0xEAF9F0, 0x15291D)
    static let blue = Color.adaptive(0x2F7DF6, 0x5A9BFF)
    static let blueWash = Color.adaptive(0xEDF4FF, 0x17233A)
    static let amber = Color.adaptive(0xF08C00, 0xFFA733)
    static let amberWash = Color.adaptive(0xFFF4E2, 0x2D2312)
    static let red = Color.adaptive(0xEE5353, 0xFF6B6B)
    static let redWash = Color.adaptive(0xFDEDED, 0x2F1819)
    static let violet = Color.adaptive(0x5A6DFE, 0x8291FF)
    static let violetWash = Color.adaptive(0xEEF0FF, 0x1E2038)
    static let teal = Color.adaptive(0x0BA5A5, 0x34C8C8)

    /// Toasts and other floating notes: Naver's near-black.
    static let toast = Color(hex: 0x303038)
}

enum Tone {
    case neutral, green, blue, amber, red, violet

    var color: Color {
        switch self {
        case .neutral: Palette.textSoft
        case .green: Palette.greenDeep
        case .blue: Palette.blue
        case .amber: Palette.amber
        case .red: Palette.red
        case .violet: Palette.violet
        }
    }

    var wash: Color {
        switch self {
        case .neutral: Palette.sunken
        case .green: Palette.greenWash
        case .blue: Palette.blueWash
        case .amber: Palette.amberWash
        case .red: Palette.redWash
        case .violet: Palette.violetWash
        }
    }
}

enum Typo {
    /// Page titles and big statements: heavy, like Naver's 800-weight headings.
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .heavy) }
    /// Card and section headings.
    static func heading(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font { .system(size: size, weight: weight) }
    static func number(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font { .system(size: size, weight: weight).monospacedDigit() }
    static let body = Font.system(size: 13)
    static let bodyStrong = Font.system(size: 13, weight: .bold)
    static let small = Font.system(size: 12)
    static let label = Font.system(size: 12.5, weight: .semibold)
    static let eyebrow = Font.system(size: 12, weight: .bold)
}

extension JobStatus {
    var tone: Tone {
        switch self {
        case .applied: .green
        case .practiceComplete: .blue
        case .needsAnswer: .amber
        case .failedForm, .failedOTPTimeout: .red
        case .skippedBlacklist, .skippedTitleFilter, .skippedAlreadyApplied: .neutral
        }
    }

    var symbol: String {
        switch self {
        case .applied: "paperplane.fill"
        case .practiceComplete: "checkmark.seal"
        case .needsAnswer: "questionmark.bubble"
        case .failedForm, .failedOTPTimeout: "exclamationmark.triangle"
        case .skippedBlacklist, .skippedTitleFilter: "line.3.horizontal.decrease"
        case .skippedAlreadyApplied: "checkmark"
        }
    }
}
