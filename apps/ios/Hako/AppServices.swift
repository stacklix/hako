import Foundation

enum AppServices {
    // Resolve configuration in the host. Token access remains private to the service,
    // and is deferred so child apps can still save local data while unconfigured.
    static func gitHub() -> any GitHubRepositoryAccess {
        GitHubService(settings: .load(), tokenProvider: { try TokenStore.read() })
    }
}
