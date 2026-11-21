import SwiftUI
import UIKit
import Combine

@MainActor private final class HakoPinDrawerMotion: ObservableObject {
    let width: CGFloat
    @Published var progress: CGFloat = 0
    @Published var dragging = false
    @Published var settling = false
    var editing = false

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
    private var drawerPan: UIPanGestureRecognizer?
    private var motion: HakoPinDrawerMotion?
    private var initialProgress: CGFloat = 0
    private var settlement: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var onEnter: ((HakoPinnedPage) -> Void)?
    private let registry = HakoApplications.pins

    func attach(to window: UIWindow, onEnter: @escaping (HakoPinnedPage) -> Void) {
        self.onEnter = onEnter
        guard self.window !== window else { return }
        selectionTask?.cancel()
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
            guard drawer == nil, selectionTask == nil, let edge, !(topController() is UIAlertController) else { return false }
            let velocity = edge.velocity(in: window)
            return HakoPinDrag.opens(velocityX: Double(velocity.x), velocityY: Double(velocity.y))
        }
        if gestureRecognizer === drawerPan, let pan = drawerPan, let motion,
           !motion.dragging, !motion.settling {
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
        guard gestureRecognizer === drawerPan, motion?.editing == true else { return true }
        // Keep native row editing intact; the header and backdrop still support folding.
        var view = touch.view
        while let current = view {
            if current is UIScrollView { return false }
            view = current.superview
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
        createDrawer()
        settleDrawer(open: true)
    }

    private func createDrawer() {
        guard let window, let parent = topController(), drawer == nil, selectionTask == nil else { return }
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
    }

    private func closeDrawer() {
        settleDrawer(open: false)
    }

    private func settleDrawer(open: Bool) {
        guard let motion else { return }
        settlement?.cancel()
        motion.dragging = false; motion.settling = true
        let duration = UIAccessibility.isReduceMotionEnabled ? 0.0 : 0.22
        withAnimation(duration == 0 ? nil : .easeOut(duration: duration)) { motion.progress = open ? 1 : 0 }
        settlement = Task { [weak self, weak motion] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, let motion, self.motion === motion else { return }
            motion.settling = false
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
        UIAccessibility.post(notification: .screenChanged, argument: topController()?.view)
    }

    private func select(_ page: HakoPinnedPage) {
        guard selectionTask == nil, registry.contains(page) else { return }
        removeDrawer()
        selectionTask = Task { [weak self, weak sourceWindow = window] in
            guard let self else { return }
            defer { self.selectionTask = nil }
            guard let sourceWindow else { return }
            // Detach the drawer after its button event finishes before presenting
            // another hosting tree. Keep one request through any ongoing transition.
            await Task.yield()
            while !Task.isCancelled {
                guard self.window === sourceWindow, !sourceWindow.isHidden,
                      sourceWindow.windowScene?.activationState == .foregroundActive else { return }
                if let presenter = self.topController(), !(presenter is UIAlertController),
                   presenter.viewIfLoaded?.window === sourceWindow,
                   !presenter.isBeingPresented, !presenter.isBeingDismissed,
                   presenter.transitionCoordinator == nil, presenter.presentedViewController == nil {
                    let content = HakoPinPreview(page: page, registry: self.registry, presenter: self) { [weak self] in self?.enter(page) }
                    let host = UIHostingController(rootView: content)
                    host.overrideUserInterfaceStyle = presenter.traitCollection.userInterfaceStyle
                    host.modalPresentationStyle = .pageSheet
                    host.sheetPresentationController?.detents = [.large()]
                    host.sheetPresentationController?.prefersGrabberVisible = true
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        presenter.present(host, animated: true) { continuation.resume() }
                    }
                    return
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
        }
    }

    private func enter(_ page: HakoPinnedPage) {
        guard registry.contains(page), let root = window?.rootViewController else { return }
        var current: UIViewController? = root
        while let controller = current {
            if controller.isModalInPresentation {
                let alert = UIAlertController(title: "请先保存当前页面", message: "当前页面有未完成的修改或操作。关闭预览后，先保存或关闭该页面，再进入固定页面。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "知道了", style: .default))
                topController()?.present(alert, animated: true)
                return
            }
            current = controller.presentedViewController
        }
        root.dismiss(animated: true) { [weak self] in self?.onEnter?(page) }
    }
}

private struct HakoPinPreview: View {
    let page: HakoPinnedPage
    let registry: HakoPinRegistry
    @ObservedObject var presenter: HakoPinPresenter
    let onEnter: () -> Void

    var body: some View {
        SettingsSheet(title: page.title, closePlacement: .topBarTrailing) {
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
    @State private var editing = EditMode.inactive
    private var pages: [HakoPinnedPage] { store.pages.filter { HakoApplications.pins.contains($0) } }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                Color.black.opacity(0.3 * Double(motion.progress)).ignoresSafeArea()
                    .onTapGesture(perform: close).accessibilityLabel("收起 Pin 列表").accessibilityAddTraits(.isButton)
                VStack(spacing: 0) {
                    HStack {
                        Text("Pin").font(.largeTitle.bold())
                        Text("\(pages.count)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                            .accessibilityLabel("关闭 Pin 列表")
                    }.padding(.horizontal, 20).padding(.top, geometry.safeAreaInsets.top + 12)
                    Text("把常用页面，留在手边。")
                        .font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.bottom, 10)
                    if pages.isEmpty {
                        ContentUnavailableView("还没有固定页面", systemImage: "pin",
                            description: Text("在代码工坊会话或容器详情的右上角更多菜单中，选择「加入 Pin」。"))
                            .frame(maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(pages) { page in
                                Button { select(page) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: page.symbol).font(.title3).frame(width: 38, height: 38)
                                            .background(HakoStyle.background, in: RoundedRectangle(cornerRadius: 10))
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(page.title).font(.subheadline.weight(.medium))
                                            Text(page.applicationID + (page.subtitle.isEmpty ? "" : " · " + page.subtitle))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 0)
                                        if !editing.isEditing { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                                    }.frame(minHeight: 60).frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(editing.isEditing)
                                    .listRowBackground(HakoStyle.card)
                                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                            }
                            .onDelete { offsets in store.remove(Set(offsets.map { pages[$0].id })) }
                            .onMove { store.move(from: $0, to: $1, among: Set(pages.map(\.id))) }
                        }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
                            .environment(\.editMode, $editing)
                    }
                    if let error = store.error { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal, 20) }
                    HStack {
                        Text("点选页面，快速查看").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(editing.isEditing ? "完成" : "管理") { editing = editing.isEditing ? .inactive : .active }
                            .frame(minWidth: 44, minHeight: 44).disabled(pages.isEmpty)
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
            .onChange(of: editing) { _, value in motion.editing = value.isEditing }
        }
    }
}
