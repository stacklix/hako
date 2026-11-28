import Foundation

struct AssistantHistoryMessage: Identifiable {
    let id: UUID
    let text: String
    let isUser: Bool
    var images: [Data] = []
    var html: AssistantHTML?
    var confirmationSymbols: [Int: String]?
    var outcome: String?
}
