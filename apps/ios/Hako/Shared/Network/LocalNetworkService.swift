import Foundation
import Combine

@MainActor protocol LocalNetworkProviding: AnyObject {
    var changes: AnyPublisher<Void, Never> { get }
    var isLocal: Bool { get }
    func refresh() async
}

@MainActor enum LocalNetworkService {
    static var shared: any LocalNetworkProviding = UnconfiguredLocalNetwork()
}

@MainActor private final class UnconfiguredLocalNetwork: LocalNetworkProviding {
    var changes: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    var isLocal: Bool { false }
    func refresh() async {}
}
