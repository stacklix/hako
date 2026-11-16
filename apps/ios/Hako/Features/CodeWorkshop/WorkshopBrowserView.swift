import SwiftUI
import UIKit
import WebKit

struct WorkshopBrowserView: View {
    @StateObject private var session: WorkshopBrowserSession

    init(link: WorkshopBrowserLink) {
        _session = StateObject(wrappedValue: WorkshopBrowserSession(url: link.url))
    }

    var body: some View {
        SettingsSheet(title: session.title.isEmpty ? "内置浏览器" : session.title) {
            ZStack {
                WorkshopBrowserWebView(session: session)
                if let error = session.error {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("网页加载失败", systemImage: "wifi.exclamationmark").font(.headline)
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                        Button("重新加载") { session.reload() }.buttonStyle(HakoActionButtonStyle())
                    }
                    .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(HakoStyle.background)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: session.url.scheme?.lowercased() == "https" ? "lock" : "globe")
                        Text(session.url.absoluteString).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    ProgressView(value: session.progress).progressViewStyle(.linear)
                        .frame(height: 2).opacity(session.loading ? 1 : 0)
                        .accessibilityLabel("网页加载进度")
                }
                .background(HakoStyle.background)
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { session.goBack() } label: { Image(systemName: "chevron.left") }
                        .disabled(!session.canGoBack).accessibilityLabel("返回上一页")
                    Spacer()
                    Button { session.goForward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!session.canGoForward).accessibilityLabel("前往下一页")
                    Spacer()
                    Button {
                        if session.loading { session.stopLoading() }
                        else { session.reload() }
                    } label: { Image(systemName: session.loading ? "xmark" : "arrow.clockwise") }
                        .accessibilityLabel(session.loading ? "停止加载网页" : "重新加载网页")
                    Spacer()
                    Button {
                        UIPasteboard.general.string = session.url.absoluteString
                        UIAccessibility.post(notification: .announcement, argument: "已复制网页链接")
                    } label: { Image(systemName: "link") }
                        .accessibilityLabel("复制网页链接")
                }
            }
        }
    }
}

@MainActor private final class WorkshopBrowserSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    private let initialURL: URL
    private var started = false
    private var observations: [NSKeyValueObservation] = []
    @Published private(set) var url: URL
    @Published private(set) var title = ""
    @Published private(set) var loading = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var error: String?

    init(url: URL) {
        self.url = url
        initialURL = url
        let configuration = WKWebViewConfiguration()
        // Web content owns its cookies and credentials. Never inject the native
        // server login, a file origin, or a JavaScript/native message bridge.
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.keyboardDismissMode = .interactive
    }

    func start() {
        guard !started else { return }
        started = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.scheduleUpdate() }
        ]
        webView.load(URLRequest(url: initialURL))
    }

    nonisolated private func scheduleUpdate() {
        Task { @MainActor [weak self] in self?.updateState() }
    }

    private func updateState() {
        if let value = webView.url, WorkshopBrowserLink.allows(value), url != value { url = value }
        let pageTitle = webView.title ?? ""
        if title != pageTitle { title = pageTitle }
        if loading != webView.isLoading { loading = webView.isLoading }
        if progress != webView.estimatedProgress { progress = webView.estimatedProgress }
        if canGoBack != webView.canGoBack { canGoBack = webView.canGoBack }
        if canGoForward != webView.canGoForward { canGoForward = webView.canGoForward }
    }

    func goBack() { if webView.canGoBack { error = nil; webView.goBack() } }
    func goForward() { if webView.canGoForward { error = nil; webView.goForward() } }
    func stopLoading() { webView.stopLoading(); updateState() }
    func reload() {
        error = nil
        if webView.url != nil { webView.reload() }
        else { webView.load(URLRequest(url: initialURL)) }
    }

    func close() {
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url, WorkshopBrowserLink.allows(target) else {
            decisionHandler(.cancel)
            return
        }
        // Links targeting a new window stay in this browser and its history.
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            webView.load(navigationAction.request)
        } else { decisionHandler(.allow) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let target = navigationAction.request.url, WorkshopBrowserLink.allows(target) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        error = nil
        updateState()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { updateState() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { updateState() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

    private func failed(_ failure: Error) {
        guard (failure as NSError).code != NSURLErrorCancelled else { return }
        error = failure.localizedDescription
        updateState()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        error = "网页进程已停止，请重新加载。"
        loading = false
    }
}

private struct WorkshopBrowserWebView: UIViewRepresentable {
    @ObservedObject var session: WorkshopBrowserSession
    func makeUIView(context: Context) -> WKWebView { session.start(); return session.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
    func makeCoordinator() -> WorkshopBrowserSession { session }
    static func dismantleUIView(_ view: WKWebView, coordinator: WorkshopBrowserSession) { coordinator.close() }
}
