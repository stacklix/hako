import SwiftUI
import UIKit
import Photos

struct WorkshopMessageView: View {
    let text: String
    let store: WorkshopStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(WorkshopMessage.parts(text).enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let prose):
                    WorkshopInlineProse(source: prose.trimmingCharacters(in: .newlines))
                case .code(let code, let language):
                    WorkshopCodeSnippet(code: code, language: language)
                case .image(let alt, let url):
                    WorkshopRemoteImage(alt: alt, url: url, store: store)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(WorkshopMessageCopy(text: text))
    }
}

private struct WorkshopMessageCopy: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            // Give the whole-message double tap precedence over inline links
            // and the system's word-selection gesture. Single taps still pass through.
            .highPriorityGesture(TapGesture(count: 2).onEnded { copy() })
            .accessibilityAction(named: Text("复制整条消息")) { copy() }
    }

    private func copy() {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        UIAccessibility.post(notification: .announcement, argument: "已复制整条消息")
    }
}

private struct WorkshopInlineProse: View {
    let source: String

    var body: some View {
        let rendered = render()
        rendered.text
            .font(.subheadline).lineSpacing(5).textSelection(.enabled)
            .textRenderer(WorkshopInlineCodeRenderer())
            .accessibilityHint(rendered.copies.isEmpty ? "双击复制整条消息，长按可选择文本" : "轻点行内代码复制该段，双击复制整条消息，长按可选择文本")
            .environment(\.openURL, OpenURLAction { url in
                guard let code = rendered.copies[url] else { return .systemAction }
                UIPasteboard.general.string = code
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                UIAccessibility.post(notification: .announcement, argument: "已复制")
                return .handled
            })
    }

    private func render() -> (text: Text, copies: [URL: String]) {
        var text = (try? AttributedString(markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
        var copies: [URL: String] = [:]
        // Keep one Text layout so code wraps naturally with the surrounding prose.
        let spans = text.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
            .map { (range: $0.range, value: String(text[$0.range].characters)) }
        for (index, span) in spans.enumerated() {
            guard let url = URL(string: "hako-inline-copy://snippet/\(index)") else { continue }
            copies[url] = span.value
            text[span.range].font = .system(.subheadline, design: .monospaced)
            text[span.range].foregroundColor = HakoStyle.text
            text[span.range].link = url
        }
        let rendered = text.runs.reduce(Text("")) { result, run in
            var fragment = Text(AttributedString(text[run.range]))
            if let link = run.link, copies[link] != nil {
                fragment = fragment.customAttribute(WorkshopInlineCodeAttribute(id: link))
            }
            return Text("\(result)\(fragment)")
        }
        return (rendered, copies)
    }
}

private struct WorkshopInlineCodeAttribute: TextAttribute {
    let id: URL
}

private struct WorkshopInlineCodeRenderer: TextRenderer {
    var displayPadding: EdgeInsets { EdgeInsets(top: 2, leading: 3, bottom: 2, trailing: 3) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // Merge fragments of the same code span on each line, including font
        // fallback runs. Wrapped spans receive a separate rounded background.
        for line in layout {
            var backgrounds: [(id: URL, rect: CGRect)] = []
            for run in line {
                guard let code = run[WorkshopInlineCodeAttribute.self] else { continue }
                let rect = run.typographicBounds.rect
                if let last = backgrounds.indices.last, backgrounds[last].id == code.id {
                    backgrounds[last].rect = backgrounds[last].rect.union(rect)
                } else {
                    backgrounds.append((code.id, rect))
                }
            }
            for background in backgrounds {
                let rect = background.rect.insetBy(dx: -3, dy: -1.5)
                let path = RoundedRectangle(cornerRadius: 4, style: .continuous).path(in: rect)
                context.fill(path, with: .color(HakoStyle.line.opacity(0.55)))
            }
            context.draw(line)
        }
    }
}

private struct WorkshopCodeSnippet: View {
    let code: String
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(language ?? "代码").font(.caption).foregroundStyle(HakoStyle.muted)
                Spacer()
                Button(action: copy) {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.medium)).frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "已复制代码" : "复制完整代码")
                .disabled(code.isEmpty)
            }
            ScrollView(.horizontal) {
                Text(verbatim: code).font(.system(.subheadline, design: .monospaced))
                    .textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
                    .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 4)
        .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(HakoStyle.line, lineWidth: 1).allowsHitTesting(false) }
        .contextMenu { Button("复制代码", systemImage: "doc.on.doc", action: copy).disabled(code.isEmpty) }
        .onChange(of: code) { copied = false }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }

    private func copy() {
        UIPasteboard.general.string = code
        copied = true
    }
}

struct WorkshopUserMessage: View {
    let entry: WorkshopEntry
    let threadId: String?
    let store: WorkshopStore
    let agent: WorkshopAgent
    @State private var photos: [WorkshopPhoto] = []
    @State private var selected: WorkshopPhoto?
    @State private var failure: String?
    @State private var loading = false
    @State private var photoLoad = UUID()
    @State private var photoRetry = 0

    var body: some View {
        let caption = WorkshopImageCaption(entry.text)
        VStack(alignment: .leading, spacing: 10) {
            if !caption.text.isEmpty {
                Text(caption.text).font(.subheadline).textSelection(.enabled)
                    .modifier(WorkshopMessageCopy(text: caption.text))
                    .accessibilityHint("双击复制整条消息，长按可选择文本")
            }
            ForEach(photos) { photo in
                if let image = UIImage(data: photo.data) {
                    Button { selected = photo } label: {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxWidth: entry.role == "assistant" ? .infinity : 220, maxHeight: entry.role == "assistant" ? 440 : 180)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityLabel("查看图片")
                }
            }
            if loading { ProgressView("正在加载图片…").font(.caption) }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
                Button("重新加载图片") { photoRetry += 1 }.font(.caption).disabled(loading)
            }
        }
        .task(id: "\(threadId ?? ""):\(entry.id):\(caption.count):\(photoRetry)") { await loadPhotos() }
        .sheet(item: $selected) { photo in WorkshopPhotoPreview(photo: photo) }
    }

    @MainActor private func loadPhotos() async {
        let count = WorkshopImageCaption(entry.text).count
        guard count > 0, !Task.isCancelled else { return }
        // SwiftUI can start the replacement task before a cancelled image read
        // unwinds. Let the new task take ownership instead of skipping it.
        let load = UUID()
        photoLoad = load
        loading = true; failure = nil
        defer { if photoLoad == load { loading = false } }
        if photos.isEmpty { photos = store.messagePhotos(entry.id) }
        do {
            guard photos.count < count else { return }
            guard let threadId else { return }
            for index in photos.count..<count {
                let data = try await store.messageImage(threadId: threadId, messageId: entry.id, index: index, agent: agent)
                try Task.checkCancellation()
                guard photoLoad == load else { return }
                guard UIImage(data: data) != nil else { throw HakoError(message: "图片格式无法显示。") }
                photos.append(WorkshopPhoto(id: "\(entry.id)-\(index)", data: data))
            }
        } catch is CancellationError { }
        catch {
            if photoLoad == load, !Task.isCancelled { failure = "图片暂时无法加载：\(error.localizedDescription)" }
        }
    }
}

struct WorkshopPhotoPreview: View {
    let photo: WorkshopPhoto
    @Environment(\.openURL) private var openURL
    @State private var saving = false
    @State private var saved = false
    @State private var showsSaveError = false
    @State private var saveError = ""
    @State private var canOpenSettings = false

    var body: some View {
        SettingsSheet(title: "图片", isBusy: saving) {
            if let image = UIImage(data: photo.data) {
                WorkshopImageZoom(image: image)
                    .safeAreaInset(edge: .bottom) {
                        Button {
                            Task { await saveToPhotos() }
                        } label: {
                            HStack(spacing: 8) {
                                if saving { ProgressView() }
                                Label(saving ? "正在保存…" : saved ? "已保存到相册" : "保存到相册",
                                      systemImage: saved ? "checkmark" : "square.and.arrow.down")
                            }
                        }
                        .buttonStyle(HakoActionButtonStyle())
                        .disabled(saving || saved)
                        .padding()
                        .background(.bar)
                    }
            }
        }
        .alert("无法保存图片", isPresented: $showsSaveError) {
            if canOpenSettings {
                Button("打开设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
            Button("好", role: .cancel) { }
        } message: { Text(saveError) }
    }

    @MainActor private func saveToPhotos() async {
        guard !saving, !saved else { return }
        saving = true
        canOpenSettings = false
        defer { saving = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized else {
            canOpenSettings = status == .denied
            saveError = canOpenSettings
                ? "请在系统设置中允许 Hako 添加照片，然后重新保存。"
                : "系统未允许添加照片，请检查设备的相册权限或访问限制。"
            showsSaveError = true
            return
        }
        do {
            let data = photo.data
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            saved = true
            UIAccessibility.post(notification: .announcement, argument: "已保存到相册")
        } catch {
            saveError = "保存未完成：\(error.localizedDescription) 请先检查相册再重试。"
            showsSaveError = true
        }
    }
}

private struct WorkshopImageZoom: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = WorkshopZoomScrollView()
        scroll.minimumZoomScale = 1; scroll.maximumZoomScale = 5
        scroll.delegate = context.coordinator
        let picture = context.coordinator.picture
        scroll.picture = picture
        picture.contentMode = .scaleAspectFit; picture.image = image
        scroll.addSubview(picture)
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) {
        let picture = context.coordinator.picture
        picture.image = image
        scroll.setNeedsLayout()
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let picture = UIImageView()
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            picture.center = CGPoint(x: max(scrollView.bounds.width, scrollView.contentSize.width) / 2,
                y: max(scrollView.bounds.height, scrollView.contentSize.height) / 2)
        }
    }
}

private final class WorkshopZoomScrollView: UIScrollView {
    weak var picture: UIImageView?
    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1, picture?.frame != bounds {
            picture?.frame = bounds
            contentSize = bounds.size
        }
    }
}

private struct WorkshopRemoteImage: View {
    let alt: String
    let url: URL
    let store: WorkshopStore
    @State private var photo: WorkshopPhoto?
    @State private var selected: WorkshopPhoto?
    @State private var failure: String?
    @State private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let photo, let image = UIImage(data: photo.data) {
                Button { selected = photo } label: {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 440)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).accessibilityLabel(alt.isEmpty ? "查看图片" : "查看图片：" + alt)
            } else {
                VStack(spacing: 12) {
                    if let failure {
                        Text(failure).font(.caption).foregroundStyle(.secondary)
                        Button("重新加载图片") { retry += 1 }.buttonStyle(HakoActionButtonStyle(primary: false))
                        Link("打开原图", destination: url).font(.caption)
                    } else { ProgressView("正在加载图片…").font(.caption) }
                }.padding(20).frame(maxWidth: .infinity, minHeight: 180)
                    .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 12))
            }
        }.task(id: "\(url.absoluteString):\(retry)") { await load() }
            .sheet(item: $selected) { photo in WorkshopPhotoPreview(photo: photo) }
    }

    @MainActor private func load() async {
        guard photo == nil else { return }
        failure = nil
        if let data = store.cachedRemoteImage(url), UIImage(data: data) != nil {
            photo = WorkshopPhoto(id: url.absoluteString, data: data)
            return
        }
        let scope = store.scope
        do {
            let request = URLRequest(url: url, timeoutInterval: 30)
            let (data, response) = try await HTTPTransport.data(for: request, source: .codeWorkshop, logBody: false)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  !data.isEmpty, data.count <= 8 * 1024 * 1024, UIImage(data: data) != nil else {
                throw HakoError(message: "图片无法读取，或超过 8 MB。")
            }
            guard scope == store.scope else { throw CancellationError() }
            // A full disk must not hide an image that was downloaded successfully.
            try? store.cacheRemoteImage(data, from: url)
            photo = WorkshopPhoto(id: url.absoluteString, data: data)
        } catch is CancellationError { }
        catch { if !Task.isCancelled { failure = "图片暂时无法加载，请重试或打开原图。" } }
    }
}
