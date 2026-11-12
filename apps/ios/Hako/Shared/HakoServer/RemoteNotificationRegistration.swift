import Foundation

/// Host-owned permission and Device Token registration, shared by sub-apps.
@MainActor enum RemoteNotificationRegistration {
    static var prepare: () async throws -> Void = { throw URLError(.unsupportedURL) }
}
