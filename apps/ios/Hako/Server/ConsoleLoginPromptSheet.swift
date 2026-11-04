import SwiftUI
import Combine

@MainActor final class ConsoleLoginPromptSession: ObservableObject {
    let prompt: ConsoleLoginPrompt
    let context: String
    @Published var active = true
    @Published private(set) var busy = false
    @Published private(set) var outcome: Bool?
    @Published private(set) var message: String?
    @Published private(set) var blocked = false
    init(prompt: ConsoleLoginPrompt, context: String) { self.prompt = prompt; self.context = context }

    func invalidate() {
        guard !busy, !blocked, outcome == nil else { return }
        blocked = true; message = "请求已失效或已被处理，请返回原浏览器查看。"
    }

    func submit(code: String, approve: Bool) async {
        guard active, !busy, !blocked, outcome == nil, context == ConsoleClient.shared.requestContext else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            try await ConsoleClient.shared.confirmLoginPrompt(prompt, code: code, approve: approve)
            guard active, context == ConsoleClient.shared.requestContext else { return }
            outcome = approve
        } catch {
            guard active, context == ConsoleClient.shared.requestContext else { return }
            if let failure = error as? ServerHTTPError, failure.code == "login_confirmation_mismatch" {
                message = "确认码不匹配，请核对原浏览器后重新输入。"
            } else {
                blocked = true
                message = (error as? ServerHTTPError)?.errorDescription ?? "未能确认处理结果。请回到原浏览器查看，不会自动重复提交。"
            }
        }
    }
}

struct ConsoleLoginPromptSheet: View {
    @ObservedObject var session: ConsoleLoginPromptSession
    var onProcessed: () -> Void = { }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var code = ""
    @State private var now = Date.now
    private var prompt: ConsoleLoginPrompt { session.prompt }
    private var expired: Bool { (prompt.expiry ?? .distantPast) <= now }

    var body: some View {
        SettingsSheet(title: "确认登录请求", isBusy: session.busy) {
            Group {
                if let approved = session.outcome {
                    ContentUnavailableView {
                        Label(approved ? "已确认" : "已拒绝", systemImage: approved ? "checkmark.circle" : "xmark.circle")
                    } description: {
                        Text(approved ? "请返回原浏览器，继续完成操作。" : "此次请求已拒绝。")
                    } actions: { Button("完成") { dismiss() }.buttonStyle(.bordered) }
                } else {
                    Form {
                        Section("登录请求") {
                            LabeledContent("应用", value: prompt.title)
                            LabeledContent("登记来源", value: prompt.isApplication ? prompt.applicationOrigin : prompt.origin).textSelection(.enabled)
                            LabeledContent("操作", value: prompt.actionDescription)
                            if prompt.effectivePurpose == "oidc" {
                                LabeledContent("申请身份信息", value: prompt.scopes)
                                Text(prompt.scopes.split(separator: " ").contains("profile") ? "提供稳定账号标识和账号名称，不授予 Hako 管理权限。" : "仅提供稳定账号标识，不授予 Hako 管理权限。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            } else if !prompt.isApplication {
                                Text("确认后，此浏览器将获得 Hako 管理控制台访问权限。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            LabeledContent("Hako 服务器", value: prompt.origin).textSelection(.enabled)
                            LabeledContent("浏览器", value: prompt.browser)
                            LabeledContent(prompt.isApplication && prompt.effectivePurpose != "oidc" ? "来源 IP（应用报告）" : "来源 IP", value: prompt.clientIP.isEmpty ? "未知" : prompt.clientIP).textSelection(.enabled)
                        }
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("六位确认码").font(.subheadline).foregroundStyle(.secondary)
                                TextField("输入原浏览器上的六位数字", text: $code)
                                    .font(.title2.monospaced()).keyboardType(.numberPad)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .accessibilityLabel("原浏览器上的六位确认码").privacySensitive()
                                    .onChange(of: code) { _, value in code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6)) }
                            }
                            Text("只批准你本人发起的请求。请从原浏览器读取确认码，不接受他人提供的数字。")
                                .font(.footnote).foregroundStyle(.secondary)
                            Text(expired ? "请求已过期，请重新发起。" : "\(max(0, Int(ceil((prompt.expiry ?? now).timeIntervalSince(now))))) 秒后过期")
                                .font(.footnote).foregroundStyle(.secondary)
                        }.disabled(session.busy || session.blocked || expired)
                        Section {
                            Button(prompt.effectivePurpose == "bind" ? "确认绑定" : "确认登录") { Task { await submit(approve: true) } }
                                .disabled(session.busy || session.blocked || expired || !ConsoleLoginPrompt.validCode(code))
                            Button("拒绝此次请求", role: .destructive) { Task { await submit(approve: false) } }
                                .disabled(session.busy || session.blocked || expired)
                        }
                        if session.busy { Section { Text("正在处理，请稍候…").font(.footnote).foregroundStyle(.secondary) } }
                        if let message = session.message { Section { Text(message).font(.footnote).foregroundStyle(.secondary) } }
                    }
                }
            }
            .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
            .onChange(of: session.active) { _, active in if !active { code = "" } }
            .onChange(of: session.blocked) { _, blocked in if blocked { code = "" } }
            .onChange(of: expired) { _, expired in if expired { code = "" } }
            .onChange(of: scenePhase) { _, phase in if phase != .active { code = "" } }
            .onDisappear { code = ""; session.active = false }
        }
    }

    @MainActor private func submit(approve: Bool) async {
        let entered = code
        code = ""
        await session.submit(code: entered, approve: approve)
        if session.outcome != nil { onProcessed() }
    }
}
