import SwiftUI
import UIKit
import Photos

struct WorkshopDiffView: View {
    let text: String

    var body: some View {
        highlighted.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            .textRenderer(WorkshopDiffRenderer())
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var highlighted: Text {
        WorkshopDiff.lines(text).reduce(Text("")) { result, line in
            let fragment = Text(verbatim: line.text)
                .foregroundColor(line.kind == .metadata ? HakoStyle.muted : HakoStyle.text)
                .customAttribute(WorkshopDiffAttribute(kind: line.kind))
            return Text("\(result)\(fragment)")
        }
    }
}

private struct WorkshopDiffAttribute: TextAttribute {
    let kind: WorkshopDiff.Kind
}

private struct WorkshopDiffRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            var backgrounds: [(kind: WorkshopDiff.Kind, rect: CGRect)] = []
            for run in line {
                guard let diff = run[WorkshopDiffAttribute.self], fill(for: diff.kind) != nil else { continue }
                let rect = run.typographicBounds.rect
                if let last = backgrounds.indices.last, backgrounds[last].kind == diff.kind {
                    backgrounds[last].rect = backgrounds[last].rect.union(rect)
                } else {
                    backgrounds.append((diff.kind, rect))
                }
            }
            for background in backgrounds {
                if let color = fill(for: background.kind) {
                    context.fill(Path(background.rect), with: .color(color))
                }
            }
            context.draw(line)
        }
    }

    private func fill(for kind: WorkshopDiff.Kind) -> Color? {
        switch kind {
        case .addition: HakoStyle.adaptive(0xe3f4e8, 0x193b28)
        case .removal: HakoStyle.adaptive(0xfbe5e7, 0x48272b)
        case .hunk: HakoStyle.adaptive(0xebf2ff, 0x20344f)
        case .metadata, .context: nil
        }
    }
}

struct WorkshopMessageView: View, Equatable {
    let text: String
    let parts: [WorkshopMessagePart]
    let store: WorkshopStore

    static func == (left: Self, right: Self) -> Bool { left.text == right.text && left.parts == right.parts && left.store === right.store }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let prose):
                    WorkshopInlineProse(source: prose.trimmingCharacters(in: .newlines))
                case .code(let code, let language):
                    WorkshopCodeSnippet(code: code, language: language)
                case .image(let alt, let url):
                    WorkshopRemoteImage(alt: alt, url: url, store: store)
                case .table(let table):
                    WorkshopTableView(table: table)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(WorkshopMessageCopy(text: text))
    }
}

private struct WorkshopTableView: View {
    let table: WorkshopMarkdownTable

    var body: some View {
        ViewThatFits(in: .horizontal) {
            compactTable.fixedSize(horizontal: true, vertical: true)
            records
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var compactTable: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            compactRow(table.headers, header: true)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                compactRow(cells, header: false)
            }
        }
    }

    private func compactRow(_ cells: [String], header: Bool) -> some View {
        GridRow(alignment: .top) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                WorkshopInlineProse(source: cell.isEmpty ? "—" : cell)
                    .fontWeight(header ? .medium : .regular)
                    .foregroundStyle(header ? HakoStyle.muted : HakoStyle.text)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, header ? 6 : 8)
                    .frame(minWidth: 64, alignment: alignment(table.alignments[index]))
                    .gridColumnAlignment(horizontalAlignment(table.alignments[index]))
                    .overlay(alignment: .bottom) { Rectangle().fill(HakoStyle.line).frame(height: 0.5) }
            }
        }
    }

    private var records: some View {
        VStack(alignment: .leading, spacing: 0) {
            if table.rows.isEmpty {
                ForEach(Array(table.headers.enumerated()), id: \.offset) { _, header in
                    WorkshopInlineProse(source: header).fontWeight(.medium)
                }
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { rowIndex, cells in
                if rowIndex > 0 { Divider().padding(.vertical, 12) }
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { column, header in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(header).font(.caption).foregroundStyle(HakoStyle.muted)
                            WorkshopInlineProse(source: cells[column].isEmpty ? "—" : cells[column])
                                .fontWeight(column == 0 ? .medium : .regular)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func alignment(_ value: WorkshopMarkdownTable.Alignment) -> Alignment {
        switch value {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func horizontalAlignment(_ value: WorkshopMarkdownTable.Alignment) -> HorizontalAlignment {
        switch value {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

private struct WorkshopMessageCopy: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            // Preserve the system's text-selection gestures alongside whole-message copying.
            .simultaneousGesture(TapGesture(count: 2).onEnded { copy() })
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
    @Environment(\.openURL) private var openURL
    @State private var rendered: (text: Text, copies: [URL: String])?

    var body: some View {
        let current = rendered ?? (text: Text(verbatim: source), copies: [:])
        current.text
            .font(.subheadline).lineSpacing(5).textSelection(.enabled)
            .tint(HakoStyle.link)
            .textRenderer(WorkshopInlineCodeRenderer())
            .accessibilityHint(current.copies.isEmpty ? "双击复制整条消息，长按可选择文本" : "轻点行内代码复制该段，双击复制整条消息，长按可选择文本")
            .environment(\.openURL, OpenURLAction { url in
                guard let code = current.copies[url] else {
                    openURL(url)
                    return .handled
                }
                UIPasteboard.general.string = code
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                UIAccessibility.post(notification: .announcement, argument: "已复制")
                return .handled
            })
            .task(id: source) {
                let source = source
                let parsed = await Task.detached(priority: .userInitiated) {
                    (try? AttributedString(markdown: source,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(source)
                }.value
                guard !Task.isCancelled else { return }
                rendered = render(parsed)
            }
    }

    private func render(_ parsed: AttributedString) -> (text: Text, copies: [URL: String]) {
        var text = parsed
        var copies: [URL: String] = [:]
        // Keep one Text layout so code wraps naturally with the surrounding prose.
        let spans = text.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true && $0.link == nil }
            .map { (range: $0.range, value: String(text[$0.range].characters)) }
        for (index, span) in spans.enumerated() {
            guard let url = URL(string: "hako-inline-copy://snippet/\(index)") else { continue }
            copies[url] = span.value
            text[span.range].font = .system(.subheadline, design: .monospaced)
            text[span.range].foregroundColor = HakoStyle.text
            text[span.range].link = url
        }
        let runs = Array(text.runs)
        let rendered = runs.enumerated().reduce(Text("")) { result, item in
            let (index, run) = item
            var value = AttributedString(text[run.range])
            if let link = run.link, copies[link] == nil, !WorkshopBrowserLink.allows(link) {
                value.link = nil
            }
            var fragment = Text(value)
            if let link = run.link, copies[link] != nil {
                fragment = fragment.customAttribute(WorkshopInlineCodeAttribute(id: link))
            } else if let link = run.link, WorkshopBrowserLink.allows(link) {
                fragment = fragment.foregroundColor(HakoStyle.link).underline(true, color: HakoStyle.link)
                // A link can contain several styled runs. Add one marker at its end,
                // with the same destination so tapping the marker also opens it.
                if index + 1 == runs.count || runs[index + 1].link != link {
                    var marker = AttributedString("\u{202F}↗")
                    marker.link = link
                    marker.font = .caption2
                    marker.foregroundColor = HakoStyle.link
                    fragment = Text("\(fragment)\(Text(marker))")
                }
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
    private static let background = HakoStyle.line
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
                context.fill(path, with: .color(Self.background))
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
    var replies: [WorkshopQuestionReply] = []
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
                Group {
                    if replies.isEmpty {
                        Text(caption.text).font(.subheadline).textSelection(.enabled)
                    } else {
                        WorkshopQuestionReplyView(replies: replies)
                    }
                }
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

private struct WorkshopQuestionReplyView: View {
    let replies: [WorkshopQuestionReply]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(replies.enumerated()), id: \.offset) { index, reply in
                if index > 0 { Divider() }
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(replies.count > 1 ? "问题 \(index + 1)" : "问题", systemImage: "questionmark.bubble")
                            .font(.caption.weight(.medium))
                        Text(reply.question).font(.subheadline).textSelection(.enabled)
                    }
                    .foregroundStyle(.secondary)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(HakoStyle.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 6) {
                        Label("你的回答", systemImage: "text.bubble")
                            .font(.caption.weight(.semibold))
                        Text(reply.answer).font(.subheadline).textSelection(.enabled)
                    }.foregroundStyle(HakoStyle.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct WorkshopPhotoPreview: View {
    let photos: [WorkshopPhoto]
    @State private var selection: String
    private var photo: WorkshopPhoto { photos.first { $0.id == selection } ?? photos[0] }
    private var saved: Bool { savedIDs.contains(photo.id) }

    init(photo: WorkshopPhoto, photos: [WorkshopPhoto] = []) {
        self.photos = photos.contains(where: { $0.id == photo.id }) ? photos : [photo]
        _selection = State(initialValue: photo.id)
    }
    @Environment(\.openURL) private var openURL
    @State private var saving = false
    @State private var savedIDs = Set<String>()
    @State private var showsSaveError = false
    @State private var saveError = ""
    @State private var canOpenSettings = false

    var body: some View {
        SettingsSheet(title: photos.count > 1 ? "图片 \((photos.firstIndex { $0.id == selection } ?? 0) + 1)/\(photos.count)" : "图片", isBusy: saving) {
            TabView(selection: $selection) {
                ForEach(photos) { item in
                    Group {
                        if let image = UIImage(data: item.data) {
                            WorkshopImageZoom(image: image)
                                .accessibilityLabel("图片，可左右滑动切换、双指缩放")
                        } else {
                            ContentUnavailableView("无法预览图片", systemImage: "photo")
                        }
                    }.tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: photos.count > 1 ? .automatic : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
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
        let selectedPhoto = photo
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
            let data = selectedPhoto.data
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            savedIDs.insert(selectedPhoto.id)
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
