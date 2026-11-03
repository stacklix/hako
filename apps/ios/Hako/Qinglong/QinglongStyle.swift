import SwiftUI

// Local presentation tokens match the approved sports-style prototype.
enum QinglongStyle {
    static let background = adaptive(0xf5f5f7, 0x151517)
    static let surface = adaptive(0xffffff, 0x242427)
    static let text = adaptive(0x202124, 0xf2f2f4)
    static let muted = adaptive(0x76777d, 0xaaaab0)
    static let line = adaptive(0xe9e9ee, 0x38383c)
    static let success = adaptive(0x478d80, 0x78b8aa)
    static let warning = adaptive(0xa27d3e, 0xd3b27b)
    static let failure = adaptive(0xb5605b, 0xd4948e)
    static let code = adaptive(0xeaeaef, 0x2c2c2e)
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let v = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255, alpha: 1)
        })
    }
}

extension View {
    func qinglongTaskAction(store: QinglongStore, request: Binding<QinglongTaskAction?>) -> some View {
        sheet(item: request) { value in
            QinglongExecutionLog(store: store, item: value.item, initialAction: value.action, revision: value.revision)
        }
    }
    func qinglongCard(padding: CGFloat = 15, cornerRadius: CGFloat = 14) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(QinglongStyle.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
    func qinglongCode() -> some View {
        self.font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(15)
            .background(QinglongStyle.code, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct QinglongTaskAction: Identifiable {
    let id = UUID()
    let item: QinglongItem
    let action: String
    let revision: UUID
}

struct QinglongPrimaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
            .padding(.horizontal, compact ? 11 : 16).frame(minHeight: compact ? 36 : 44)
            .frame(maxWidth: compact ? nil : .infinity)
            .foregroundStyle(QinglongStyle.surface)
            .background(QinglongStyle.text, in: RoundedRectangle(cornerRadius: compact ? 9 : 12))
            .padding(.vertical, compact ? 4 : 0)
            .opacity(enabled ? configuration.isPressed ? 0.6 : 1 : 0.4)
    }
}

struct QinglongSecondaryButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline).frame(maxWidth: .infinity).frame(minHeight: 46)
            .foregroundStyle(destructive ? QinglongStyle.failure : QinglongStyle.text)
            .background(QinglongStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .opacity(enabled ? configuration.isPressed ? 0.6 : 1 : 0.4)
    }
}

struct QinglongInlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.caption).frame(minHeight: 36)
            .contentShape(Rectangle()).foregroundStyle(Color.primary)
            .opacity(enabled ? configuration.isPressed ? 0.5 : 1 : 0.35)
    }
}

// Native sheet navigation; editors use Form, details and execution logs use scrolling content.
struct QinglongSheet<Content: View>: View {
    let title: String
    let disabled: Bool
    let embedded: Bool
    let saveDisabled: Bool
    let usesForm: Bool
    let showsClose: Bool
    let close: (() -> Void)?
    let save: (() -> Void)?
    private let content: Content
    @Environment(\.dismiss) private var dismiss
    init(_ title: String, disabled: Bool = false, embedded: Bool = false, saveDisabled: Bool = false, usesForm: Bool = true, showsClose: Bool = true,
         close: (() -> Void)? = nil, save: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.disabled = disabled; self.embedded = embedded
        self.saveDisabled = saveDisabled; self.usesForm = usesForm; self.showsClose = showsClose; self.close = close; self.save = save; self.content = content()
    }
    var body: some View {
        Group {
            if embedded { form }
            else { NavigationStack { form } }
        }.tint(QinglongStyle.text).interactiveDismissDisabled(disabled)
    }
    private var form: some View {
        Group {
            if usesForm { Form { content } }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) { content }
                        .padding(.horizontal, 20).padding(.vertical, 16)
                }
            }
        }
            .scrollContentBackground(.hidden).background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                if !embedded && showsClose {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(save == nil ? "关闭" : "取消") { if let close { close() } else { dismiss() } }.disabled(disabled)
                    }
                }
                if let save {
                    ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(disabled || saveDisabled) }
                } else if !embedded {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { if let close { close() } else { dismiss() } }.disabled(disabled)
                    }
                }
            }
    }
}

struct QinglongPageLink: View {
    let title: String
    let symbol: String
    var last = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 20)
                Text(title).font(.system(size: 13))
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(QinglongStyle.muted)
            }.padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .overlay(alignment: .bottom) { if !last { Rectangle().fill(QinglongStyle.line).frame(height: 1).padding(.horizontal, 16) } }
    }
}

struct QinglongMenuRow: View {
    let title: String
    var symbol: String? = nil
    var destructive = false
    var last = false
    var trailingSymbol = "chevron.right"
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let symbol { Image(systemName: symbol).frame(width: 20) }
                Text(title).font(.system(size: 13))
                Spacer(minLength: 4)
                Image(systemName: trailingSymbol).font(.caption).foregroundStyle(destructive ? QinglongStyle.failure : QinglongStyle.muted)
            }.foregroundStyle(destructive ? QinglongStyle.failure : QinglongStyle.text)
                .padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle())
        }.buttonStyle(.plain)
        .overlay(alignment: .bottom) { if !last { Divider().padding(.horizontal, 16) } }
    }
}

struct QinglongNotice: View {
    let text: String
    var error = false
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(error ? Color.orange : .primary)
            .textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(QinglongStyle.code, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct QinglongActionSheet: View {
    @ObservedObject var store: QinglongStore
    let item: QinglongItem
    let action: String
    var completed: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var revision: UUID?
    @State private var error: String?
    var title: String {
        switch action { case "run": return item.resource == .subscriptions ? "拉取订阅" : "运行任务"; case "stop": return "停止任务"; case "delete": return "确认删除"; case "disable": return "禁用"; default: return "启用" }
    }
    var body: some View {
        QinglongSheet(title, disabled: store.busy) {
            Text("\(title)「\(item.title)」？").font(.subheadline)
            if action == "delete" { Text("此操作无法撤销。").font(.footnote).foregroundStyle(.secondary) }
            if item.resource == .tasks, action == "run" { Text(item.raw["command"].text).qinglongCode() }
            if let error { QinglongNotice(text: error, error: true) }
            Button(store.busy ? "正在处理…" : action == "delete" ? "确认删除" : title) {
                Task {
                    guard revision == store.revision else { error = "连接已改变，请关闭后重新打开。"; return }
                    let succeeded: Bool
                    if action == "delete" { succeeded = await store.delete(item) }
                    else { succeeded = await store.perform(item.resource, success: "请求已提交，请查看状态和日志确认执行结果。") { try await $0.action(action, item: item) } }
                    if succeeded { dismiss(); completed?() } else { error = store.message }
                }
            }.buttonStyle(QinglongPrimaryButtonStyle()).disabled(store.busy)
            Button("取消") { dismiss() }.buttonStyle(QinglongSecondaryButtonStyle()).disabled(store.busy)
        }.onAppear { if revision == nil { revision = store.revision } }
    }
}
