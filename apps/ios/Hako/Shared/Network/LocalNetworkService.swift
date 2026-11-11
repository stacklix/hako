import Foundation
import Combine

@MainActor protocol LocalNetworkProviding: AnyObject {
    var changes: AnyPublisher<Void, Never> { get }
    func endpoint(for application: LocalNetworkApplication) async -> LocalNetworkEndpoint?
}

@MainActor enum LocalNetworkService {
    static var shared: any LocalNetworkProviding = UnconfiguredLocalNetwork()
}

@MainActor private final class UnconfiguredLocalNetwork: LocalNetworkProviding {
    var changes: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    func endpoint(for application: LocalNetworkApplication) async -> LocalNetworkEndpoint? { nil }
}
