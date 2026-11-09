import Foundation

@MainActor protocol HakoTerminalRendering: AnyObject {
    func reset()
    func feed(_ bytes: Data)
    func focus()
    func blur()
    func key(_ key: String)
}

// Own output independently of SwiftUI's UIKit view lifetime. Nothing here is
// persisted or logged, and output replay never sends input back to the server.
@MainActor final class HakoTerminalDisplay {
    private weak var renderer: (any HakoTerminalRendering)?
    private(set) var bytes = Data()
    private let limit: Int
    init(limit: Int = 1_048_576) { self.limit = max(1, limit) }
    func isAttached(_ renderer: any HakoTerminalRendering) -> Bool { self.renderer === renderer }
    func attach(_ renderer: any HakoTerminalRendering) {
        self.renderer = renderer
        renderer.reset()
        if !bytes.isEmpty { renderer.feed(bytes) }
    }
    func detach(_ renderer: any HakoTerminalRendering) {
        guard isAttached(renderer) else { return }
        renderer.blur(); self.renderer = nil
    }
    func beginSession() { bytes.removeAll(); renderer?.reset() }
    func append(_ value: Data) {
        bytes.append(value)
        if bytes.count > limit { bytes.removeFirst(bytes.count - limit) }
        renderer?.feed(value)
    }
    func focus() { renderer?.focus() }
    func blur() { renderer?.blur() }
    func key(_ key: String) { renderer?.key(key) }
}
