import Foundation

struct HakoError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
