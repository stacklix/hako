import SwiftUI

struct SettingsView: View {
    private struct Release: Decodable {
        let version: String
        let build: String
        let builtAt: Date

        func isNewer(than currentBuild: String) -> Bool {
            guard let latest = Int(build), let current = Int(currentBuild) else { return false }
            return latest > current
        }
    }
    private enum SheetRoute: String, Identifiable {
        case server, scanner, applications, github
        var id: String { rawValue }
    }
    @Environment(\.openURL) private var openURL
    @State private var sheet: SheetRoute?
    @State private var message: String?
    @State private var latestRelease: Release?
    @State private var latestBuildDateFailed = false
    @State private var checkingForUpdate = false
    @State private var updateCheckID = 0
    @State private var isVisible = false
    private var currentVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return "\(version) (\(build))"
    }
    private var availableUpdate: Release? {
        guard let release = latestRelease,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              release.isNewer(than: build) else { return nil }
        return release
    }
    var body: some View {
        Form {
            Section("Hako 服务") {
                Button { sheet = .server } label: {
                    settingsEntry("服务器与登录", systemImage: "server.rack")
                }
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                Button { sheet = .scanner } label: {
                    settingsEntry("扫码登录", systemImage: "qrcode.viewfinder")
                }
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                Button { sheet = .applications } label: {
                    settingsEntry("第三方应用", systemImage: "square.stack.3d.up")
                }
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
            Section("GitHub") {
                Button { sheet = .github } label: {
                    settingsEntry("GitHub 配置", systemImage: "externaldrive.connected.to.line.below")
                }
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
            Section {
                HStack(spacing: 16) {
                    LabeledContent("当前版本", value: currentVersion)
                    Button("检测更新") { updateCheckID += 1 }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .fixedSize()
                        .disabled(checkingForUpdate)
                }
                if let release = availableUpdate {
                    Button(action: installLatestVersion) {
                        HStack(alignment: .top) {
                            Image(systemName: "arrow.down.circle")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("安装最新版")
                                    Spacer()
                                    Text("\(release.version) (\(release.build))")
                                        .foregroundStyle(.secondary)
                                }
                                Text("构建于 \(release.builtAt.formatted(date: .numeric, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                } else {
                    Text(latestBuildDateFailed ? "检查更新失败" : latestRelease == nil ? "正在检查更新…" : "当前无需更新")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Link(destination: URL(string: "https://stacklix.github.io/hako/")!) {
                    Label("查看下载页面", systemImage: "arrow.up.right.square")
                }
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            } header: {
                Text("应用更新")
            } footer: {
                Text("「安装最新版」直接发起系统安装；「查看下载页面」打开分发页，查看版本信息或下载 IPA。")
            }
            BuildStatusView(isSettingsVisible: isVisible && sheet == nil)
        }.navigationTitle("设置")
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .sheet(item: $sheet) { route in
                switch route {
                case .server: ServerSettingsView()
                case .scanner: ConsoleWebLoginView()
                case .applications: ConsoleApplicationsView()
                case .github: GitHubSettingsSheet()
                }
            }
            .task(id: updateCheckID) { await loadLatestBuildDate() }
            .alert("Hako", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("好") { message = nil } } message: { Text(message ?? "") }
    }
    private func settingsEntry(_ title: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private func loadLatestBuildDate() async {
        guard !Task.isCancelled else { return }
        checkingForUpdate = true
        defer { checkingForUpdate = false }
        latestRelease = nil
        latestBuildDateFailed = false
        var endpoint = URLComponents(string: "https://stacklix.github.io/hako/latest.json")!
        endpoint.queryItems = [URLQueryItem(name: "t", value: String(Int(Date.now.timeIntervalSince1970)))]
        let request = URLRequest(url: endpoint.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                latestBuildDateFailed = true
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let release = try decoder.decode(Release.self, from: data)
            guard Int(release.build) != nil,
                  let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                  Int(currentBuild) != nil else {
                latestBuildDateFailed = true
                return
            }
            try Task.checkCancellation()
            latestRelease = release
        } catch {
            if !Task.isCancelled { latestBuildDateFailed = true }
        }
    }
    private func installLatestVersion() {
        var manifest = URLComponents(string: "https://stacklix.github.io/hako/manifest.plist")!
        manifest.queryItems = [URLQueryItem(name: "t", value: String(Int(Date.now.timeIntervalSince1970)))]
        var installation = URLComponents()
        installation.scheme = "itms-services"
        installation.host = ""
        installation.queryItems = [
            URLQueryItem(name: "action", value: "download-manifest"),
            URLQueryItem(name: "url", value: manifest.url!.absoluteString)
        ]
        openURL(installation.url!) { accepted in
            if !accepted {
                message = "无法打开系统安装入口，请在 Safari 打开 https://stacklix.github.io/hako/ 安装最新版本。"
            }
        }
    }
}
