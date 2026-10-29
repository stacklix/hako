import SwiftUI

struct ConsoleSessionsView: View {
    @ObservedObject private var client = ConsoleClient.shared
    var body: some View {
        List {
            ForEach(client.remoteSessions) { session in
                VStack(alignment: .leading, spacing: 8) {
                    Label(session.type == .web ? "网页管理端 · \(session.browser ?? "网页浏览器")" : session.current ? "当前 iPhone" : "管理客户端",
                          systemImage: session.type == .web ? "globe" : "iphone")
                    if let deviceId = session.deviceId {
                        Text(deviceId).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Text("登录时间：\(sessionTime(session.createdAt))").font(.caption).foregroundStyle(.secondary)
                    if let lastUsedAt = session.lastUsedAt {
                        Text("最近活动：\(sessionTime(lastUsedAt))").font(.caption).foregroundStyle(.secondary)
                    }
                    if session.type == .web {
                        Button("移除网页登录", role: .destructive) {
                            Task { await client.revokeWebSession(session) }
                        }.disabled(client.busy)
                    }
                }.padding(.vertical, 5)
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
            if client.busy { ProgressView() }
            if let message = client.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("已登录设备")
            .task { await client.fetchSessions() }
            .refreshable { await client.fetchSessions() }
    }
    private func sessionTime(_ value: String) -> String {
        ISO8601DateFormatter().date(from: value)?.formatted(date: .numeric, time: .shortened) ?? value
    }
}
