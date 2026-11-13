import AppKit
import SwiftUI

// MARK: - surfaces

/// Naver's content box: white, a 1-pt grey edge, 8-pt corners and the faintest drop.
struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardBackground()
    }
}

extension View {
    func cardBackground(radius: CGFloat = 8) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Palette.surface)
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.edge))
    }
}

/// The page frame: a heavy black title with a grey line under it, then the content, on the white canvas.
struct Page<Content: View, Accessory: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(Typo.display(24)).foregroundStyle(Palette.ink)
                        Text(subtitle).font(Typo.body).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    accessory
                }
                .padding(.bottom, 2)
                content
            }
            .padding(.horizontal, 32)
            .padding(.top, 26)
            .padding(.bottom, 40)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .background(Palette.canvas)
    }
}

extension Page where Accessory == EmptyView {
    init(title: String, subtitle: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

struct SectionTitle: View {
    var title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Typo.heading(16)).foregroundStyle(Palette.ink)
            if let detail { Text(detail).font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// A small bold label over a group, in plain case.
struct Eyebrow: View {
    var text: String
    var color: Color = Palette.textSoft
    init(_ text: String, color: Color = Palette.textSoft) {
        self.text = text
        self.color = color
    }
    var body: some View {
        Text(text).font(Typo.eyebrow).foregroundStyle(color)
    }
}

/// Naver's card tabs: names divided by thin slashes, the chosen one heavy and black, the others grey.
struct TabStrip<T: Hashable>: View {
    var options: [T]
    @Binding var selection: T
    var title: (T) -> String
    var count: (T) -> Int? = { _ in nil }
    var size: CGFloat = 16

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 {
                    Text("/").font(.system(size: size - 3, weight: .light)).foregroundStyle(Palette.lineStrong).padding(.horizontal, 9)
                }
                let on = option == selection
                Button { withAnimation(.snappy(duration: 0.2)) { selection = option } } label: {
                    Hover { hovering in
                        HStack(spacing: 5) {
                            Text(title(option))
                                .font(.system(size: size, weight: on ? .heavy : .semibold))
                                .foregroundStyle(on ? Palette.ink : hovering ? Palette.text : Palette.textSoft)
                            if let n = count(option), n > 0 {
                                Text("\(n)").font(.system(size: size - 3, weight: .bold).monospacedDigit())
                                    .foregroundStyle(on ? Palette.greenDeep : Palette.textFaint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - buttons

/// The green button (Naver's login button): flat green, white heavy text, a light green glow.
struct PrimaryButtonStyle: ButtonStyle {
    var large = false
    var fill = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Hover { hovering in
            configuration.label
                .font(.system(size: large ? 15 : 13, weight: large ? .heavy : .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, large ? 22 : 14)
                .padding(.vertical, large ? 13 : 7.5)
                .frame(maxWidth: fill ? .infinity : nil)
                .background(
                    RoundedRectangle(cornerRadius: large ? 6 : 5, style: .continuous)
                        .fill(isEnabled ? (configuration.isPressed || hovering ? Palette.greenPressed : Palette.green) : Palette.textFaint.opacity(0.5))
                        .shadow(color: Palette.green.opacity(isEnabled ? 0.16 : 0), radius: 2, y: 2)
                )
                .overlay(RoundedRectangle(cornerRadius: large ? 6 : 5, style: .continuous).strokeBorder(.black.opacity(0.06)))
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// A white button with a grey edge.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Hover { hovering in
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.text)
                .opacity(isEnabled ? 1 : 0.45)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(configuration.isPressed ? Palette.line : hovering ? Palette.sunken : Palette.surface)
                )
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.lineStrong))
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// A text link: green by default, underlined on hover.
struct QuietButtonStyle: ButtonStyle {
    var color: Color = Palette.greenDeep

    func makeBody(configuration: Configuration) -> some View {
        Hover { hovering in
            configuration.label
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(color)
                .underline(hovering)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
        }
    }
}

/// Naver's round paging button: a white circle with a grey edge.
struct CircleButtonStyle: ButtonStyle {
    var size: CGFloat = 30

    func makeBody(configuration: Configuration) -> some View {
        Hover { hovering in
            configuration.label
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(Palette.text)
                .frame(width: size, height: size)
                .background(Circle().fill(hovering ? Palette.sunken : Palette.surface))
                .overlay(Circle().strokeBorder(Palette.lineStrong))
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}

/// "See all ›": grey text with a chevron.
struct MoreLink: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Hover { hovering in
                HStack(spacing: 3) {
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(hovering ? Palette.text : Palette.textSoft)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }
}

/// Links in a row with thin bars between them, like Naver's "Find ID | Find password | Sign up".
struct LinkBar: View {
    struct Item: Identifiable {
        var id: String { title }
        var title: String
        var action: () -> Void
    }
    var items: [Item]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Rectangle().fill(Palette.line).frame(width: 1, height: 11).padding(.horizontal, 12) }
                Button(action: item.action) { Text(item.title).lineLimit(1).fixedSize() }
                    .buttonStyle(QuietButtonStyle(color: Palette.textSoft)).padding(.horizontal, -6)
            }
        }
    }
}

/// Gives a view its hover state without a @State in every caller.
struct Hover<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content
    @State private var hovering = false

    var body: some View {
        content(hovering).onHover { hovering = $0 }
    }
}

// MARK: - small pieces

struct Pill: View {
    var text: String
    var tone: Tone = .neutral
    var symbol: String?
    /// White text on the tone's color, like Naver's LIVE and 신작 badges.
    var solid = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(solid ? .white : tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(solid ? tone.color : tone.wash, in: Capsule())
        .overlay { if tone == .neutral && !solid { Capsule().strokeBorder(Palette.line) } }
        .fixedSize()
    }
}

/// A figure with its label, like the numbers in Naver's market widget.
struct StatTile: View {
    var value: String
    var label: String
    var symbol: String
    var tone: Tone

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .bold)).foregroundStyle(tone.color)
                Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.textSoft).lineLimit(1)
            }
            Text(value).font(Typo.number(26, .heavy)).foregroundStyle(Palette.ink).contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A short, friendly note beside a form: what to enter and why.
struct CoachTip: View {
    var title: String?
    var text: LocalizedStringKey
    var symbol = "lightbulb"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(Palette.greenDeep).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                if let title { Text(title).font(Typo.bodyStrong).foregroundStyle(Palette.ink) }
                Text(text).font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true).tint(Palette.greenDeep)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Palette.sunken, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

struct EmptyState: View {
    var symbol: String
    var title: String
    var message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(Palette.greenWash).frame(width: 60, height: 60)
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold)).foregroundStyle(Palette.green)
            }
            Text(title).font(Typo.heading(17)).foregroundStyle(Palette.ink)
            Text(message).font(Typo.body).foregroundStyle(Palette.textSoft).multilineTextAlignment(.center).frame(maxWidth: 380)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}

/// A company's initials on a colored tile (stable color per name).
struct Monogram: View {
    var name: String
    var size: CGFloat = 34

    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        let hues: [Color] = [Palette.green, Palette.blue, Palette.violet, Palette.amber, Palette.teal, Palette.red]
        let color = hues[abs(name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 1_000_003 }) % hues.count]
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.36, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }
}

struct ProgressRing: View {
    var value: Double
    var lineWidth: CGFloat = 10
    var track: Color = Palette.sunken

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(Palette.green, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.8, dampingFraction: 0.85), value: value)
        }
    }
}

/// The brand mark: a white paper plane on a green tile (matches the app icon).
struct BrandMark: View {
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x19D16A), Palette.green], startPoint: .top, endPoint: .bottom))
            PlaneShape()
                .fill(.white)
                .frame(width: size * 0.56, height: size * 0.56)
                .offset(x: -size * 0.02, y: size * 0.02)
        }
        .frame(width: size, height: size)
    }
}

/// The name as a wordmark: heavy, green "Auto", black "Applicator".
struct Wordmark: View {
    var size: CGFloat = 17

    var body: some View {
        (Text("Auto").foregroundStyle(Palette.green) + Text("Applicator").foregroundStyle(Palette.ink))
            .font(.system(size: size, weight: .black))
            .tracking(-0.3)
    }
}

struct PlaneShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        // nose top-right, wings bottom-left, a fold in the middle
        p.move(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.42))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.minY + r.height * 0.6))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.55, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - form controls

/// A label above a control, with an optional hint under it.
struct Field<Content: View>: View {
    var label: String
    var hint: String?
    var optional = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(label).font(Typo.label).foregroundStyle(Palette.text)
                if optional { Text("Optional").font(.system(size: 10.5)).foregroundStyle(Palette.textFaint) }
            }
            content
            if let hint { Text(hint).font(.system(size: 11)).foregroundStyle(Palette.textFaint).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

/// The text box used everywhere: white with a grey edge that turns green while you type (Naver's sign-in fields).
struct InputStyle: ViewModifier {
    var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Typo.body)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(focused ? Palette.green : Palette.lineStrong, lineWidth: focused ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

struct TextInput: View {
    var placeholder: String
    @Binding var text: String
    var secure = false
    var multiline = false
    @FocusState private var focused: Bool

    init(_ placeholder: String, text: Binding<String>, secure: Bool = false, multiline: Bool = false) {
        self.placeholder = placeholder
        _text = text
        self.secure = secure
        self.multiline = multiline
    }

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else if multiline {
                TextField(placeholder, text: $text, axis: .vertical).lineLimit(3...8)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .focused($focused)
        .modifier(InputStyle(focused: focused))
    }
}

/// A whole-number box (salary, years) that keeps an Int? binding.
struct NumberInput: View {
    var placeholder: String
    @Binding var value: Int?
    var prefix: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            if let prefix { Text(prefix).foregroundStyle(Palette.textFaint) }
            TextField(placeholder, text: $text)
                .focused($focused)
                .onChange(of: text) { _, new in
                    let digits = new.filter(\.isNumber)
                    if digits != new { text = digits }
                    value = Int(digits)
                }
        }
        .modifier(InputStyle(focused: focused))
        .onAppear { text = value.map(String.init) ?? "" }
        .onChange(of: value) { _, new in if Int(text) != new { text = new.map(String.init) ?? "" } }
    }
}

/// Years, in half-year steps, as a compact − n + control.
struct YearsStepper: View {
    @Binding var years: Double

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus") { years = max(0, years - (years > 2 ? 1 : 0.5)) }
            Text(years == years.rounded() ? "\(Int(years))" : String(format: "%.1f", years))
                .font(Typo.number(13.5))
                .frame(minWidth: 34)
            stepButton("plus") { years = min(50, years + (years >= 2 ? 1 : 0.5)) }
        }
        .padding(2)
        .background(Palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.lineStrong))
    }

    func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold)).frame(width: 24, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.textSoft)
    }
}

/// Words as removable chips with a box to add more (job titles, companies to avoid).
struct TagEditor: View {
    @Binding var tags: [String]
    var placeholder: String
    var suggestions: [String] = []
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 5) {
                        Text(tag).font(.system(size: 12.5, weight: .medium))
                        Button { withAnimation(.snappy) { tags.removeAll { $0 == tag } } } label: {
                            Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Palette.textFaint)
                        .accessibilityLabel("Remove \(tag)")
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 8)
                    .padding(.vertical, 5)
                    .background(Palette.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.lineStrong))
                }
                TextField(tags.isEmpty ? placeholder : "Add another…", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Typo.body)
                    .focused($focused)
                    .frame(minWidth: 150)
                    .padding(.vertical, 5)
                    .onSubmit(commit)
                    .onChange(of: draft) { _, new in if new.contains(",") { commit() } }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(InputStyle(focused: focused))
            .onTapGesture { focused = true }

            let open = suggestions.filter { s in !tags.contains { $0.lowercased() == s.lowercased() } }
            if !open.isEmpty {
                HStack(spacing: 6) {
                    Text("Ideas:").font(.system(size: 11)).foregroundStyle(Palette.textFaint)
                    ForEach(open.prefix(5), id: \.self) { s in
                        Button("+ \(s)") { withAnimation(.snappy) { tags.append(s) } }.buttonStyle(QuietButtonStyle())
                    }
                }
            }
        }
    }

    private func commit() {
        let parts = draft.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for p in parts where !tags.contains(where: { $0.lowercased() == p.lowercased() }) { tags.append(p) }
        draft = ""
    }
}

/// One or more choices as chips (workplace, experience level).
struct ChipPicker<T: Hashable>: View {
    var options: [T]
    @Binding var selection: [T]
    var title: (T) -> String
    var single = false

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(options, id: \.self) { option in
                let on = selection.contains(option)
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        if single { selection = [option] } else if on { selection.removeAll { $0 == option } } else { selection.append(option) }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if on { Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold)) }
                        Text(title(option)).font(.system(size: 12.5, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6.5)
                    .foregroundStyle(on ? Palette.greenDeep : Palette.text)
                    .background(on ? Palette.greenWash : Palette.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(on ? Palette.green : Palette.lineStrong))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A two-to-four-way choice: the chosen one is a green pill with white text (Naver's 신작 / 완결 switch).
struct Segmented<T: Hashable>: View {
    var options: [T]
    @Binding var selection: T
    var title: (T) -> String
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let on = option == selection
                Button { withAnimation(.snappy(duration: 0.25)) { selection = option } } label: {
                    Text(title(option))
                        .font(.system(size: 12.5, weight: on ? .heavy : .semibold))
                        .foregroundStyle(on ? .white : Palette.textSoft)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background {
                            if on { Capsule().fill(Palette.green).matchedGeometryEffect(id: "thumb", in: ns) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Palette.surface, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.lineStrong))
    }
}

/// A switch with a title and an explanation, as one row.
struct ToggleRow: View {
    var title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Typo.bodyStrong).foregroundStyle(Palette.text)
                if let detail { Text(detail).font(Typo.small).foregroundStyle(Palette.textSoft).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(Palette.green).controlSize(.small)
        }
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { y += lineHeight + spacing; x = 0; lineHeight = 0 }
            x += s.width + spacing
            widest = max(widest, x - spacing)
            lineHeight = max(lineHeight, s.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for v in subviews {
            var s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += lineHeight + spacing; x = bounds.minX; lineHeight = 0 }
            s.width = min(s.width, bounds.width)
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineHeight = max(lineHeight, s.height)
        }
    }
}

/// A transient message at the bottom of the window.
struct ToastView: View {
    var toast: Toast

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.symbol).foregroundStyle(toast.tone.color)
            Text(toast.message).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Palette.toast, in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
    }
}

struct Toast: Equatable, Identifiable {
    let id = UUID()
    var message: String
    var symbol = "checkmark.circle.fill"
    var tone: Tone = .green
}

extension View {
    /// A thin separator line.
    func hairline(_ edge: Edge = .bottom) -> some View {
        overlay(alignment: edge == .bottom ? .bottom : .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

extension Date {
    var relative: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        if abs(timeIntervalSinceNow) < 60 { return "just now" }
        return f.localizedString(for: self, relativeTo: Date())
    }
}
