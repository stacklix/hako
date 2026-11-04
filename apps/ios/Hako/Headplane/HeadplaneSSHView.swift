import SwiftUI
import WebKit

// Headplane's WASM client joins the Tailnet and implements Tailscale SSH.
// Its OIDC session is deliberately isolated from the native API Key session.
@MainActor final class HeadplaneSSHSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private let connection: HeadplaneConnection
    private let hostname: String
    private var terminalURL: URL?
    private var awaitingLogin = false
    @Published var webLoginPayload: String?
    @Published private(set) var opened = false
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    init(connection: HeadplaneConnection, hostname: String) {
        self.connection = connection
        self.hostname = hostname
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.keyboardDismissMode = .interactive
    }

    func connect(username: String) {
        do {
            terminalURL = try HeadplaneSSH.terminalURL(connection: connection, hostname: hostname, username: username)
            awaitingLogin = false
            opened = true
            load(terminalURL!)
        } catch { self.error = error.localizedDescription }
    }

    func signIn() {
        guard var url = URL(string: connection.address) else { return }
        url.appendPathComponent("oidc"); url.appendPathComponent("start")
        awaitingLogin = true
        load(url)
    }

    func returnToTerminal() {
        guard let terminalURL else { return }
        awaitingLogin = false
        load(terminalURL)
    }

    private func load(_ url: URL) {
        error = nil
        loading = true
        webView.load(URLRequest(url: url))
    }

    func shutdown() {
        awaitingLogin = false
        webView.stopLoading()
        // Navigating away destroys the page's WASM runtime and terminal connection.
        webView.loadHTMLString("", baseURL: nil)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, url.scheme == "hako" {
            // Only the configured Hako authorization page may open its own v3 request.
            if navigationAction.navigationType == .linkActivated, navigationAction.sourceFrame.isMainFrame,
               navigationAction.targetFrame?.isMainFrame != false,
               ConsoleWebLoginPayload.allowsOIDCLink(url.absoluteString, source: navigationAction.sourceFrame.request.url, origin: AuthenticatedServerService.shared.serverURL),
               webView.url == navigationAction.sourceFrame.request.url {
                webLoginPayload = url.absoluteString
            }
            decisionHandler(.cancel)
            return
        }
        guard let url = navigationAction.request.url,
              HeadplaneSSH.allowsNavigation(url, allowHTTP: connection.allowHTTP) else {
            error = "无法在终端中打开此链接，请使用 HTTPS 登录页面。"
            loading = false
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loading = false
        if awaitingLogin, let url = webView.url, HeadplaneSSH.isLoginReturn(url, connection: connection) {
            returnToTerminal()
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        guard (error as? URLError)?.code != .cancelled else { return }
        loading = false
        self.error = "终端页面加载失败，请检查网络与 Headplane 地址后重新连接。"
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loading = false
        error = "终端页面已停止，请重新连接。"
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Complete provider popups in this same isolated browser session.
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url,
           HeadplaneSSH.allowsNavigation(url, allowHTTP: connection.allowHTTP) {
            load(url)
        }
        return nil
    }
}

private struct HeadplaneSSHWebView: UIViewRepresentable {
    let session: HeadplaneSSHSession
    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

struct HeadplaneSSHView: View {
    let hostname: String
    @StateObject private var session: HeadplaneSSHSession
    @State private var username = ""
    @State private var closing = false
    @Environment(\.dismiss) private var dismiss

    init(connection: HeadplaneConnection, hostname: String) {
        self.hostname = hostname
        _session = StateObject(wrappedValue: HeadplaneSSHSession(connection: connection, hostname: hostname))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if session.opened {
                    if session.loading { ProgressView().frame(maxWidth: .infinity).padding(8) }
                    if let error = session.error {
                        Text(error).font(.footnote).foregroundStyle(HeadplaneStyle.red).padding(12)
                    }
                    HeadplaneSSHWebView(session: session)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            HeadplaneFact(title: "目标设备", value: hostname)
                            HeadplaneField(title: "SSH 用户名") {
                                TextField("例如：ubuntu", text: $username)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .accessibilityLabel("SSH 用户名")
                            }
                            Text("使用 Headplane 的 Web SSH 终端。首次连接请点击右上角登录，使用已关联 Headscale 用户的 OIDC 账号；API Key 无法用于 SSH。")
                                .font(.footnote).foregroundStyle(HeadplaneStyle.muted)
                            Text("服务器需启用 Headplane Agent，目标设备需在线并启用 Tailscale SSH，访问策略需允许当前用户连接。")
                                .font(.footnote).foregroundStyle(HeadplaneStyle.muted)
                            HeadplaneErrorText(message: session.error)
                            Button("打开终端") { session.connect(username: username) }
                                .buttonStyle(HeadplaneButtonStyle(primary: true))
                                .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }.padding(24)
                    }
                }
            }
            .background(HeadplaneStyle.background)
            .navigationTitle("SSH · \(hostname)").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { if session.opened { closing = true } else { dismiss() } } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("关闭 SSH 终端")
                }
                if session.opened {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("登录") { session.signIn() }.accessibilityLabel("使用 OIDC 登录 Headplane")
                        Button { session.returnToTerminal() } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("重新连接 SSH 终端")
                    }
                }
            }
            .confirmationDialog("关闭终端并断开连接？", isPresented: $closing, titleVisibility: .visible) {
                Button("断开并关闭", role: .destructive) { dismiss() }
                Button("取消", role: .cancel) {}
            }
        }
        .tint(HeadplaneStyle.text)
        .sheet(isPresented: Binding(get: { session.webLoginPayload != nil }, set: { if !$0 { session.webLoginPayload = nil } })) {
            ConsoleWebLoginView(initialPayload: session.webLoginPayload)
        }
        .onDisappear { session.shutdown() }
    }
}
