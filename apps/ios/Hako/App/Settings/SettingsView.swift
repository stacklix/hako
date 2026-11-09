import CoreLocation
import NetworkExtension
import SwiftUI

struct SettingsView: View {
    private enum UpdateSource: String, CaseIterable, Sendable {
        case github, xkode

        var title: String { self == .github ? "GitHub Pages" : "本机 xkode" }
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
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(HakoAppearance.storageKey) private var appearance = HakoAppearance.system
    @AppStorage("choreUpdateWiFiSSIDs") private var choreWiFiSSIDData = Data()
    @AppStorage("choreUpdateWiFiSSID") private var legacyChoreWiFiSSID = ""
    @ObservedObject private var buildPush = BuildPushSubscription.shared
    @ObservedObject private var console = ConsoleClient.shared
    @State private var sheet: SheetRoute?
    @State private var alert: (title: String, message: String)?
    @State private var updates: [UpdateSource: UpdateState] = [:]
    @State private var choreRoute: ChoreUpdateRoute?
    @State private var currentWiFiSSID: String?
    @State private var updateRequestID: UUID?
    @State private var updateCheckID = 0
    @State private var isVisible = false
    @State private var inForeground = false
    private var choreWiFiSSIDs: [String] {
        if let saved = try? JSONDecoder().decode([String].self, from: choreWiFiSSIDData) { return saved }
        return legacyChoreWiFiSSID.isEmpty ? [] : [legacyChoreWiFiSSID]
    }
    private var updateTaskID: String? {
        guard isVisible, inForeground, !buildPush.settingsRequested else { return nil }
        return "\(updateCheckID)-\(buildPush.settingsRequestID)"
    }
    private static let githubUpdateURL = URL(string: "https://stacklix.github.io/hako/")!
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
            Section("外观") {
                Picker("主题", selection: $appearance) {
                    ForEach(HakoAppearance.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
            }
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
                NavigationLink { HakoShortcutHistoryView() } label: {
                    Label("快捷指令执行历史", systemImage: "clock.arrow.circlepath")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                NavigationLink { HakoLogsView() } label: {
                    Label("日志", systemImage: "doc.text.magnifyingglass")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
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
                        .disabled(updateRequestID != nil)
                }
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                LabeledContent("Chore 连接", value: choreRoute == .local ? "当前在局域网" : choreRoute == nil ? "正在检测…" : "使用公网地址")
                NavigationLink {
                    ChoreWiFiSettingsView(
                        ssids: Binding(get: { choreWiFiSSIDs }, set: storeChoreWiFiSSIDs),
                        currentSSID: $currentWiFiSSID
                    ) {
                        await Self.check(ChoreUpdateRoute.local.appURL, timeout: 3).release != nil
                    }
                } label: {
                    LabeledContent("当前 Wi-Fi", value: currentWiFiSSID ?? "未获取")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                .accessibilityHint("管理已登记的内网 Wi-Fi")
                ForEach(UpdateSource.allCases, id: \.self) { source in
                    updateRow(source)
                }
            } header: {
                Text("应用更新")
            }
            BuildStatusView(isSettingsVisible: isVisible && sheet == nil, choreRoute: choreRoute)
            Section("版本信息") {
                LabeledContent("Hako iOS", value: currentVersion)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                LabeledContent("Hako 服务端", value: console.serverVersionLabel)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
            }
        }.navigationTitle("设置")
            .scrollContentBackground(.hidden)
            .background(HakoStyle.background)
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            .onChange(of: scenePhase, initial: true) { _, phase in
                // Preserve the task across brief inactive transitions in the foreground.
                if phase == .active { inForeground = true }
                if phase == .background { inForeground = false }
            }
            .sheet(item: $sheet) { route in
                switch route {
                case .server: ServerSettingsView()
                case .scanner: ConsoleWebLoginView()
                case .applications: ConsoleApplicationsView()
                case .github: GitHubSettingsSheet()
                }
            }
            .task(id: updateTaskID) { [updateTaskID] in
                guard updateTaskID != nil else { return }
                await checkUpdates()
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { return }
                    await refreshChore()
                }
            }
            .alert(alert?.title ?? "Hako", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }), presenting: alert) { _ in
                Button("好") { alert = nil }
            } message: { content in
                Text(content.message)
            }
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
                        if let release = state.release {
                            Text("最近构建 \(release.builtAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: updateAvailable == true ? "arrow.down.circle.fill" : "arrow.down.circle")
                        .foregroundStyle(highlight ?? .primary)
                        .frame(width: 28, height: 28)
                }
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(state.release == nil)

            Button {
                alert = ("变更摘要", state.release?.summary ?? "该版本暂无变更摘要。")
            } label: {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(.blue)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(state.release == nil)
            .accessibilityLabel("查看 \(source.title) 版变更摘要")

            let baseURL = source == .github ? Self.githubUpdateURL : choreRoute?.appURL
            Link(destination: (baseURL ?? ChoreUpdateRoute.publicNetwork.appURL).appendingPathComponent("index.html")) {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.blue)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(baseURL == nil)
            .accessibilityLabel("打开 \(source.title) 安装页")
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }

    private func checkUpdates() async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        updateRequestID = request
        defer { if updateRequestID == request { updateRequestID = nil } }
        updates = [:]
        guard installedBuild != nil else {
            updates = Dictionary(uniqueKeysWithValues: UpdateSource.allCases.map { ($0, .failed) })
            return
        }
        async let github = Self.check(Self.githubUpdateURL)
        await refreshChore()
        let githubState = await github
        guard !Task.isCancelled, updateRequestID == request else { return }
        updates[.github] = githubState
    }

    private func refreshChore() async {
        let ssid = await NEHotspotNetwork.fetchCurrent()?.ssid
        guard !Task.isCancelled else { return }
        currentWiFiSSID = ssid
        if let ssid, choreWiFiSSIDs.contains(where: { $0.utf8.elementsEqual(ssid.utf8) }) {
            let local = await Self.check(ChoreUpdateRoute.local.appURL, timeout: 3)
            guard !Task.isCancelled else { return }
            if local.release != nil {
                choreRoute = .local
                updates[.xkode] = local
                return
            }
        }
        guard !Task.isCancelled else { return }
        choreRoute = .publicNetwork
        let remote = await Self.check(ChoreUpdateRoute.publicNetwork.appURL)
        guard !Task.isCancelled else { return }
        updates[.xkode] = remote
    }

    private func storeChoreWiFiSSIDs(_ ssids: [String]) {
        guard let data = try? JSONEncoder().encode(ssids) else { return }
        choreWiFiSSIDData = data
        legacyChoreWiFiSSID = ""
        choreRoute = .publicNetwork
        updateCheckID += 1
    }

    nonisolated private static func check(_ baseURL: URL, timeout: TimeInterval = 15) async -> UpdateState {
        var endpoint = URLComponents(url: baseURL.appendingPathComponent("latest.json"), resolvingAgainstBaseURL: false)!
        endpoint.queryItems = [URLQueryItem(name: "t", value: UUID().uuidString)]
        let request = URLRequest(url: endpoint.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        do {
            let (data, response) = try await HTTPTransport.data(for: request)
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
        // The system installer requires trusted HTTPS for the manifest and IPA.
        let baseURL = source == .github ? Self.githubUpdateURL : ChoreUpdateRoute.publicNetwork.appURL
        var manifest = URLComponents(url: baseURL.appendingPathComponent(name), resolvingAgainstBaseURL: false)!
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
                alert = ("Hako", "无法打开系统安装入口，请从 \(source.title) 下载页面安装。")
            }
        }
    }
}

private struct ChoreWiFiSettingsView: View {
    @Binding var ssids: [String]
    @Binding var currentSSID: String?
    let checkLocalChore: () async -> Bool
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var wifiLocation = ChoreWiFiLocationAuthorization()
    @State private var addingWiFi = false
    @State private var error: String?

    private var canAddWiFi: Bool { addingWiFi && wifiLocation.status != .notDetermined }

    var body: some View {
        Form {
            Section {
                LabeledContent("当前 Wi-Fi", value: currentSSID ?? "未获取")
                Button {
                    addingWiFi = true
                    wifiLocation.requestIfNeeded()
                } label: {
                    HStack {
                        Label("添加当前 Wi-Fi", systemImage: "plus.circle")
                        Spacer()
                        if addingWiFi {
                            ProgressView().accessibilityLabel("正在验证当前 Wi-Fi")
                        }
                    }
                    .contentShape(Rectangle())
                }
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
            }
            Section("已登记的 Wi-Fi") {
                if ssids.isEmpty {
                    Text("尚未登记 Wi-Fi").foregroundStyle(.secondary)
                }
                ForEach(Array(ssids.enumerated()), id: \.offset) { _, ssid in
                    HStack {
                        Label(ssid, systemImage: "wifi")
                        Spacer()
                        Button(role: .destructive) {
                            ssids = ssids.filter { !$0.utf8.elementsEqual(ssid.utf8) }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("移除内网 Wi-Fi \(ssid)")
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
            }
        }
        .navigationTitle("内网 Wi-Fi")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(HakoStyle.background)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { addingWiFi = false }
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await refreshCurrentSSID()
        }
        .task(id: canAddWiFi) { [canAddWiFi] in
            if canAddWiFi { await addCurrentWiFi() }
        }
        .alert("设置内网 Wi-Fi", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    @discardableResult private func refreshCurrentSSID() async -> String? {
        let ssid = await NEHotspotNetwork.fetchCurrent()?.ssid
        guard !Task.isCancelled else { return nil }
        currentSSID = ssid
        return ssid
    }

    private func addCurrentWiFi() async {
        defer { if !Task.isCancelled { addingWiFi = false } }
        guard !Task.isCancelled else { return }
        guard wifiLocation.hasPreciseLocation else {
            error = "请在系统设置中允许 Hako 在使用期间访问位置，并打开「精确位置」。"
            return
        }
        let current = await refreshCurrentSSID()
        guard !Task.isCancelled else { return }
        guard let ssid = current, !ssid.isEmpty else {
            error = "未能读取 Wi-Fi 名称，请连接 Chore 所在的 Wi-Fi 后重试。"
            return
        }
        guard !ssids.contains(where: { $0.utf8.elementsEqual(ssid.utf8) }) else {
            error = "当前 Wi-Fi 已在内网列表中。"
            return
        }
        let reachable = await checkLocalChore()
        guard !Task.isCancelled else { return }
        guard reachable else {
            error = "当前 Wi-Fi 无法访问 Chore，请检查网络连接和 Hako 的本地网络权限。"
            return
        }
        let verifiedSSID = await refreshCurrentSSID()
        guard !Task.isCancelled else { return }
        guard let verifiedSSID, verifiedSSID.utf8.elementsEqual(ssid.utf8) else {
            error = "验证期间 Wi-Fi 已切换，请重新添加当前 Wi-Fi。"
            return
        }
        ssids.append(ssid)
    }
}

@MainActor
private final class ChoreWiFiLocationAuthorization: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published private(set) var status: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        status = manager.authorizationStatus
        manager.delegate = self
    }

    var hasPreciseLocation: Bool {
        let authorization = manager.authorizationStatus
        return (authorization == .authorizedWhenInUse || authorization == .authorizedAlways)
            && manager.accuracyAuthorization == .fullAccuracy
    }

    func requestIfNeeded() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            status = self.manager.authorizationStatus
        }
    }
}
