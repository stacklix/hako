import SwiftUI
import UIKit
import Combine

/// Captures the presenting page, rather than the window that also contains the conversation.
@MainActor final class WorkshopPageCapture: ObservableObject {
    @Published private(set) var available = false
    private weak var anchor: UIViewController?

    func attach(_ controller: UIViewController) {
        anchor = controller
        // UIKit layout callbacks can run during a SwiftUI update.
        DispatchQueue.main.async { [weak self, weak controller] in
            guard let self, let controller, self.anchor === controller else { return }
            let next = self.presentingPage() != nil
            if self.available != next { self.available = next }
        }
    }

    func detach(_ controller: UIViewController) {
        guard anchor === controller else { return }
        anchor = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.anchor == nil else { return }
            self.available = false
        }
    }

    func capture() throws -> Data {
        guard let page = presentingPage() else {
            throw HakoError(message: "无法截取背后页面，请在会话 Sheet 中重试。")
        }
        page.layoutIfNeeded()
        let size = page.bounds.size
        guard size.width > 0, size.height > 0 else {
            throw HakoError(message: "背后页面尚未完成布局，请稍后重试。")
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(page.traitCollection.displayScale, 2048 / max(size.width, size.height))
        format.opaque = true
        let bounds = CGRect(origin: .zero, size: size)
        var complete = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemBackground.setFill()
            context.fill(bounds)
            complete = page.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        guard complete, let data = image.pngData() else {
            throw HakoError(message: "页面截图不完整，未添加图片，请稍后重试。")
        }
        return data
    }

    private func presentingPage() -> UIView? {
        guard let anchor, anchor.viewIfLoaded?.window != nil else { return nil }
        var sheet = anchor
        while let parent = sheet.parent { sheet = parent }
        guard let presentation = sheet.presentationController as? UISheetPresentationController,
              sheet.presentingViewController != nil,
              !sheet.isBeingPresented, !sheet.isBeingDismissed,
              sheet.presentedViewController == nil,
              let page = presentation.presentingViewController.viewIfLoaded,
              page.window === anchor.view.window, !page.isHidden, page.alpha > 0,
              !sheet.view.isDescendant(of: page) else { return nil }
        // The Sheet and its dimming view are siblings outside this subtree. Rendering
        // this page also excludes the keyboard, without dismissing or rebuilding anything.
        return page
    }
}

struct WorkshopPageCaptureHost: UIViewControllerRepresentable {
    let capture: WorkshopPageCapture

    func makeUIViewController(context: Context) -> Controller { Controller(capture: capture) }
    func updateUIViewController(_ controller: Controller, context: Context) { capture.attach(controller) }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.capture.detach(controller) }

    final class Controller: UIViewController {
        let capture: WorkshopPageCapture

        init(capture: WorkshopPageCapture) {
            self.capture = capture
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); capture.attach(self) }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); capture.attach(self) }
        override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); capture.attach(self) }
    }
}
