import Foundation
import SwiftData

@MainActor enum UsageDatabase {
    static let shared: Result<ModelContainer, Error> = Result { try ModelContainer(for: DailyUsage.self) }
    static func context() throws -> ModelContext { ModelContext(try shared.get()) }
}
