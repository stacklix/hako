import SwiftUI
import UIKit

struct WorkshopMessageView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(WorkshopMessage.parts(text).enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let prose):
                    Text(LocalizedStringKey(prose.trimmingCharacters(in: .newlines)))
                        .font(.subheadline).lineSpacing(5).textSelection(.enabled)
                case .code(let code, let language):
                    WorkshopCodeSnippet(code: code, language: language)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    var body: some View {
        let caption = WorkshopImageCaption(entry.text)
        VStack(alignment: .leading, spacing: 10) {
            if !caption.text.isEmpty { Text(caption.text).font(.subheadline).textSelection(.enabled) }
            ForEach(photos) { photo in
                if let image = UIImage(data: photo.data) {
                    Button { selected = photo } label: {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxWidth: 220, maxHeight: 180)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain).accessibilityLabel("查看图片")
                }
            }
            if loading { ProgressView("正在加载图片…").font(.caption) }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
                Button("重新加载图片") { Task { await loadPhotos() } }.font(.caption).disabled(loading)
            }
        }
        .task(id: "\(threadId ?? ""):\(entry.id):\(caption.count)") { await loadPhotos() }
        .sheet(item: $selected) { photo in WorkshopPhotoPreview(photo: photo) }
    }

    @MainActor private func loadPhotos() async {
        let count = WorkshopImageCaption(entry.text).count
        guard count > 0, !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        if photos.isEmpty { photos = store.messagePhotos(entry.id) }
        do {
            guard photos.count < count else { return }
            guard let threadId else { return }
            for index in photos.count..<count {
                let data = try await store.messageImage(threadId: threadId, messageId: entry.id, index: index, agent: agent)
                try Task.checkCancellation()
                guard UIImage(data: data) != nil else { throw HakoError(message: "图片格式无法显示。") }
                photos.append(WorkshopPhoto(id: "\(entry.id)-\(index)", data: data))
            }
        } catch is CancellationError { }
        catch { failure = "图片暂时无法加载：\(error.localizedDescription)" }
    }
}

struct WorkshopPhotoPreview: View {
    let photo: WorkshopPhoto
    var body: some View {
        SettingsSheet(title: "图片") {
            if let image = UIImage(data: photo.data) {
                WorkshopImageZoom(image: image)
            }
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
