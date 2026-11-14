import SwiftUI
import UIKit
import WebKit

struct AssistantReplyView: View {
    let html: AssistantHTML
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var fontSize = 14.0

    var body: some View {
        let page = document
        AssistantHTMLLayout(document: page).id(page)
    }

    private var document: String {
        let dark = colorScheme == .dark
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        func css(_ color: Color) -> String {
            let color = UIColor(color).resolvedColor(with: traits)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: nil)
            return String(format: "#%02x%02x%02x", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
        }
        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <style>
        :root {
            color-scheme: \(dark ? "dark" : "light"); font-size: \(fontSize)px; -webkit-text-size-adjust: 100%;
            --ink: \(css(HakoStyle.text)); --muted: \(css(HakoStyle.muted));
            --card: \(css(HakoStyle.card)); --surface: \(css(HakoStyle.background)); --line: \(css(HakoStyle.line));
            --code-background: \(css(HakoStyle.adaptive(0xf6f6f8, 0x2b2b2f)));
            --title-size: calc(17rem / 14); --label-size: calc(12rem / 14);
            --code-size: calc(13rem / 14); --title-code-size: calc(16rem / 14);
            --item-gap: calc(16rem / 14); --title-gap: calc(8rem / 14); --field-gap: calc(4rem / 14);
        }
        * { box-sizing: border-box; }
        body { margin: 0; color: var(--ink); background: transparent; font: 1rem/1.5 -apple-system, sans-serif; overflow-wrap: anywhere; }
        main { display: flow-root; }
        main > :first-child, section > :first-child { margin-top: 0; }
        main > :last-child, section > :last-child { margin-bottom: 0; }
        p, ul, ol, dl, table, blockquote, pre, hr { margin: 0 0 var(--title-gap); }
        h2, h3, h4 { margin: var(--item-gap) 0 var(--title-gap); font-size: var(--title-size); line-height: 1.4; font-weight: 600; }
        section { margin: 0 0 var(--item-gap); padding: calc(16rem / 14) 1rem; border-radius: calc(16rem / 14); background: var(--card); }
        section > h2 + p > strong:only-child { font-size: calc(24rem / 14); font-weight: 650; font-variant-numeric: tabular-nums; }
        small, caption { color: var(--muted); font-size: var(--label-size); }
        ul, ol { padding-inline-start: 1.3em; }
        li + li { margin-top: var(--title-gap); }
        li:has(> p, > h3) + li { margin-top: var(--item-gap); padding-top: var(--item-gap); border-top: 1px solid var(--line); }
        li > p:first-child > strong:only-child { font-size: var(--title-size); line-height: 1.4; font-weight: 600; }
        li > ul, li > ol { margin: .25rem 0; }
        dl { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.4fr); gap: var(--field-gap) var(--title-gap); font-size: 1rem; }
        dt { color: var(--muted); font-size: var(--label-size); }
        dd { margin: 0; text-align: end; font-variant-numeric: tabular-nums; }
        table { width: 100%; table-layout: fixed; border-collapse: collapse; font-size: 1rem; font-variant-numeric: tabular-nums; }
        caption { text-align: start; margin-bottom: .28rem; }
        th, td { padding: .38rem .28rem; text-align: start; border-bottom: 1px solid var(--line); vertical-align: top; }
        th { font-weight: 600; }
        hr { border: 0; border-top: 1px solid var(--line); }
        blockquote { padding-inline-start: .6rem; border-inline-start: 2px solid var(--line); color: var(--muted); }
        code, pre { font-family: ui-monospace, monospace; background: var(--code-background); border-radius: calc(4rem / 14); }
        code { font-size: var(--code-size); padding: calc(1rem / 14) calc(3rem / 14); }
        :is(h2, h3, h4) code, li > p:first-child > strong:only-child code { font-size: var(--title-code-size); }
        pre { padding: var(--title-gap); font-size: 1rem; white-space: pre-wrap; }
        pre code { padding: 0; font-size: inherit; background: transparent; }
        \(AssistantTableLayout.style)
        </style></head><body><main>\(html.fragment)</main></body></html>
        """
    }
}

private struct AssistantHTMLLayout: View {
    let document: String
    @State private var width: CGFloat = 0
    @State private var height: CGFloat = 1
    @State private var failed = false

    var body: some View {
        if failed {
            Text("这条回复暂时无法显示。")
                .foregroundStyle(.secondary)
        } else {
            let layoutWidth = width
            ZStack(alignment: .topLeading) {
                Color.clear
                if layoutWidth > 0 {
                    AssistantHTMLWebView(document: document, onHeight: { value in
                        if width == layoutWidth { height = value }
                    }, onFailure: {
                        if width == layoutWidth { failed = true }
                    })
                    .id(layoutWidth)
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { value in
                guard value > 0, abs(value - width) > 0.5 else { return }
                width = value
                height = 1
            }
        }
    }
}

private struct AssistantHTMLWebView: UIViewRepresentable {
    let document: String
    let onHeight: (CGFloat) -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onHeight: onHeight, onFailure: onFailure) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsLinkPreview = false
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.observeHeight(of: view)
        view.loadHTMLString(document, baseURL: nil)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        view.navigationDelegate = nil
        view.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onHeight: (CGFloat) -> Void
        private let onFailure: () -> Void
        private var observation: NSKeyValueObservation?
        private var ready = false
        private var active = true

        init(onHeight: @escaping (CGFloat) -> Void, onFailure: @escaping () -> Void) {
            self.onHeight = onHeight
            self.onFailure = onFailure
        }

        func observeHeight(of view: WKWebView) {
            observation = view.scrollView.observe(\.contentSize, options: [.new]) { [weak self, weak view] _, _ in
                Task { @MainActor in
                    if let view { self?.reportHeight(of: view) }
                }
            }
        }

        func stop() {
            active = false
            ready = false
            observation?.invalidate()
        }

        private func reportHeight(of view: WKWebView) {
            let height = view.scrollView.contentSize.height
            if ready, view.bounds.width > 0, height.isFinite, height > 0 { onHeight(ceil(height)) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url
            let isInlineDocument = action.navigationType == .other && action.targetFrame?.isMainFrame == true
                && (url == nil || url?.absoluteString == "about:blank")
            decisionHandler(isInlineDocument ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript(AssistantTableLayout.script, in: nil, in: .defaultClient) { [weak self, weak webView] result in
                guard let self, self.active, let webView else { return }
                switch result {
                case .success:
                    self.ready = true
                    self.reportHeight(of: webView)
                case .failure: self.onFailure()
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFailure() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFailure() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onFailure() }
    }
}
