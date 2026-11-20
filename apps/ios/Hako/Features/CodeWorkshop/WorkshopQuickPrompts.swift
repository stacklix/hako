import Foundation

struct WorkshopQuickPrompt: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name = ""
    var text = ""
    var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf16.count <= 120 &&
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.utf16.count <= 4000
    }
}
