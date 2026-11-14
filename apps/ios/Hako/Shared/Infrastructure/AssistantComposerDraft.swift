import Foundation

struct AssistantComposerDraft: Codable, Equatable {
    struct Attachment: Identifiable, Codable, Equatable {
        var id = UUID()
        let photoIdentifier: String?
        let data: Data
    }

    var text = ""
    var attachments: [Attachment] = []
    var isEmpty: Bool { text.isEmpty && attachments.isEmpty }
}
