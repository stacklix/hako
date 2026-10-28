import SwiftUI
import SwiftData
import FamilyControls
import ManagedSettings

@main struct HakoApp: App {
    var body: some Scene {
        WindowGroup {
            switch Database.shared {
            case .success(let container): HomeView().modelContainer(container)
            case .failure(let error): ContentUnavailableView("数据库无法打开", systemImage: "externaldrive.badge.exclamationmark", description: Text(error.localizedDescription))
            }
        }
    }
}

struct HomeView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HakoMark()
                            .stroke(.primary, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                            .frame(width: 86, height: 100)
                            .frame(height: 120)
                            .frame(maxWidth: .infinity)
                            .accessibilityHidden(true)
                        Text("你的日常，收进一个盒子。").font(.title3.bold())
                        Text("HAKO · 个人工具箱").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 12)
                }
                Section("应用") {
                    NavigationLink { DeviceMonitorView() } label: {
                        Label { VStack(alignment: .leading, spacing: 5) {
                            Text("设备监控").font(.headline)
                            Text("设备在线状态 · 能力调用").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8) } icon: { Image(systemName: "desktopcomputer").foregroundStyle(.primary) }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    NavigationLink { UsageView() } label: {
                        Label { VStack(alignment: .leading, spacing: 5) {
                            Text("使用时间").font(.headline)
                            Text("每日概览 · Top 5 · GitHub 归档").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 8) } icon: { Image(systemName: "chart.bar.xaxis").foregroundStyle(.primary) }
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                }
            }
            .navigationTitle("Hako")
            .toolbar { NavigationLink { SettingsView() } label: { Image(systemName: "gearshape") }.accessibilityLabel("设置") }
        }.tint(.primary)
    }
}

struct UsageView: View {
    @ObservedObject private var authorization = AuthorizationCenter.shared
    @State private var installedApplications: [String: Application] = [:]
    @Query(sort: \DailyUsage.day, order: .reverse) private var records: [DailyUsage]
    @State private var busy = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var selectedDay: String?
    @State private var showDatePicker = false
    @ScaledMetric(relativeTo: .body) private var dateRowHeight = 44
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private var activeDay: String? { selectedDay ?? records.first?.day }
    private var selectedRecord: DailyUsage? { records.first { $0.day == activeDay } }
    var body: some View {
        List {
            Section {
                Button { execute { try await Recorder.shared.run(collect: true, requestAuthorization: true) } } label: { Label("获取app使用时间并同步", systemImage: "arrow.down.doc") }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                Button { execute { try await Recorder.shared.run(collect: false) } } label: { Label("合并本地与 GitHub 记录", systemImage: "arrow.triangle.2.circlepath") }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                if busy { ProgressView("正在处理…") }
            } footer: {
                Text("合并会补齐双方缺失的日期并保存到本地；同一天内容不一致时，以 GitHub 记录为准。")
            }.disabled(busy)
            if let message {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: messageIsError ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(messageIsError ? .orange : .green)
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button { self.message = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("关闭提示")
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                }
            }
            if records.isEmpty {
                ContentUnavailableView("还没有记录", systemImage: "clock", description: Text("点击「获取app使用时间并同步」开始，或点击「合并本地与 GitHub 记录」恢复历史记录。GitHub 仓库可在设置中配置。"))
            }
            if let oldest = records.last.flatMap({ Self.dayFormatter.date(from: $0.day) }),
               let newest = records.first.flatMap({ Self.dayFormatter.date(from: $0.day) }) {
                Section {
                    HStack {
                        Text("日期")
                        Spacer()
                        Button { showDatePicker = true } label: {
                            Label(activeDay ?? "选择日期", systemImage: "calendar")
                        }
                        .buttonStyle(.borderless)
                    }
                    .frame(height: dateRowHeight)
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    .popover(isPresented: $showDatePicker) {
                            DatePicker("日期", selection: Binding(
                                get: { activeDay.flatMap { Self.dayFormatter.date(from: $0) } ?? newest },
                                set: {
                                    selectedDay = Self.dayFormatter.string(from: $0)
                                    showDatePicker = false
                                }
                            ), in: oldest...newest, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .environment(\.calendar, Calendar(identifier: .gregorian))
                            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                            .frame(width: 320)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(8)
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
            if let record = selectedRecord {
                Section {
                    LabeledContent("总使用时间", value: duration(record.totalSeconds)).font(.headline)
                    ForEach(Array(record.apps.enumerated()), id: \.offset) { index, app in
                        HStack {
                            Text(String(index + 1)).monospacedDigit().foregroundStyle(.secondary)
                            appTitle(app).lineLimit(2)
                            Spacer()
                            Text(duration(app.seconds)).foregroundStyle(.secondary)
                        }
                    }
                    Label(record.syncedAt == nil ? "等待同步" : "已同步", systemImage: record.syncedAt == nil ? "arrow.clockwise" : "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                } header: { Text(record.day) } footer: { Text("时区：\(record.timeZone)") }
            } else if !records.isEmpty {
                ContentUnavailableView("这一天没有记录", systemImage: "calendar", description: Text("请选择其他日期查看。"))
            }
        }.navigationTitle("使用时间")
            .task(id: authorization.authorizationStatus) {
                installedApplications = await ScreenTime.installedApplications()
            }
            .onChange(of: records.first?.day) { _, _ in selectedDay = nil }
    }
    @ViewBuilder private func appTitle(_ app: AppUsage) -> some View {
        let installed = installedApplications[app.bundleID]
        let name = [installed?.localizedDisplayName, app.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != app.bundleID }
        let token = installed?.token ?? app.applicationTokenData.flatMap {
            try? JSONDecoder().decode(ApplicationToken.self, from: $0)
        }
        if let name {
            Text(name)
        } else if let token {
            Label(token).labelStyle(.titleOnly)
        } else {
            Text(app.bundleID)
        }
    }
    private func execute(_ action: @escaping @MainActor () async throws -> String) {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                let result = try await action()
                messageIsError = false
                message = result
            } catch {
                messageIsError = true
                message = error.localizedDescription
            }
        }
    }
    private func duration(_ seconds: Double) -> String {
        let value = Int(seconds.rounded()); return "\(value / 3600)小时 \((value % 3600) / 60)分"
    }
}

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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var settings = GitHubSettings.load()
    @State private var token = ""
    @State private var savedSettings: GitHubSettings?
    @State private var savedToken = ""
    @State private var showDiscardConfirmation = false
    @State private var message: String?
    @State private var latestRelease: Release?
    @State private var latestBuildDateFailed = false
    @State private var checkingForUpdate = false
    @State private var updateCheckID = 0
    @State private var isVisible = false
    private var hasChanges: Bool {
        guard let savedSettings else { return false }
        return settings != savedSettings || token != savedToken
    }
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
            Section("GitHub 仓库") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("仓库地址").font(.subheadline).foregroundStyle(.secondary)
                    TextField("https://github.com/username/repository", text: $settings.repositoryURL)
                        .keyboardType(.URL)
                        .accessibilityLabel("仓库地址")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("分支").font(.subheadline).foregroundStyle(.secondary)
                    TextField("master", text: $settings.branch)
                        .accessibilityLabel("分支")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Personal Access Token").font(.subheadline).foregroundStyle(.secondary)
                    SecureField("输入 GitHub Token", text: $token)
                        .accessibilityLabel("Personal Access Token")
                }
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(savedSettings == nil)
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
            BuildStatusView(isSettingsVisible: isVisible)
        }.navigationTitle("设置")
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
            // Use a guarded back action while editing; prevent the native swipe
            // from popping this screen and silently losing the draft.
            .navigationBarBackButtonHidden(hasChanges)
            .toolbar {
                if hasChanges {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("返回", systemImage: "chevron.left") {
                            showDiscardConfirmation = true
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: save) {
                        Image(systemName: "checkmark")
                    }
                        .accessibilityLabel("保存设置")
                        .disabled(!hasChanges)
                }
            }
            .confirmationDialog("有尚未保存的修改", isPresented: $showDiscardConfirmation, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) { }
            } message: {
                Text("返回后，本次修改将不会保存。")
            }
            .task {
                guard savedSettings == nil else { return }
                do {
                    let storedToken = try TokenStore.read()
                    token = storedToken
                    savedToken = storedToken
                    savedSettings = settings
                } catch { message = error.localizedDescription }
            }
            .task(id: updateCheckID) { await loadLatestBuildDate() }
            .alert("Hako", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("好") { message = nil } } message: { Text(message ?? "") }
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
    private func save() {
        do {
            try settings.validate()
            try TokenStore.save(token.trimmingCharacters(in: .whitespacesAndNewlines))
            try settings.save()
            dismiss()
        } catch {
            message = error.localizedDescription
        }
    }
}
