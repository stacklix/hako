import SwiftUI

@main struct HakoApp: App {
    @UIApplicationDelegateAdaptor(BuildPushDelegate.self) private var pushDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(HakoAppearance.storageKey) private var appearance = HakoAppearance.system

    init() {
        LocalNetworkService.shared = AppNetworkService.shared
        RemoteNotificationRegistration.prepare = { try await BuildPushSubscription.shared.prepareHakoRegistration() }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(appearance.colorScheme)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active {
                        Task { await AppNetworkService.shared.refresh() }
                        Task { await BuildPushSubscription.shared.refresh() }
                    }
                }
        }
    }
}

struct HomeView: View {
    private typealias Category = HakoApplications.Category
    private typealias Application = HakoApplications.Application

    private enum Destination: Hashable {
        case application(Application), notifications, settings
    }

    @ObservedObject private var console = ConsoleClient.shared
    @ObservedObject private var buildPush = BuildPushSubscription.shared
    @StateObject private var notifications = HakoNotificationsStore()
    @State private var path: [Destination] = []
    @State private var loginLink: HakoLoginLink?
    @State private var workshopPreview: WorkshopPushNotice?
    @State private var workshopSwitch: WorkshopPushNotice?
    @State private var category = Category.it
    @State private var versionWarning: String?
    @State private var lastVersionWarning: String?
    private struct HakoLoginLink: Identifiable { let id = UUID(); let payload: String }
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("你的日常，收进一个盒子。")
                            .font(.system(size: 22, weight: .semibold)).tracking(-0.5)
                        Text("HAKO · 个人工具箱")
                            .font(.system(size: 11)).tracking(1.1).foregroundStyle(HakoStyle.muted)
                    }
                    .padding(.bottom, 23)
                    categoryTabs
                    applications
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 28)
            }
            .background(HakoStyle.background)
            .foregroundStyle(HakoStyle.text)
            .navigationTitle("Hako")
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .application(let app): app.destination
                case .notifications: NotificationsView(store: notifications)
                case .settings: SettingsView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(HakoStyle.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("Hako").font(.system(size: 26, weight: .bold)).tracking(-1)
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                        .accessibilityAddTraits(.isHeader)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .principal) { Text("").accessibilityHidden(true) }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink(value: Destination.notifications) {
                        if notifications.notifications.isEmpty {
                            Image(systemName: "bell")
                        } else {
                            Image(systemName: "bell.badge")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.red, .primary)
                        }
                    }.accessibilityLabel("通知，\(notifications.notifications.count) 条待处理")
                    NavigationLink(value: Destination.settings) { Image(systemName: "gearshape") }.accessibilityLabel("设置")
                }
            }
        }
            // Reset the stack owner, including an already-pushed conversation.
            // Re-identifying only the workshop list leaves its old destination above it.
            .id(buildPush.workshopNavigationID)
            .tint(.primary)
            .overlay(alignment: .top) {
                if let notice = buildPush.workshopBanner {
                    WorkshopNotificationBanner(notice: notice, open: {
                        buildPush.dismissWorkshopNotice()
                        loginLink = nil
                        workshopPreview = notice
                    }, dismiss: { buildPush.dismissWorkshopNotice() })
                        .id(notice.id)
                        .padding(.horizontal, 12).padding(.top, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: buildPush.workshopBanner?.id)
            .sheet(item: $workshopPreview, onDismiss: {
                if let notice = workshopSwitch {
                    workshopSwitch = nil
                    buildPush.openWorkshopNotice(notice)
                }
            }) { notice in
                HakoApplications.notifications.preview(for: notice, destination: .codeWorkshop) {
                    workshopSwitch = notice
                    workshopPreview = nil
                }
            }
            .onChange(of: buildPush.workshopNavigationID) { _, _ in
                workshopSwitch = nil; workshopPreview = nil
            }
            .task(id: scenePhase == .active && buildPush.workshopRequested ? buildPush.workshopNavigationID : nil) {
                guard !Task.isCancelled, scenePhase == .active, buildPush.workshopRequested else { return }
                let requestID = buildPush.workshopNavigationID
                loginLink = nil
                path = [.application(.codeWorkshop)]
                buildPush.workshopHostReady(requestID)
            }
            .task(id: scenePhase == .active && buildPush.settingsRequested) {
                guard !Task.isCancelled, scenePhase == .active, buildPush.settingsRequested else { return }
                loginLink = nil
                path = [.settings]
                buildPush.settingsRequested = false
                HakoLog.record(.hako, "从构建通知打开设置")
            }
            .onOpenURL { url in
                // Accept only the existing exact Hako login structure and configured HTTPS server.
                guard let _ = try? ConsoleWebLoginPayload(url.absoluteString, origin: ConsoleClient.shared.serverURL) else { return }
                loginLink = HakoLoginLink(payload: url.absoluteString)
            }
            .sheet(item: $loginLink) { link in ConsoleWebLoginView(initialPayload: link.payload) }
            .alert("Hako 版本兼容性", isPresented: Binding(
                get: { versionWarning != nil },
                set: { if !$0 { versionWarning = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(versionWarning ?? "")
            }
            .task(id: scenePhase == .active ? console.serverURL : nil) {
                guard scenePhase == .active, !console.serverURL.isEmpty else { return }
                await checkServerVersion(origin: console.serverURL)
            }
            .toggleStyle(SwitchToggleStyle(tint: .green))
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await ConsoleClient.shared.restore()
                await BuildPushSubscription.shared.syncHako()
            }
            .task(id: "\(scenePhase)-\(console.requestContext)") {
                guard scenePhase == .active, console.authenticated, !console.logoutPending else { return }
                await notifications.run()
            }
    }

    private func checkServerVersion(origin: String) async {
        guard let result = await console.checkServerVersion(origin: origin),
              !Task.isCancelled, console.serverURL == origin, scenePhase == .active else { return }
        let warningKey = result.warning.map { origin + "\n" + $0 }
        if warningKey != lastVersionWarning {
            lastVersionWarning = warningKey
            versionWarning = result.warning
        }
    }

    private var categoryTabs: some View {
        HStack(spacing: 25) {
            ForEach(Category.allCases, id: \.self) { option in
                Button { category = option } label: {
                    Text(option.rawValue)
                        .font(.system(size: 14, weight: category == option ? .semibold : .regular))
                        .foregroundStyle(category == option ? HakoStyle.text : HakoStyle.muted)
                        .padding(.horizontal, 1).frame(minHeight: 44)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(category == option ? HakoStyle.text : .clear).frame(height: 2)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(category == option ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .background(alignment: .bottom) { Rectangle().fill(HakoStyle.line).frame(height: 1) }
        .accessibilityElement(children: .contain).accessibilityLabel("子应用分类")
    }

    private var applications: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text(category.rawValue).font(.system(size: 13, weight: .medium)).foregroundStyle(HakoStyle.text)
                Spacer()
                Text("\(category.applications.count) 个应用").font(.system(size: 12))
            }
            .foregroundStyle(HakoStyle.muted)
            .padding(.top, 20)

            if category.applications.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "building.columns")
                        .font(.system(size: 34, weight: .light)).foregroundStyle(HakoStyle.muted)
                        .padding(.bottom, 6).accessibilityHidden(true)
                    Text("暂无金融应用").font(.system(size: 17, weight: .semibold))
                    Text("后续金融应用将收录在这里。")
                        .font(.system(size: 13)).foregroundStyle(HakoStyle.muted)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).padding(.horizontal, 12).padding(.vertical, 75)
            } else {
                VStack(spacing: 0) {
                    ForEach(category.applications) { app in
                        if app != category.applications.first {
                            Rectangle().fill(HakoStyle.line).frame(height: 1).accessibilityHidden(true)
                        }
                        NavigationLink(value: Destination.application(app)) {
                            applicationRow(app)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func applicationRow(_ app: Application) -> some View {
        HStack(spacing: 13) {
            Group {
                if app == .qinglong {
                    Image("QinglongLogo").renderingMode(.template).resizable().scaledToFit()
                } else {
                    Image(systemName: app.symbol).font(.system(size: 22, weight: .regular))
                }
            }
            .frame(width: 24, height: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.rawValue).font(.system(size: 16, weight: .semibold))
                Text(app.subtitle).font(.system(size: 11)).foregroundStyle(HakoStyle.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                .foregroundStyle(HakoStyle.muted.opacity(0.65)).accessibilityHidden(true)
        }
        .padding(.vertical, 19).frame(minHeight: 78).contentShape(Rectangle())
    }
}

private struct WorkshopNotificationBanner: View {
    let notice: WorkshopPushNotice
    let open: () -> Void
    let dismiss: () -> Void
    @GestureState private var translation: CGSize = .zero

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: HakoApplications.Application.codeWorkshop.symbol)
                    .font(.title2).frame(width: 30).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(notice.title).font(.caption.weight(.semibold)).lineLimit(1)
                    if !notice.subtitle.isEmpty { Text(notice.subtitle).font(.subheadline).lineLimit(1) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 44).padding(.horizontal, 14).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(HakoStyle.text)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .offset(y: min(0, translation.height))
        .highPriorityGesture(DragGesture(minimumDistance: 12)
            .updating($translation) { value, state, _ in state = value.translation }
            .onEnded { value in
                if value.translation.height < -32 && abs(value.translation.height) > abs(value.translation.width) * 1.2 { dismiss() }
            })
        .accessibilityLabel("预览会话：" + (notice.subtitle.isEmpty ? notice.title : notice.subtitle))
        .accessibilityHint("向上滑动关闭通知")
        .accessibilityAction(named: Text("关闭通知"), dismiss)
    }
}
