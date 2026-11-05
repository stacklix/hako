import SwiftUI

struct SettingsView: View {
    private enum UpdateSource: String, CaseIterable, Sendable {
        case github, xkode

        var title: String { self == .github ? "GitHub Pages" : "本机 xkode" }
        var baseURL: URL {
            URL(string: self == .github ? "https://stacklix.github.io/hako/" : "https://nux.luckyqiao.com/chore/ios/")!
        }
        var pageURL: URL { baseURL.appendingPathComponent("index.html") }
    }
    private enum UpdateState: Sendable {
        case checking, loaded(AppUpdateRelease), failed
    }
    private enum SheetRoute: String, Identifiable {
        case server, scanner, applications, github
        var id: String { rawValue }
    }
    @Environment(\.openURL) private var openURL
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
            Section("工具") {
                NavigationLink { HakoLogsView() } label: {
                    Label("日志", systemImage: "doc.text.magnifyingglass")
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
                ForEach(UpdateSource.allCases, id: \.self) { source in
                    updateRow(source)
                    Link(destination: source.pageURL) {
                        Label("查看 \(source.title) 下载页面", systemImage: "arrow.up.right.square")
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
            } header: {
                Text("应用更新")
            } footer: {
                Text("各渠道独立检测。发现较新版本时，可直接发起系统安装。")
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

    @ViewBuilder
    private func updateRow(_ source: UpdateSource) -> some View {
        switch updates[source] ?? .checking {
        case .checking:
            LabeledContent(source.title, value: "正在检查…")
        case .failed:
            LabeledContent(source.title, value: "检查更新失败")
        case .loaded(let release):
            if let installedBuild, let latest = release.buildVersion, latest > installedBuild {
                Button { install(release, from: source) } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("安装 \(source.title) 最新版")
                            Text("\(release.version) (\(release.build)) · \(release.builtAt.formatted(date: .numeric, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.down.circle").foregroundStyle(.green)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
            } else {
                LabeledContent(source.title, value: "\(release.version) (\(release.build)) · 无需更新")
            }
        }
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
