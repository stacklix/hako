import SwiftUI
import WebKit

struct WorkshopPreviewView: View {
    let store: WorkshopStore
    let agent: WorkshopAgent
    let artifact: WorkshopArtifact
    @Environment(\.colorScheme) private var colorScheme
    @State private var html: String?
    @State private var error: String?

    var body: some View {
        SettingsSheet(title: artifact.name) {
            Group {
                if let html {
                    WorkshopWebPreview(html: html, dark: colorScheme == .dark)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(error ?? "正在从电脑读取原型…").font(.subheadline).textSelection(.enabled)
                        if error != nil {
                            Button("重新读取") { Task { await load() } }.buttonStyle(HakoActionButtonStyle())
                        }
                        Text(artifact.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .background(HakoStyle.background)
            .task { await load() }
        }
    }

    private func load() async {
        error = nil
        do { html = try await store.artifact(artifact, agent: agent) }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}

private struct WorkshopWebPreview: UIViewRepresentable {
    let html: String
    let dark: Bool

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(WKUserScript(source: """
            window.openai = { widgetState: null, setWidgetState: function(value) {
                this.widgetState = value; return Promise.resolve();
            }};
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let document = WorkshopPreviewDocument.build(html: html, dark: dark)
        guard context.coordinator.document != document else { return }
        context.coordinator.document = document
        view.loadHTMLString(document, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) { view.stopLoading(); view.navigationDelegate = nil }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var document = ""
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let scheme = navigationAction.request.url?.scheme
            decisionHandler(scheme == "about" || scheme == "data" ? .allow : .cancel)
        }
    }
}

enum WorkshopPreviewDocument {
    static func build(html: String, dark: Bool) -> String {
        let theme = dark ? "dark" : "light"
        let head = """
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' https://unpkg.com https://cdn.jsdelivr.net https://esm.sh https://cdnjs.cloudflare.com https://persistent.oaistatic.com/plugins/visualize/; style-src 'unsafe-inline' https://fonts.googleapis.com https://cdn.jsdelivr.net https://unpkg.com; font-src https://fonts.gstatic.com https://cdn.jsdelivr.net data:; img-src data: blob: https://cdn.jsdelivr.net https://unpkg.com https://persistent.oaistatic.com; connect-src 'none'; frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'">
        <style>
        :root{color-scheme:\(theme);--font-size-base:14px;--background:light-dark(#fff,#151517);--foreground:light-dark(#202124,#f2f2f4);--card:light-dark(#fff,#242427);--card-foreground:var(--foreground);--muted:light-dark(#f5f5f7,#28282b);--muted-foreground:light-dark(#76777d,#aaaab0);--border:light-dark(#e9e9ee,#38383c);--primary:var(--foreground);--primary-foreground:var(--background)}
        body{margin:0;font:14px -apple-system,BlinkMacSystemFont,sans-serif;background:var(--background);color:var(--foreground);overflow-wrap:anywhere}*{box-sizing:border-box}button,input,select,textarea{font:inherit}button{cursor:pointer}[hidden]{display:none!important}.card{padding:16px;border:1px solid var(--border);border-radius:12px;background:var(--card)}.btn{padding:9px 14px;min-height:44px;border:1px solid var(--border);border-radius:9px;background:var(--muted);color:var(--foreground)}.btn-primary{background:var(--primary);color:var(--primary-foreground)}.text-muted{color:var(--muted-foreground)}.text-small{font-size:12px}.viz-row,.viz-controls{display:flex;flex-wrap:wrap;align-items:center;gap:12px}.viz-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,180px),1fr));gap:12px}.form-control,.form-select{width:100%;min-height:44px;padding:9px;border:1px solid var(--border);border-radius:8px;background:var(--background);color:var(--foreground)}.form-label{display:block;margin-bottom:6px}.sr-only{position:absolute;width:1px;height:1px;overflow:hidden;clip:rect(0,0,0,0)}
        </style>
        <script async src="https://unpkg.com/lucide@1.17.0/dist/umd/lucide.js" onload="lucide.createIcons({attrs:{width:16,height:16}})"></script>
        """
        if html.range(of: "<html", options: .caseInsensitive) != nil {
            var result = html
            if let range = result.range(of: "<head[^>]*>", options: [.regularExpression, .caseInsensitive]) {
                result.insert(contentsOf: head, at: range.upperBound)
                return result
            }
            return head + result
        }
        return "<!doctype html><html lang=\"zh-CN\"><head>" + head + "</head><body>" + html + "</body></html>"
    }
}
