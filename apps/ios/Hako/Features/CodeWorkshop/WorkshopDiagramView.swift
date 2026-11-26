import SwiftUI
import UIKit
import WebKit

struct WorkshopDiagramView: View {
    let source: String
    @State private var showingSource = false
    @State private var expanded = false
    @State private var height = 240.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 22) {
                ForEach([false, true], id: \.self) { isSource in
                    Button { showingSource = isSource } label: {
                        Text(isSource ? "源码" : "图表").font(.caption.weight(showingSource == isSource ? .semibold : .regular))
                            .foregroundStyle(showingSource == isSource ? Color.primary : .secondary)
                            .frame(minHeight: 44)
                            .overlay(alignment: .bottom) { Capsule().fill(showingSource == isSource ? Color.primary : .clear).frame(height: 2) }
                    }.buttonStyle(.plain).accessibilityAddTraits(showingSource == isSource ? .isSelected : [])
                }
                Spacer(minLength: 0)
                Button { UIPasteboard.general.string = source } label: { Image(systemName: "doc.on.doc").frame(minWidth: 32, minHeight: 44) }
                    .buttonStyle(.plain).accessibilityLabel("复制 Mermaid 源码")
                Button { expanded = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(minWidth: 32, minHeight: 44) }
                    .buttonStyle(.plain).accessibilityLabel("放大查看图表")
            }.padding(.horizontal, 12)
            Divider()
            if showingSource {
                ScrollView([.horizontal, .vertical]) {
                    Text(verbatim: source).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true).padding(12)
                }.frame(height: min(360, max(160, Double(source.components(separatedBy: "\n").count) * 18 + 24)))
            } else {
                WorkshopDiagramCanvas(source: source, height: $height).frame(height: min(420, max(160, height)))
                HStack {
                    Text("滑动查看完整图表").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("放大查看") { expanded = true }.font(.caption).buttonStyle(.plain)
                }.padding(12)
            }
        }
        .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(HakoStyle.line, lineWidth: 1).allowsHitTesting(false) }
        .sheet(isPresented: $expanded) { WorkshopDiagramExpanded(source: source) }
    }
}

private struct WorkshopDiagramExpanded: View {
    let source: String
    @State private var height = 240.0
    @State private var zoom = 1.0
    var body: some View {
        SettingsSheet(title: "图表") {
            VStack(spacing: 0) {
                HStack(spacing: 24) {
                    Button { zoom = max(0.5, zoom / 1.25) } label: { Image(systemName: "minus.magnifyingglass").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("缩小图表")
                    Button("适应宽度") { zoom = 1 }.frame(minHeight: 44)
                    Button { zoom = min(5, zoom * 1.25) } label: { Image(systemName: "plus.magnifyingglass").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("放大图表")
                }.buttonStyle(.plain).font(.subheadline)
                Divider()
                WorkshopDiagramCanvas(source: source, height: $height, zoom: zoom, fit: true)
            }.background(HakoStyle.background)
        }
    }
}

private struct WorkshopDiagramCanvas: UIViewRepresentable {
    let source: String
    @Binding var height: Double
    var zoom = 1.0
    var fit = false
    @Environment(\.colorScheme) private var colorScheme
    private static let library: String? = Bundle.main.url(forResource: "mermaid-10.9.3.min", withExtension: "js")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "diagram")
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.accessibilityLabel = "Mermaid 图表，可滑动及缩放"
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.height = $height
        coordinator.zoom = zoom; coordinator.fit = fit
        let dark = colorScheme == .dark
        if coordinator.source != source || coordinator.dark != dark {
            coordinator.source = source; coordinator.dark = dark
            coordinator.ready = false
            let html: String
            if let library = Self.library {
                html = WorkshopDiagramDocument.build(source: source, library: library, dark: dark, nonce: UUID().uuidString)
            } else { html = "<p>图表资源缺失，请切换源码。</p>" }
            view.loadHTMLString(html, baseURL: nil)
        } else if coordinator.ready { coordinator.applyZoom(view) }
    }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil
        view.configuration.userContentController.removeScriptMessageHandler(forName: "diagram")
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var height: Binding<Double>
        var source: String?
        var dark: Bool?
        var zoom = 1.0
        var fit = false
        var ready = false
        init(height: Binding<Double>) { self.height = height }
        func applyZoom(_ view: WKWebView) {
            view.evaluateJavaScript("window.diagramZoom(\(zoom), \(fit ? "true" : "false"))", in: nil, in: .page) { _ in }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let data = message.body as? [String: Any] else { return }
            if let value = data["height"] as? Double, value.isFinite {
                let next = min(420, max(160, value))
                if abs(height.wrappedValue - next) > 1 { height.wrappedValue = next }
            }
            if data["ready"] as? Bool == true, let view = message.webView { ready = true; applyZoom(view) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.navigationType == .other && action.targetFrame?.isMainFrame == true && action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}
