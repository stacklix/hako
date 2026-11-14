import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Owned by the session so dismissing a sheet does not cancel image imports.
@MainActor
final class AssistantPhotoImporter {
    private var task: Task<Void, Never>?
    private var importID: UUID?

    func cancel() {
        importID = nil; task?.cancel(); task = nil
    }

    func load(_ items: [PhotosPickerItem], maximumCount: Int, draft: Binding<AssistantComposerDraft>,
              onLoading: @escaping (Bool) -> Void, onCompletion: @escaping (String?) -> Void) {
        guard !items.isEmpty else { return }
        task?.cancel()
        let id = UUID()
        importID = id
        onLoading(true)
        task = Task {
            var issue: String?
            defer {
                if importID == id {
                    task = nil; importID = nil
                    onLoading(false); onCompletion(issue)
                }
            }
            var failures = 0
            for item in items {
                do {
                    try Task.checkCancellation()
                    guard importID == id else { return }
                    guard draft.wrappedValue.attachments.count < maximumCount else { break }
                    if let identifier = item.itemIdentifier,
                       draft.wrappedValue.attachments.contains(where: { $0.photoIdentifier == identifier }) { continue }
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw LanguageModelError.invalid("无法读取这张图片。")
                    }
                    let encoded = await Task.detached(priority: .userInitiated) { Self.modelImage(data) }.value
                    try Task.checkCancellation()
                    guard importID == id else { return }
                    guard let encoded else { throw LanguageModelError.invalid("无法处理这张图片，请换一张。") }
                    if !draft.wrappedValue.attachments.contains(where: { $0.data == encoded }) {
                        draft.wrappedValue.attachments.append(.init(photoIdentifier: item.itemIdentifier, data: encoded))
                    }
                } catch is CancellationError { return }
                catch {
                    guard importID == id, !Task.isCancelled else { return }
                    failures += 1
                }
            }
            if failures > 0 { issue = "有 \(failures) 张图片未能读取，请重新选择。其余图片已保留。" }
        }
    }

    nonisolated private static func modelImage(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        for quality in [0.86, 0.68, 0.5] {
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), encoded.length <= 2_000_000 { return encoded as Data }
        }
        return nil
    }
}
