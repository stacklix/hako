import Foundation

enum WorkshopMarkdownDocument {
    static func supports(_ path: String) -> Bool {
        ["md", "markdown"].contains((path as NSString).pathExtension.lowercased())
    }

    static func build(_ source: String) -> String {
        let content = WorkshopMessage.parts(source).map { part -> String in
            switch part {
            case .text(let text): return AssistantMarkdown.render(text)
            case .code(let code, _): return "<pre><code>" + escape(code) + "</code></pre>"
            case .image(let alt, _): return "<p class=\"image-note\">" + escape(alt.isEmpty ? "图片" : "图片：" + alt) + "</p>"
            case .table(let table):
                func row(_ cells: [String], header: Bool) -> String {
                    let tag = header ? "th" : "td"
                    let values = cells.enumerated().map { index, cell in
                        let alignment: String
                        switch table.alignments[index] {
                        case .leading: alignment = "left"
                        case .center: alignment = "center"
                        case .trailing: alignment = "right"
                        }
                        return "<\(tag) style=\"text-align:\(alignment)\">" + AssistantMarkdown.inline(cell) + "</\(tag)>"
                    }.joined()
                    return "<tr>" + values + "</tr>"
                }
                return "<div class=\"table-scroll\"><table><thead>" + row(table.headers, header: true)
                    + "</thead><tbody>" + table.rows.map { row($0, header: false) }.joined() + "</tbody></table></div>"
            }
        }.joined(separator: "\n")
        return """
        <!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <style>
        :root { color-scheme: light dark; font: -apple-system-body; -webkit-text-size-adjust: 100%; }
        * { box-sizing: border-box; }
        body { margin: 0; padding: 16px 16px 32px; color: light-dark(#202124,#f2f2f4); background: light-dark(#fff,#000); line-height: 1.6; overflow-wrap: anywhere; }
        main > :first-child { margin-top: 0; }
        p, ul, ol, blockquote, pre, .table-scroll { margin: 0 0 16px; }
        h2, h3, h4 { margin: 24px 0 12px; line-height: 1.35; }
        h2 { font-size: 1.5em; } h3 { font-size: 1.25em; } h4 { font-size: 1.1em; }
        ul, ol { padding-inline-start: 1.5em; } li > p { margin-bottom: 4px; }
        blockquote { margin-inline: 0; padding-inline-start: 12px; border-inline-start: 3px solid light-dark(#ddd,#444); color: light-dark(#666,#aaa); }
        code, pre { font-family: ui-monospace, monospace; font-size: .9em; background: light-dark(#f3f3f5,#262629); border-radius: 6px; }
        code { padding: 2px 4px; } pre { padding: 12px; white-space: pre; overflow-x: auto; } pre code { padding: 0; font-size: inherit; background: transparent; }
        .table-scroll { overflow-x: auto; } table { width: 100%; border-collapse: collapse; font-size: .9em; }
        th, td { padding: 8px 10px; border: 1px solid light-dark(#ddd,#444); min-width: 80px; }
        th { background: light-dark(#f3f3f5,#262629); } hr { border: 0; border-top: 1px solid light-dark(#ddd,#444); margin: 20px 0; }
        .image-note { color: light-dark(#666,#aaa); }
        </style></head><body><main>\(content)</main></body></html>
        """
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

#if canImport(UIKit)
import SwiftUI
import WebKit

struct WorkshopMarkdownPreview: View {
    let source: String
    @State private var document = ""

    var body: some View {
        ZStack {
            WorkshopMarkdownWebView(document: document)
            if document.isEmpty { ProgressView("正在生成预览…") }
        }
        .background(Color(uiColor: .systemBackground))
        .task(id: source) {
            let source = source
            let rendered = await Task.detached(priority: .userInitiated) { WorkshopMarkdownDocument.build(source) }.value
            guard !Task.isCancelled else { return }
            document = rendered
        }
    }
}

private struct WorkshopMarkdownWebView: UIViewRepresentable {
    let document: String

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .systemBackground
        view.accessibilityLabel = "Markdown 预览"
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        guard !document.isEmpty, context.coordinator.document != document else { return }
        context.coordinator.document = document
        context.coordinator.offset = view.scrollView.contentOffset
        context.coordinator.navigation = view.loadHTMLString(document, baseURL: nil)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        var document = ""
        var offset = CGPoint.zero
        var navigation: WKNavigation?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let inlineDocument = action.navigationType == .other && action.targetFrame?.isMainFrame == true
                && action.request.url?.absoluteString == "about:blank"
            decisionHandler(inlineDocument ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === self.navigation else { return }
            let scroll = webView.scrollView
            let maximum = max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: min(max(0, offset.y), maximum)), animated: false)
        }
    }
}
#endif
