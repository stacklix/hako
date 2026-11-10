import SwiftUI
import UIKit
import WebKit

struct InvestmentAgentReplyView: View {
    let html: InvestmentAgentHTML
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var fontSize = 17.0

    var body: some View {
        let page = document
        InvestmentAgentHTMLLayout(document: page).id(page)
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
        }
        * { box-sizing: border-box; }
        body { margin: 0; color: var(--ink); background: transparent; font: 1rem/1.42 -apple-system, sans-serif; overflow-wrap: anywhere; }
        main { display: flow-root; }
        main > :first-child, section > :first-child { margin-top: 0; }
        main > :last-child, section > :last-child { margin-bottom: 0; }
        p, ul, ol, dl, table, blockquote, pre, hr { margin: 0 0 .65rem; }
        h2, h3, h4 { margin: .7rem 0 .3rem; font-size: 1rem; font-weight: 600; }
        section { margin: 0 0 .6rem; padding: 14px; border-radius: 14px; background: var(--card); }
        section > h2:first-child { font-size: .84rem; font-weight: 600; }
        section > h2 + p { margin-bottom: .35rem; }
        section > h2 + p > strong:only-child { font-size: 1.4rem; font-weight: 650; font-variant-numeric: tabular-nums; }
        small, caption { color: var(--muted); font-size: .78rem; }
        ul, ol { padding-inline-start: 1.3em; }
        li + li { margin-top: .2rem; }
        li > ul, li > ol { margin: .25rem 0; }
        dl { display: grid; grid-template-columns: minmax(0, 1fr) minmax(0, 1.4fr); gap: .4rem .6rem; font-size: .88rem; }
        dt { color: var(--muted); }
        dd { margin: 0; text-align: end; font-variant-numeric: tabular-nums; }
        table { width: 100%; table-layout: fixed; border-collapse: collapse; font-size: .84rem; font-variant-numeric: tabular-nums; }
        caption { text-align: start; margin-bottom: .28rem; }
        th, td { padding: .38rem .28rem; text-align: start; border-bottom: 1px solid var(--line); vertical-align: top; }
        th { font-weight: 600; }
        hr { border: 0; border-top: 1px solid var(--line); }
        blockquote { padding-inline-start: .6rem; border-inline-start: 2px solid var(--line); color: var(--muted); }
        code, pre { font-family: ui-monospace, monospace; font-size: .86rem; background: var(--surface); border-radius: 5px; }
        code { padding: .1em .24em; }
        pre { padding: .45rem; white-space: pre-wrap; }
        </style></head><body><main>\(html.fragment)</main></body></html>
        """
    }
}

private struct InvestmentAgentHTMLLayout: View {
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
                    InvestmentAgentHTMLWebView(document: document, onHeight: { value in
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

private struct InvestmentAgentHTMLWebView: UIViewRepresentable {
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
            ready = true
            reportHeight(of: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { onFailure() }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { onFailure() }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { onFailure() }
    }
}
