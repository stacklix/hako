import SwiftUI
import UIKit

// Presents above the current sub-application or settings sheet, without
// replacing its navigation state. No notification permission or background work.
@MainActor final class ConsoleLoginPromptCoordinator: NSObject, UITextFieldDelegate {
    static let shared = ConsoleLoginPromptCoordinator()
    private var generation = UUID()
    private var context = ""
    private var suppressed: [String: Date] = [:]
    private var errors: [String: String] = [:]
    private var alert: UIAlertController?
    private var promptID: String?
    private var approveAction: UIAlertAction?
    private var submitting = false

    func run() async {
        let client = ConsoleClient.shared
        let expected = client.requestContext
        let run = UUID()
        generation = run
        dismissPrompt()
        if context != expected { suppressed = [:]; errors = [:]; context = expected }
        defer { if generation == run { dismissPrompt() } }
        while !Task.isCancelled && client.authenticated && !client.logoutPending && client.requestContext == expected {
            guard UIApplication.shared.applicationState == .active else { return }
            var delay: UInt64 = 3
            do {
                let prompts = try await client.pendingLoginPrompts()
                try Task.checkCancellation()
                guard generation == run, client.requestContext == expected else { return }
                suppressed = suppressed.filter { $0.value > .now }
                let live = Set(prompts.map(\.id))
                errors = errors.filter { live.contains($0.key) }
                if let promptID, !live.contains(promptID) { dismissPrompt() }
                if !submitting, alert == nil, let prompt = prompts.first(where: { suppressed[$0.id] == nil }) {
                    present(prompt, context: expected)
                }
            } catch {
                guard !Task.isCancelled, generation == run, client.requestContext == expected else { return }
                dismissPrompt()
                // Older servers have no discovery endpoint. Do not flood them.
                delay = (error as? ServerHTTPError)?.status == 404 ? 30 : 6
            }
            do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
        }
    }

    private func presenter() -> UIViewController? {
        guard UIApplication.shared.applicationState == .active,
              let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }),
              var top = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return nil }
        while let next = top.presentedViewController { top = next }
        guard !(top is UIAlertController), !top.isBeingDismissed, !top.isBeingPresented, top.viewIfLoaded?.window != nil else { return nil }
        return top
    }

    private func present(_ prompt: ConsoleLoginPrompt, context expected: String) {
        guard let top = presenter(), (prompt.expiry ?? .distantPast) > .now else { return }
        let profile = prompt.scopes.split(separator: " ").contains("profile") ? "账号标识、账号名称" : "账号标识"
        let error = errors[prompt.id].map { "\n\n\($0)" } ?? ""
        let message = "登记来源：\(prompt.applicationOrigin)\n申请资料：\(profile)\n浏览器：\(prompt.browser)\n来源 IP：\(prompt.clientIP)\n\n只批准自己发起的登录。请输入原浏览器显示的六位确认码。" + error
        let dialog = UIAlertController(title: "登录到 \(prompt.application)", message: message, preferredStyle: .alert)
        dialog.addTextField { [weak self] field in
            field.placeholder = "六位确认码"
            field.accessibilityLabel = "原浏览器上的六位确认码"
            field.keyboardType = .numberPad
            field.autocorrectionType = .no
            field.delegate = self
            field.addTarget(self, action: #selector(ConsoleLoginPromptCoordinator.codeChanged(_:)), for: .editingChanged)
        }
        let approve = UIAlertAction(title: "确认登录", style: .default) { [weak self, weak dialog] _ in
            let code = dialog?.textFields?.first?.text ?? ""
            self?.submit(prompt, code: code, approve: true, context: expected)
        }
        approve.isEnabled = false
        dialog.addAction(approve)
        dialog.addAction(UIAlertAction(title: "拒绝登录", style: .destructive) { [weak self] _ in
            self?.submit(prompt, code: "", approve: false, context: expected)
        })
        dialog.addAction(UIAlertAction(title: "稍后", style: .cancel) { [weak self] _ in
            self?.suppressed[prompt.id] = prompt.expiry
            self?.alert = nil; self?.promptID = nil; self?.approveAction = nil
        })
        alert = dialog; promptID = prompt.id; approveAction = approve
        top.present(dialog, animated: true)
    }

    @objc private func codeChanged(_ field: UITextField) {
        approveAction?.isEnabled = ConsoleLoginPrompt.validCode(field.text ?? "")
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        guard let text = textField.text, let range = Range(range, in: text) else { return false }
        let value = text.replacingCharacters(in: range, with: string)
        return value.utf8.count <= 6 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private func submit(_ prompt: ConsoleLoginPrompt, code: String, approve: Bool, context expected: String) {
        alert = nil; promptID = nil; approveAction = nil
        guard !submitting, expected == ConsoleClient.shared.requestContext else { return }
        submitting = true
        Task {
            defer { submitting = false }
            do {
                try await ConsoleClient.shared.confirmLoginPrompt(prompt, code: code, approve: approve)
                guard expected == context else { return }
                suppressed[prompt.id] = prompt.expiry
            } catch {
                guard expected == context, expected == ConsoleClient.shared.requestContext,
                      UIApplication.shared.applicationState == .active else { return }
                if let failure = error as? ServerHTTPError, failure.code == "login_confirmation_mismatch" {
                    errors[prompt.id] = "确认码不匹配，请核对原浏览器后重新输入。"
                } else {
                    suppressed[prompt.id] = prompt.expiry
                    guard let top = presenter() else { return }
                    let text = (error as? ServerHTTPError)?.errorDescription ?? "未能确认处理结果。请回到原浏览器查看，不会自动重复提交。"
                    let dialog = UIAlertController(title: "登录确认未完成", message: text, preferredStyle: .alert)
                    dialog.addAction(UIAlertAction(title: "好", style: .default) { [weak self] _ in self?.alert = nil })
                    alert = dialog
                    top.present(dialog, animated: true)
                }
            }
        }
    }

    private func dismissPrompt() {
        alert?.textFields?.forEach { $0.text = "" }
        alert?.dismiss(animated: false)
        alert = nil; promptID = nil; approveAction = nil
    }
}
