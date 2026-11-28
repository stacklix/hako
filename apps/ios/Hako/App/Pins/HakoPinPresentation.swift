import SwiftUI
import UIKit
import Combine

@MainActor private final class HakoPinDrawerMotion: ObservableObject {
    let width: CGFloat
    @Published var progress: CGFloat = 0
    @Published var dragging = false
    @Published var settling = false

    init(width: CGFloat) { self.width = width }
}

/// The recognizer belongs to the window so it also sees gestures over presented sheets.
struct HakoPinGestureHost: UIViewControllerRepresentable {
    let onEnter: (HakoPinnedPage) -> Void

    func makeUIViewController(context: Context) -> Controller { Controller(onEnter: onEnter) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.onEnter = onEnter; controller.attach() }

    final class Controller: UIViewController {
        var onEnter: (HakoPinnedPage) -> Void
        init(onEnter: @escaping (HakoPinnedPage) -> Void) { self.onEnter = onEnter; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); attach() }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); attach() }
        func attach() {
            guard let window = view.window else { return }
            HakoPinPresenter.shared.attach(to: window, onEnter: onEnter)
        }
    }
}

@MainActor final class HakoPinPresenter: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    static let shared = HakoPinPresenter()
    // UIKit presents this independent hosting tree, so forward the owning SwiftUI scene's lifecycle.
    @Published var scenePhase: ScenePhase = .inactive
    private weak var window: UIWindow?
    private var edge: UIPanGestureRecognizer?
    private var drawer: UIHostingController<HakoPinDrawer>?
    private var drawerWindow: UIWindow?
    private weak var notificationHost: UIViewController?
    private var drawerPan: UIPanGestureRecognizer?
    private var motion: HakoPinDrawerMotion?
    private var initialProgress: CGFloat = 0
    private var settlement: Task<Void, Never>?
    private enum Presentation {
        case pinned(HakoPinnedPage)
        case notification(WorkshopPushNotice)
        case navigation(@MainActor () -> Void)
    }
    private lazy var presentations = HakoPresentationQueue<Presentation> { [weak self] request, isCurrent in
        await self?.perform(request, isCurrent: isCurrent)
    }
    private var onEnter: ((HakoPinnedPage) -> Void)?
    private let registry = HakoApplications.pins

    func attach(to window: UIWindow, onEnter: @escaping (HakoPinnedPage) -> Void) {
        self.onEnter = onEnter
        guard self.window !== window else { return }
        if self.window != nil { presentations.cancel() }
        if let edge { self.window?.removeGestureRecognizer(edge) }
        removeDrawer()
        self.window = window
        let gesture = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        gesture.maximumNumberOfTouches = 1; gesture.delegate = self
        window.addGestureRecognizer(gesture)
        edge = gesture
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === edge {
            guard drawer == nil, !presentations.isBusy, let edge, !(topController() is UIAlertController) else { return false }
            let velocity = edge.velocity(in: window)
            return HakoPinDrag.opens(velocityX: Double(velocity.x), velocityY: Double(velocity.y))
        }
        if gestureRecognizer === drawerPan, let pan = drawerPan, let motion,
           !motion.dragging, !motion.settling {
            guard drawer?.presentedViewController == nil else { return false }
            let velocity = pan.velocity(in: drawerWindow)
            return velocity.x > 0 && abs(velocity.x) > abs(velocity.y) * 1.2
        }
        return false
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === edge {
            guard let window, drawer == nil else { return false }
            let point = touch.location(in: window)
            return HakoPinDrag.acceptsStart(x: Double(point.x - window.bounds.minX),
                y: Double(point.y - window.bounds.minY), width: Double(window.bounds.width), height: Double(window.bounds.height))
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        (gestureRecognizer === edge || gestureRecognizer === drawerPan) &&
            otherGestureRecognizer !== edge && otherGestureRecognizer !== drawerPan &&
            otherGestureRecognizer is UIPanGestureRecognizer
    }

    @objc private func swiped(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { createDrawer(); initialProgress = 0; motion?.dragging = true }
        updateDrag(gesture, in: window)
    }

    @objc private func drawerSwiped(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { initialProgress = motion?.progress ?? 1; motion?.dragging = true }
        updateDrag(gesture, in: drawerWindow)
    }

    private func updateDrag(_ gesture: UIPanGestureRecognizer, in view: UIView?) {
        guard let motion, motion.dragging else { return }
        let progress = HakoPinDrag.progress(from: Double(initialProgress),
            translationX: Double(gesture.translation(in: view).x), width: Double(motion.width))
        switch gesture.state {
        case .began, .changed:
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { motion.progress = CGFloat(progress) }
        case .ended, .cancelled, .failed:
            let target = HakoPinDrag.shouldOpen(progress: progress,
                velocityX: Double(gesture.velocity(in: view).x), width: Double(motion.width),
                initial: Double(initialProgress), cancelled: gesture.state != .ended)
            motion.dragging = false
            settleDrawer(open: target)
        default: break
        }
    }

    private func topController() -> UIViewController? {
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController, !presented.isBeingDismissed { controller = presented }
        return controller
    }

    func openDrawer() {
        trace("请求打开快捷访问")
        createDrawer()
        settleDrawer(open: true)
    }

    private func createDrawer() {
        guard let window, let parent = topController(), drawer == nil, !presentations.isBusy else { return }
        guard let scene = window.windowScene else { return }
        window.endEditing(true)
        let motion = HakoPinDrawerMotion(width: min(330, max(1, window.bounds.width - 52)))
        let host = UIHostingController(rootView: HakoPinDrawer(motion: motion, close: { [weak self] in self?.closeDrawer() },
            select: { [weak self] page in self?.select(page) }))
        let overlay = UIWindow(windowScene: scene)
        overlay.frame = window.frame
        overlay.windowLevel = UIWindow.Level(rawValue: window.windowLevel.rawValue + 1)
        host.overrideUserInterfaceStyle = parent.traitCollection.userInterfaceStyle
        host.view.backgroundColor = .clear; host.view.accessibilityViewIsModal = true
        overlay.backgroundColor = .clear; overlay.rootViewController = host
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drawerSwiped(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        overlay.addGestureRecognizer(pan)
        drawerPan = pan
        self.motion = motion
        overlay.isHidden = false
        drawerWindow = overlay
        drawer = host
        trace("快捷访问浮层已创建")
    }

    private func closeDrawer() {
        settleDrawer(open: false)
    }

    private func settleDrawer(open: Bool) {
        guard let motion else { return }
        trace(open ? "快捷访问开始展开" : "快捷访问开始收起")
        settlement?.cancel()
        motion.dragging = false; motion.settling = true
        let duration = UIAccessibility.isReduceMotionEnabled ? 0.0 : 0.22
        withAnimation(duration == 0 ? nil : .easeOut(duration: duration)) { motion.progress = open ? 1 : 0 }
        settlement = Task { [weak self, weak motion] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, let motion, self.motion === motion else { return }
            motion.settling = false
            self.trace(open ? "快捷访问展开完成" : "快捷访问收起完成")
            if open { UIAccessibility.post(notification: .screenChanged, argument: self.drawer?.view) }
            else { self.removeDrawer() }
        }
    }

    private func removeDrawer() {
        guard drawer != nil else { return }
        settlement?.cancel(); settlement = nil
        drawerPan = nil; motion = nil
        drawerWindow?.isHidden = true; drawerWindow?.rootViewController = nil
        drawerWindow = nil
        drawer = nil
        trace("快捷访问浮层已移除")
        UIAccessibility.post(notification: .screenChanged, argument: topController()?.view)
    }

    private func select(_ page: HakoPinnedPage) {
        guard !presentations.isBusy, registry.contains(page) else { return }
        trace("点击快捷会话/页面")
        presentations.submit(.pinned(page))
    }

    private func enter(_ page: HakoPinnedPage) {
        guard registry.contains(page) else { return }
        navigateAfterDismissing { [weak self] in self?.onEnter?(page) }
    }

    func presentWorkshopNotification(_ notice: WorkshopPushNotice) {
        trace("收到通知会话预览请求")
        presentations.submit(.notification(notice))
    }

    func navigateAfterDismissing(_ action: @escaping @MainActor () -> Void) {
        trace("收到完整页面跳转请求")
        presentations.submit(.navigation(action))
    }

    private func perform(_ request: Presentation, isCurrent: @escaping @MainActor () -> Bool) async {
        let operation = UUID().uuidString
        trace("弹层请求开始处理", detail: "operation=\(operation)")
        defer { trace("弹层请求处理结束", detail: "operation=\(operation), current=\(isCurrent())") }
        // Leave the originating button/notification callback before touching UIKit.
        await Task.yield()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while isCurrent(), window == nil, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        guard isCurrent() else { return }
        guard let sourceWindow = window else {
            trace("等待页面窗口超时")
            HakoDiagnosticStore.shared.record(.presentation, detail: "通知/快捷页面请求在 10 秒内未获得页面窗口，未继续导航。")
            return
        }
        if let overlay = drawerWindow {
            guard let top = await stablePresenter(in: overlay, isCurrent: isCurrent),
                  !blocksNavigation(in: overlay, top: top) else { return }
            if let root = overlay.rootViewController, root.presentedViewController != nil {
                guard await transition({ root.dismiss(animated: false, completion: $0) }), isCurrent() else { return }
            }
        }
        guard isCurrent() else { return }
        removeDrawer()
        guard let presenter = await stablePresenter(in: sourceWindow, isCurrent: isCurrent) else { return }
        switch request {
        case .navigation(let action):
            guard !blocksNavigation(in: sourceWindow, top: presenter), let root = sourceWindow.rootViewController else { return }
            HakoLog.record(.hako, "准备关闭弹层并切换页面")
            if root.presentedViewController != nil {
                guard await transition({ root.dismiss(animated: true, completion: $0) }) else { return }
            }
            guard isCurrent(), window === sourceWindow,
                  await stablePresenter(in: sourceWindow, isCurrent: isCurrent) === root else { return }
            // SwiftUI may finish its sheet binding update in the same dismissal callback.
            await Task.yield()
            guard isCurrent() else { return }
            HakoLog.record(.hako, "弹层已关闭，开始切换页面")
            trace("开始切换完整页面")
            action()
        case .pinned(let page):
            guard registry.contains(page) else { return }
            let content = HakoPinPreview(page: page, registry: registry, presenter: self) { [weak self] in self?.enter(page) }
            await present(UIHostingController(rootView: content), from: presenter)
        case .notification(let notice):
            var targetPresenter = presenter
            if let previous = notificationHost, let owner = previous.presentingViewController {
                guard !blocksNavigation(in: sourceWindow, top: presenter),
                      await transition({ owner.dismiss(animated: true, completion: $0) }), isCurrent(),
                      let next = await stablePresenter(in: sourceWindow, isCurrent: isCurrent) else { return }
                notificationHost = nil
                targetPresenter = next
            }
            guard let content = HakoApplications.notifications.preview(for: notice, destination: .codeWorkshop, onOpen: {
                BuildPushSubscription.shared.openWorkshopNotice(notice)
            }) else { return }
            HakoLog.record(.codeWorkshop, "准备从当前弹层打开通知会话预览")
            let host = UIHostingController(rootView: HakoWorkshopNotificationPreview(content: content, presenter: self))
            notificationHost = host
            if await present(host, from: targetPresenter) {
                HakoLog.record(.codeWorkshop, "通知会话预览已呈现")
            }
        }
    }

    @discardableResult private func present(_ host: UIViewController, from presenter: UIViewController) async -> Bool {
        host.overrideUserInterfaceStyle = presenter.traitCollection.userInterfaceStyle
        host.modalPresentationStyle = .pageSheet
        host.sheetPresentationController?.detents = [.large()]
        host.sheetPresentationController?.prefersGrabberVisible = true
        return await transition { presenter.present(host, animated: true, completion: $0) }
    }

    private func stablePresenter(in sourceWindow: UIWindow, isCurrent: @escaping @MainActor () -> Bool) async -> UIViewController? {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while isCurrent(), !sourceWindow.isHidden, ContinuousClock.now < deadline {
            var top = sourceWindow.rootViewController
            var visited = Set<ObjectIdentifier>()
            while let controller = top, visited.insert(ObjectIdentifier(controller)).inserted,
                  let next = controller.presentedViewController, !next.isBeingDismissed { top = next }
            if sourceWindow.windowScene?.activationState == .foregroundActive, let top,
               !(top is UIAlertController), top.viewIfLoaded?.window === sourceWindow,
               !top.isBeingPresented, !top.isBeingDismissed, top.transitionCoordinator == nil,
               top.presentedViewController == nil { return top }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
        }
        if isCurrent() {
            HakoLog.record(.hako, .warning, "等待弹层切换就绪超时，未继续导航")
            trace("等待弹层切换就绪超时")
            HakoDiagnosticStore.shared.record(.presentation, detail: "未能在 10 秒期限内取得就绪弹层（可能已隐藏或切换），未继续导航。\n" + diagnosticContext())
        }
        return nil
    }

    private func blocksNavigation(in sourceWindow: UIWindow, top: UIViewController) -> Bool {
        var current = sourceWindow.rootViewController
        var visited = Set<ObjectIdentifier>()
        while let controller = current, visited.insert(ObjectIdentifier(controller)).inserted {
            if controller.isModalInPresentation {
                trace("页面跳转被未完成修改/操作阻止")
                let alert = UIAlertController(title: "请先保存当前页面", message: "当前页面有未完成的修改或操作，请先保存或关闭该页面，再切换。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "知道了", style: .default))
                top.present(alert, animated: true)
                return true
            }
            current = controller.presentedViewController
        }
        return false
    }

    private func transition(_ start: (@escaping () -> Void) -> Void) async -> Bool {
        trace("UIKit 弹层动画开始")
        let context = diagnosticContext()
        return await withCheckedContinuation { continuation in
            let completion = HakoPresentationCompletion(continuation, context: context)
            completion.armTimeout()
            start { completion.finish(true) }
        }
    }

    private func trace(_ event: String, detail: String = "") {
        HakoDiagnosticStore.shared.breadcrumb(event, detail: detail + "\n" + diagnosticContext())
    }

    // Controller types and transition flags only: never capture page titles,
    // notification contents, URLs, conversation messages or credential fields.
    private func diagnosticContext() -> String {
        func chain(_ root: UIViewController?) -> String {
            var current = root, visited = Set<ObjectIdentifier>(), result: [String] = []
            while let controller = current, result.count < 8, visited.insert(ObjectIdentifier(controller)).inserted {
                result.append("\(String(describing: type(of: controller)).prefix(100))[presenting=\(controller.isBeingPresented), dismissing=\(controller.isBeingDismissed), transition=\(controller.transitionCoordinator != nil), protected=\(controller.isModalInPresentation)]")
                current = controller.presentedViewController
            }
            return result.joined(separator: " → ")
        }
        return "scene=\(scenePhase), queueBusy=\(presentations.isBusy), drawer=\(drawer != nil), settling=\(motion?.settling ?? false), hidden=\(window?.isHidden ?? true)\n页面：\(chain(window?.rootViewController))\n浮层：\(chain(drawer?.presentedViewController))"
    }
}

@MainActor private final class HakoPresentationCompletion {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var timeout: Task<Void, Never>?
    private let context: String
    init(_ continuation: CheckedContinuation<Bool, Never>, context: String) { self.continuation = continuation; self.context = context }
    func armTimeout() {
        timeout = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            HakoLog.record(.hako, .warning, "弹层动画完成回调超时，未继续导航")
            HakoDiagnosticStore.shared.record(.presentation, detail: "UIKit 弹层动画完成回调超过 10 秒未返回。\n开始时的状态：\n" + context)
            finish(false)
        }
    }
    func finish(_ completed: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        HakoDiagnosticStore.shared.breadcrumb(completed ? "UIKit 弹层动画完成" : "UIKit 弹层动画超时")
        timeout?.cancel(); timeout = nil
        continuation.resume(returning: completed)
    }
}

private struct HakoWorkshopNotificationPreview: View {
    let content: AnyView
    @ObservedObject var presenter: HakoPinPresenter
    var body: some View {
        content.environment(\.scenePhase, presenter.scenePhase).tint(.primary)
    }
}

private struct HakoPinPreview: View {
    let page: HakoPinnedPage
    let registry: HakoPinRegistry
    @ObservedObject var presenter: HakoPinPresenter
    let onEnter: () -> Void

    var body: some View {
        SettingsSheet(title: page.title, edgeDismissEnabled: true, closePlacement: .topBarTrailing) {
            registry.content(for: page)
                .environment(\.hakoPinPreview, true)
                .environment(\.hakoPinEnter, onEnter)
                .toolbar {
                    if !registry.providesPreviewNavigation(for: page) {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("进入", systemImage: "arrow.up.right", action: onEnter)
                                .accessibilityLabel("进入" + page.title).disabled(!registry.contains(page))
                        }
                    }
                }
        }
        .environment(\.scenePhase, presenter.scenePhase)
        .tint(.primary)
    }
}

private struct HakoPinDrawer: View {
    @ObservedObject var motion: HakoPinDrawerMotion
    let close: () -> Void
    let select: (HakoPinnedPage) -> Void
    @ObservedObject private var store = HakoPinStore.shared
    @ObservedObject private var presenter = HakoPinPresenter.shared
    @State private var showingSettings = false
    @State private var selectedCollection = "pinned"
    private let registry = HakoApplications.pins
    private var pages: [HakoPinnedPage] { store.pages.filter { HakoApplications.pins.contains($0) } }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.3 * Double(motion.progress)).ignoresSafeArea()
                    .onTapGesture(perform: close).accessibilityLabel("收起快捷访问").accessibilityAddTraits(.isButton)
                VStack(spacing: 0) {
                    HStack {
                        Text("快捷访问").font(.largeTitle.bold())
                        Spacer()
                        Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                            .accessibilityLabel("关闭快捷访问")
                    }.padding(.horizontal, 20).padding(.top, geometry.safeAreaInsets.top + 12).padding(.bottom, 16)
                    HStack(spacing: 24) {
                        tab("已固定", id: "pinned", count: pages.count)
                        ForEach(registry.collections) { collection in
                            tab(collection.title, id: collection.id)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 20)
                    .overlay(alignment: .bottom) { HakoStyle.line.frame(height: 0.5).padding(.horizontal, 20) }
                    if let collection = registry.collections.first(where: { $0.id == selectedCollection }) {
                        collection.content(select)
                            .environment(\.scenePhase, presenter.scenePhase)
                    } else if pages.isEmpty {
                        ContentUnavailableView("还没有固定页面", systemImage: "pin",
                            description: Text("在代码工坊会话或容器详情的右上角更多菜单中，选择「加入 Pin」。"))
                            .frame(maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(pages) { page in
                                Button { select(page) } label: {
                                    HStack(spacing: 12) {
                                        registry.icon(for: page).font(.title3).frame(width: 38, height: 38)
                                            .background(HakoStyle.background, in: RoundedRectangle(cornerRadius: 10))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(page.title).font(.subheadline.weight(.medium))
                                            Text(page.applicationID + (page.subtitle.isEmpty ? "" : " · " + page.subtitle))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    }.frame(minHeight: 60).frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                    .listRowBackground(HakoStyle.card)
                                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                            }
                            .onDelete { offsets in store.remove(Set(offsets.map { pages[$0].id })) }
                            .onMove { store.move(from: $0, to: $1, among: Set(pages.map(\.id))) }
                        }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
                    }
                    if let error = store.error { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal, 20) }
                    HStack {
                        Text("点选页面，快速查看").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { showingSettings = true } label: {
                            Image(systemName: "gearshape").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("主应用设置")
                    }.padding(.horizontal, 20).padding(.bottom, geometry.safeAreaInsets.bottom + 8)
                }
                .frame(width: motion.width)
                .background(HakoStyle.background)
                .clipShape(.rect(topLeadingRadius: 28, bottomLeadingRadius: 28))
                .offset(x: motion.width * (1 - motion.progress))
            .allowsHitTesting(!motion.dragging && (!motion.settling || motion.progress == 1))
            }
            .ignoresSafeArea()
            .foregroundStyle(HakoStyle.text).tint(.primary)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, close)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsSheet(title: "设置", edgeDismissEnabled: true) {
                SettingsView()
            }
            .environment(\.scenePhase, presenter.scenePhase)
            .tint(.primary)
        }
    }

    private func tab(_ title: String, id: String, count: Int? = nil) -> some View {
        let selected = selectedCollection == id
        return Button { selectedCollection = id } label: {
            HStack(spacing: 5) {
                Text(title).font(.subheadline.weight(.medium))
                if let count { Text("\(count)").font(.caption2).foregroundStyle(.secondary) }
            }
            .foregroundStyle(selected ? HakoStyle.text : HakoStyle.muted)
            .padding(.bottom, 12).frame(minHeight: 44)
            .overlay(alignment: .bottom) {
                if selected { HakoStyle.text.frame(height: 2) }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
