import Foundation

struct HakoShortcutSkip: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}
