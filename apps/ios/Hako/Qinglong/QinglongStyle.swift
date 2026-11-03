import SwiftUI

// Geometry follows the approved prototype; colors follow Hako/system appearance.
enum QinglongStyle {
    static let background = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    static let code = Color(uiColor: .tertiarySystemFill)
}

extension View {
    func qinglongCard(padding: CGFloat = 15) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(QinglongStyle.surface, in: RoundedRectangle(cornerRadius: 15))
    }
    func qinglongCode() -> some View {
        self.font(.footnote.monospaced()).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading).padding(15)
            .background(QinglongStyle.code, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct QinglongPrimaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
            .padding(.horizontal, compact ? 11 : 16).frame(minHeight: 44)
            .frame(maxWidth: compact ? nil : .infinity)
            .foregroundStyle(Color(uiColor: .systemBackground))
            .background(Color.primary, in: RoundedRectangle(cornerRadius: compact ? 9 : 12))
            .opacity(enabled ? configuration.isPressed ? 0.6 : 1 : 0.4)
    }
}

struct QinglongSecondaryButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline).frame(maxWidth: .infinity).frame(minHeight: 46)
            .foregroundStyle(destructive ? Color.red : Color.primary)
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

struct QinglongSheet<Content: View>: View {
    let title: String
    var disabled = false
    var close: (() -> Void)?
    private let content: Content
    @Environment(\.dismiss) private var dismiss
    init(_ title: String, disabled: Bool = false, close: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.disabled = disabled; self.close = close; self.content = content()
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text(title).font(.system(size: 18, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { if let close { close() } else { dismiss() } } label: {
                    Image(systemName: "xmark").font(.system(size: 16)).frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("关闭").disabled(disabled)
            }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(.horizontal, 20).padding(.bottom, 28)
            }.scrollDismissesKeyboard(.interactively)
        }
        .foregroundStyle(.primary).background(QinglongStyle.background).tint(.primary)
        .presentationDetents([.large]).presentationDragIndicator(.visible).presentationCornerRadius(23)
        .interactiveDismissDisabled(disabled)
    }
}

struct QinglongMenuRow: View {
    let title: String
    var symbol: String? = nil
    var destructive = false
    var last = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let symbol { Image(systemName: symbol).frame(width: 20) }
                Text(title).font(.subheadline)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.foregroundStyle(destructive ? Color.red : .primary)
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
