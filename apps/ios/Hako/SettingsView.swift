import SwiftUI

struct SettingsView: View {
    private enum UpdateSource: String, CaseIterable, Sendable {
        case github, xkode

        var title: String { self == .github ? "GitHub Pages" : "本机 xkode" }
        var baseURL: URL {
            URL(string: self == .github ? "https://stacklix.github.io/hako/" : "https://nux.luckyqiao.com/chore/ios/hako/")!
        }
        var pageURL: URL { baseURL.appendingPathComponent("index.html") }
    }
    private enum UpdateState: Sendable {
        case checking, loaded(AppUpdateRelease), failed

        var release: AppUpdateRelease? {
            if case .loaded(let release) = self { return release }
            return nil
        }

        func updateAvailable(comparedTo installedBuild: AppBuildVersion?) -> Bool? {
            guard let installedBuild, let latest = release?.buildVersion else { return nil }
            return latest > installedBuild
        }

        func detail(updateAvailable: Bool?) -> String {
            switch self {
            case .checking:
                return "正在检查…"
            case .failed:
                return "检查更新失败"
            case .loaded(let release):
                let version = "\(release.version) (\(release.build))"
                guard let updateAvailable else { return version }
                return "\(version) · \(updateAvailable ? "可更新" : "无需更新")"
            }
        }
    }
    private enum SheetRoute: String, Identifiable {
        case server, scanner, applications, github
        var id: String { rawValue }
    }
    @Environment(\.openURL) private var openURL
    @ObservedObject private var buildPush = BuildPushSubscription.shared
    @State private var sheet: SheetRoute?
    @State private var message: String?
    @State private var updates: [UpdateSource: UpdateState] = [:]
    @State private var checkingForUpdate = false
    @State private var updateCheckID = 0
    @State private var isVisible = false
    private var currentVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        return "\(version) (\(build))"
    }
    private var installedBuild: AppBuildVersion? {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return nil }
        return AppBuildVersion(version: version, build: build)
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
            Section("构建通知") {
                Toggle("接收 Hako 构建通知", isOn: Binding(
                    get: { buildPush.enabled },
                    set: { enabled in Task { await buildPush.setEnabled(enabled) } }
                ))
                .disabled(buildPush.busy)
                if let message = buildPush.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("工具") {
                NavigationLink { HakoLogsView() } label: {
                    Label("日志", systemImage: "doc.text.magnifyingglass")
                }
                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            }
            Section {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前版本")
                        Text(currentVersion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("检测更新") { updateCheckID += 1 }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .fixedSize()
                        .disabled(checkingForUpdate)
                }
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                ForEach(UpdateSource.allCases, id: \.self) { source in
                    updateRow(source)
                }
            } header: {
                Text("应用更新")
            }
            BuildStatusView(isSettingsVisible: isVisible && sheet == nil)
        }.navigationTitle("设置")
            .scrollContentBackground(.hidden)
            .background(HakoStyle.background)
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
            .task(id: updateCheckID) { await checkUpdates() }
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

    private func updateRow(_ source: UpdateSource) -> some View {
        let state = updates[source] ?? .checking
        let updateAvailable = state.updateAvailable(comparedTo: installedBuild)
        let highlight = updateAvailable == true ? HakoStyle.adaptive(0x18743b, 0x5cdb83) : nil
        return HStack(spacing: 8) {
            Button {
                if let release = state.release { install(release, from: source) }
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("下载 \(source.title) 版")
                        Text(state.detail(updateAvailable: updateAvailable))
                            .font(.caption)
                            .foregroundStyle(highlight ?? .secondary)
                    }
                } icon: {
                    Image(systemName: "arrow.down.to.line")
                }
                .foregroundStyle(highlight ?? .primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.release == nil)

            Link(destination: source.pageURL) {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(highlight ?? .blue)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("打开 \(source.title) 安装页")
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }

    private func checkUpdates() async {
        guard !Task.isCancelled else { return }
        checkingForUpdate = true
        defer { if !Task.isCancelled { checkingForUpdate = false } }
        updates = [:]
        guard installedBuild != nil else {
            updates = Dictionary(uniqueKeysWithValues: UpdateSource.allCases.map { ($0, .failed) })
            return
        }
        await withTaskGroup(of: (UpdateSource, UpdateState).self) { group in
            for source in UpdateSource.allCases {
                group.addTask { (source, await Self.check(source)) }
            }
            for await (source, state) in group {
                guard !Task.isCancelled else { return }
                updates[source] = state
            }
        }
    }

    nonisolated private static func check(_ source: UpdateSource) async -> UpdateState {
        var endpoint = URLComponents(url: source.baseURL.appendingPathComponent("latest.json"), resolvingAgainstBaseURL: false)!
        endpoint.queryItems = [URLQueryItem(name: "t", value: UUID().uuidString)]
        let request = URLRequest(url: endpoint.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let release = try decoder.decode(AppUpdateRelease.self, from: data)
            guard release.buildVersion != nil, release.manifestName != nil else { return .failed }
            return .loaded(release)
        } catch {
            return .failed
        }
    }
    private func install(_ release: AppUpdateRelease, from source: UpdateSource) {
        guard let name = release.manifestName else { return }
        var manifest = URLComponents(url: source.baseURL.appendingPathComponent(name), resolvingAgainstBaseURL: false)!
        manifest.queryItems = [URLQueryItem(name: "t", value: UUID().uuidString)]
        var installation = URLComponents()
        installation.scheme = "itms-services"
        installation.host = ""
        installation.queryItems = [
            URLQueryItem(name: "action", value: "download-manifest"),
            URLQueryItem(name: "url", value: manifest.url!.absoluteString)
        ]
        openURL(installation.url!) { accepted in
            if !accepted {
                message = "无法打开系统安装入口，请从 \(source.title) 下载页面安装。"
            }
        }
    }
}
