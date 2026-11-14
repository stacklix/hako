import SwiftUI
import UIKit

struct AssistantSendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: 36, height: 36)
            .foregroundStyle(enabled ? HakoStyle.background : HakoStyle.muted)
            .background(enabled ? HakoStyle.text : HakoStyle.line, in: Circle())
            .padding(4).contentShape(Circle()).opacity(configuration.isPressed ? 0.6 : 1)
    }
}

struct AssistantImageSelection: Identifiable {
    let id = UUID()
    let images: [Data]
    let index: Int
}

struct AssistantPhotoThumbnail: View {
    let data: Data
    let size: CGFloat
    var body: some View {
        Group {
            if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo") }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("已附加的图片")
    }
}

struct AssistantUserMessage: View {
    let text: String
    let images: [Data]
    let preview: ([Data], Int) -> Void
    var body: some View {
        HStack {
            Spacer(minLength: 28)
            VStack(alignment: .leading, spacing: 7) {
                if !images.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 100))], alignment: .leading, spacing: 8) {
                        ForEach(images.indices, id: \.self) { index in
                            Button {
                                preview(images, index)
                            } label: { AssistantPhotoThumbnail(data: images[index], size: 76) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("预览第 \(index + 1) 张图片，共 \(images.count) 张")
                        }
                    }
                    .frame(maxWidth: CGFloat(min(images.count, 3) * 84 - 8), alignment: .leading)
                }
                if !text.isEmpty { Text(verbatim: text).textSelection(.enabled) }
            }
            .padding(10)
            .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
        }
    }
}

struct AssistantAttachmentsView: View {
    @Binding var attachments: [AssistantComposerDraft.Attachment]
    let loadingPhoto: Bool
    let preview: ([Data], Int) -> Void
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                    Button {
                        preview(attachments.map(\.data), index)
                    } label: { AssistantPhotoThumbnail(data: attachment.data, size: 76) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("预览第 \(index + 1) 张待发送图片")
                    .overlay(alignment: .topTrailing) {
                        Button { attachments.removeAll { $0.id == attachment.id } } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.65)).frame(width: 32, height: 32)
                        }
                        .accessibilityLabel("移除第 \(index + 1) 张图片")
                        .disabled(loadingPhoto)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }
}

struct AssistantThinkingView: View {
    let text: String
    @Binding var expanded: Bool
    var body: some View {
        DisclosureGroup("模型思考", isExpanded: $expanded) {
            Text(verbatim: text).font(.footnote).foregroundStyle(.secondary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
        }
        .font(.footnote).foregroundStyle(.secondary)
    }
}

struct AssistantInputBar: View {
    @Binding var text: String
    let prompt: String
    let imageCount: Int
    let maximumImages: Int
    let allowsPhotos: Bool
    let canSend: Bool
    let working: Bool
    var focus: FocusState<Bool>.Binding
    let onPhotos: () -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            Button(action: onPhotos) {
                Image(systemName: "plus").font(.system(size: 22, weight: .bold))
                    .foregroundStyle(HakoStyle.text).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("添加图片")
            .accessibilityValue("已添加 \(imageCount) 张，最多 \(maximumImages) 张")
            .disabled(!allowsPhotos)
            TextField(prompt, text: $text, axis: .vertical)
                .font(.body).lineLimit(1...5)
                .padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("聊天消息")
                .focused(focus)
            if working {
                Button(action: onStop) {
                    Image(systemName: "square.fill").font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(AssistantSendButtonStyle())
                .accessibilityLabel("停止生成")
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(AssistantSendButtonStyle())
                .disabled(!canSend)
                .accessibilityLabel("发送消息")
            }
        }
        .padding(4)
        .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 27))
        .overlay { RoundedRectangle(cornerRadius: 27).strokeBorder(HakoStyle.line, lineWidth: 1).allowsHitTesting(false) }
    }
}

struct AssistantShortcutButton: View {
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.footnote)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(HakoStyle.card, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
