import SwiftUI

struct WorkshopPushStatus: Decodable, Equatable {
    let enabled: Bool
    let configured: Bool
    let registered: Bool
}

struct WorkshopPushSettings: View {
    let authentication: any AuthenticatedServerAccess
    @State private var status: WorkshopPushStatus?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Section {
            Toggle("后台任务通知", isOn: Binding(get: { status?.enabled == true }, set: { enabled in
                Task { await update(enabled) }
            }))
            .disabled(busy || status == nil || !authentication.authenticated || authentication.logoutPending)
            if busy { ProgressView("正在同步通知设置") }
            if let status, !status.configured {
                Text("服务器尚未配置 APNs，暂时无法推送。").foregroundStyle(.secondary)
            } else if let status, status.enabled && !status.registered {
                Text("此 iPhone 尚未完成推送登记，请关闭后重新开启通知。").foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red) }
            if status == nil && !busy {
                Button("重新读取通知设置") { Task { await load() } }
                    .disabled(!authentication.authenticated || authentication.logoutPending)
            }
        } header: { Text("通知") } footer: {
            Text("默认关闭。开启后通知完成、失败、中断或结果未知的任务，并显示项目名、会话名和本轮最后回复的简短摘要，锁屏上也可能显示这些内容；App 在前台时不弹横幅。局域网任务由电脑经 Hako 服务器上报，电脑需配置云端连接并联网；纯离线局域网无法推送。")
        }
        .task(id: authentication.requestContext) { await load() }
    }

    private func load() async {
        status = nil; error = nil
        guard authentication.authenticated, !authentication.logoutPending else {
            error = "请先登录 Hako 服务器，再配置后台通知。"; return
        }
        busy = true
        defer { busy = false }
        do {
            let data = try await authentication.send("/api/v1/notifications/workshop", method: "GET", body: nil, logSource: .codeWorkshop)
            status = try JSONDecoder().decode(WorkshopPushStatus.self, from: data)
        } catch is CancellationError { }
        catch { self.error = "无法读取通知设置，请检查服务器连接及版本。" }
    }

    private func update(_ enabled: Bool) async {
        guard !busy else { return }
        let context = authentication.requestContext
        busy = true; error = nil
        defer { busy = false }
        do {
            if enabled { try await RemoteNotificationRegistration.prepare() }
            guard context == authentication.requestContext else { throw CancellationError() }
            let data = try await authentication.send("/api/v1/notifications/workshop", method: "PUT", body: ["enabled": enabled], logSource: .codeWorkshop)
            status = try JSONDecoder().decode(WorkshopPushStatus.self, from: data)
        } catch is CancellationError { }
        catch { self.error = "通知设置未保存，请确认系统通知权限、设备登记及服务器连接后重试。" }
    }
}
