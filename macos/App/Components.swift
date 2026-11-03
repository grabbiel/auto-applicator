import AppKit
import SwiftUI

struct AppIcon: View {
    var size: CGFloat = 64
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct BannerView: View {
    let banner: Banner

    init(_ banner: Banner) { self.banner = banner }
    init(_ kind: Banner.Kind, _ text: String, spinning: Bool = false) { banner = Banner(kind: kind, text: text, spinning: spinning) }

    private var color: Color {
        switch banner.kind {
        case .info: .accentColor
        case .ok: .green
        case .warn: .orange
        case .error: .red
        }
    }

    private var symbol: String {
        switch banner.kind {
        case .info: "info.circle.fill"
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .error: "exclamationmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if banner.spinning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol).foregroundStyle(color)
            }
            Text(banner.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ErrorText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .foregroundStyle(.red)
            .font(.callout)
    }
}

/// A text field row in a form, with its error (if any) underneath.
struct TextRow: View {
    @EnvironmentObject var model: AppModel
    let label: String
    let path: String
    var prompt = ""
    var secure = false
    var multiline = false

    var body: some View {
        if secure {
            SecureField(label, text: model.text(path), prompt: Text(prompt))
        } else if multiline {
            TextField(label, text: model.text(path), prompt: Text(prompt), axis: .vertical).lineLimit(2...6)
        } else {
            TextField(label, text: model.text(path), prompt: Text(prompt))
        }
        if let error = model.errors[path] { ErrorText(error) }
    }
}

struct YesNoRow: View {
    @EnvironmentObject var model: AppModel
    let question: String
    let path: String

    var body: some View {
        Picker(selection: model.yesNo(path)) {
            Text("Yes").tag(Bool?.some(true))
            Text("No").tag(Bool?.some(false))
        } label: {
            Text(question).fixedSize(horizontal: false, vertical: true)
        }
        .pickerStyle(.segmented)
    }
}

struct ChoiceRow: View {
    @EnvironmentObject var model: AppModel
    let label: String
    let path: String
    let optionsPath: String

    var body: some View {
        Picker(label, selection: model.text(path)) {
            ForEach(model.choices(optionsPath, current: path), id: \.self) { Text($0).tag($0) }
        }
    }
}

/// A switch with a bold title and a line of explanation.
struct ToggleRow: View {
    @EnvironmentObject var model: AppModel
    let title: String
    var detail = ""
    let path: String

    var body: some View {
        Toggle(isOn: model.flag(path)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

/// A list of strings edited one per row (job titles, companies to avoid).
struct StringListRows: View {
    @EnvironmentObject var model: AppModel
    let path: String
    let prompt: String
    let addLabel: String

    var body: some View {
        ForEach(Array(model.list(path).indices), id: \.self) { i in
            HStack {
                TextField("", text: model.text("\(path).\(i)"), prompt: Text(prompt)).labelsHidden()
                Button { model.remove(path, at: i) } label: { Image(systemName: "minus.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove")
            }
        }
        Button { model.append(path, "") } label: { Label(addLabel, systemImage: "plus") }
            .buttonStyle(.borderless)
        if let error = model.errors[path] { ErrorText(error) }
    }
}

/// A list of strings typed as "a, b, c". Keeps what's being typed (a trailing comma) while it updates the draft.
struct CommaListRow: View {
    @EnvironmentObject var model: AppModel
    let label: String
    let path: String
    var prompt = ""
    @State private var raw = ""

    private func parse(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        TextField(label, text: $raw, prompt: Text(prompt))
            .onAppear { raw = model.draft[path].strings.joined(separator: ", ") }
            .onChange(of: raw) { text in
                let items = parse(text)
                if items != model.draft[path].strings { model.set(path, .array(items.map(JSON.string))) }
            }
            .onChange(of: model.draft[path].strings) { items in
                if parse(raw) != items { raw = items.joined(separator: ", ") }
            }
    }
}

/// The install progress list (browser, AI engine, AI model) with a Retry button when a step failed.
struct InstallList: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(model.install["steps"].array.enumerated()), id: \.offset) { _, step in
                let status = step["status"].string ?? "waiting"
                let progress = step["progress"]
                HStack(alignment: .top, spacing: 12) {
                    Group {
                        switch status {
                        case "done": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case "error": Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                        case "running": ProgressView().controlSize(.small)
                        default: Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step["title"].text).fontWeight(.semibold)
                        Text(status == "waiting" ? "Waiting…" : step["detail"].text).font(.callout).foregroundStyle(.secondary)
                        if status == "running", case .number(let p) = progress {
                            ProgressView(value: min(max(p, 0), 1))
                        }
                    }
                    Spacer(minLength: 0)
                    if status == "running", case .number(let p) = progress {
                        Text("\(Int(p * 100))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            if let error = model.installError {
                BannerView(.error, error)
                Button("Retry") { model.retryInstall() }
            }
        }
    }
}

struct InstallPill: View {
    @EnvironmentObject var model: AppModel
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            if model.installDone {
                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if model.installError != nil {
                Label("Install problem", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            } else {
                Label("Installing… \(Int(overall * 100))%", systemImage: "arrow.down.circle")
            }
        }
        .labelStyle(.titleAndIcon)
        .help("What Auto Applicator has installed")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.installDone ? "Installed" : "Installing").font(.headline)
                InstallList()
            }
            .padding(18)
            .frame(width: 380)
        }
    }

    private var overall: Double {
        if case .number(let n) = model.install["overall"] { return n }
        return 0
    }
}

struct ToastView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let toast = model.toast {
            Text(toast)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 6, y: 2)
                .padding(.bottom, 76)
                .transition(.opacity)
                .onTapGesture { model.toast = nil }
        }
    }
}

/// A rounded panel for the home page.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// A form section's title. Explicit styling: macOS otherwise draws the first one on a page smaller than the rest.
struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.headline).foregroundStyle(.primary).textCase(nil)
    }
}

extension Section where Parent == SectionTitle, Footer == EmptyView, Content: View {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { SectionTitle(title) })
    }
}
