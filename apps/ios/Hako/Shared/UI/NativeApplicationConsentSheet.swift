import SwiftUI

/// Generic host confirmation, containing no child business implementation.
@MainActor struct NativeApplicationConsentSheet: View {
    let consent: NativeApplicationConsent
    var authentication: any AuthenticatedServerAccess = AuthenticatedServerService.shared
    let onConfirm: () async throws -> Void
    @State private var busy = false
    @State private var error: String?
    @State private var authorizationTask: Task<Void, Never>?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SettingsSheet(title: "使用 Hako 登录", isBusy: busy) {
            Form {
                Section {
                    LabeledContent("应用", value: consent.application)
                    LabeledContent("应用地址", value: consent.request.applicationOrigin)
                    LabeledContent("Hako 服务器", value: consent.request.issuer)
                    LabeledContent("当前账号", value: consent.username)
                } footer: {
                    Text("应用将获得你的账号标识与账号名称。确认后，此设备可以自动登录该应用；你可在 Hako 已登录设备中移除应用授权。")
                }
                Section {
                    Button(busy ? "正在授权…" : "同意并登录") {
                        guard !busy else { return }
                        busy = true; error = nil
                        authorizationTask = Task { @MainActor in
                            defer { busy = false }
                            do { try await onConfirm(); dismiss() }
                            catch is CancellationError { dismiss() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .buttonStyle(HakoActionButtonStyle())
                    .disabled(busy)
                    if let error { Text(error).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) }
                }
            }
        }
        .onAppear { closeIfIdentityChanged() }
        .onReceive(authentication.changes) { _ in
            // objectWillChange arrives before the changed context is assigned.
            Task { @MainActor in closeIfIdentityChanged() }
        }
        .onDisappear { authorizationTask?.cancel() }
    }

    private func closeIfIdentityChanged() {
        guard !consent.isCurrent(using: authentication) else { return }
        authorizationTask?.cancel()
        dismiss()
    }
}
