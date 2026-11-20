import Foundation
import CryptoKit
import Darwin

struct AgentLanDescriptor: Decodable {
    static let command = "query.network.lan"
    let enabled: Bool
    let `protocol`: String?
    let addresses: [String]
    let port: Int
    let token: String?

    var key: SymmetricKey? {
        guard enabled, self.protocol == "hako-agent-lan-v1", (1...65535).contains(port),
              let token, let data = Data(base64Encoded: token), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }
    static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let byte = UInt8(part) else { return nil }
            value = value << 8 | UInt32(byte)
        }
        return value
    }
    static func isPrivate(_ value: UInt32) -> Bool {
        value >> 24 == 10 || value >> 20 == 0xac1 || value >> 16 == 0xc0a8
    }
    // Match a current Wi-Fi subnet, rather than treating every private address as local.
    static func isOnWiFiSubnet(_ text: String) -> Bool {
        guard let peer = ipv4(text), isPrivate(peer) else { return false }
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else { return false }
        defer { freeifaddrs(first) }
        var next = first
        while let item = next {
            defer { next = item.pointee.ifa_next }
            guard let address = item.pointee.ifa_addr, let mask = item.pointee.ifa_netmask,
                  address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: item.pointee.ifa_name) == "en0",
                  item.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let own = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.bigEndian
            let bits = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr.bigEndian
            if bits != 0, own & bits == peer & bits { return true }
        }
        return false
    }
}

@MainActor final class AgentLanTransport {
    private struct Cached { let value: AgentLanDescriptor?; let expires: Date }
    private var context = ""
    private var cache: [String: Cached] = [:]
    private var discoveries: [String: Task<AgentLanDescriptor?, Never>] = [:]
    private(set) var routes: [String: String] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 12
        return URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }()

    func reset(context: String) {
        guard self.context != context else { return }
        discoveries.values.forEach { $0.cancel() }
        discoveries.removeAll(); cache.removeAll(); routes.removeAll()
        self.context = context
    }
    func invoke(agentID: String, context: String, method: String, version: Int, params: [String: Any],
                discover: @escaping @MainActor () async throws -> Data) async throws -> Data? {
        reset(context: context)
        guard method.hasPrefix("query."), method != AgentLanDescriptor.command else { return nil }
        var descriptor = cache[agentID].flatMap { $0.expires > Date() ? $0 : nil }
        if descriptor == nil {
            let task = discoveries[agentID] ?? Task<AgentLanDescriptor?, Never> {
                do {
                    let reply = try JSONDecoder().decode(ConsoleAgentReply<AgentLanDescriptor>.self, from: await discover())
                    if case .result(let value) = reply, value.key != nil { return value }
                } catch { }
                return nil
            }
            discoveries[agentID] = task
            let value = await task.value
            guard self.context == context else { throw CancellationError() }
            try Task.checkCancellation()
            discoveries[agentID] = nil
            descriptor = Cached(value: value, expires: Date().addingTimeInterval(value == nil ? 15 : 60))
            cache[agentID] = descriptor
        }
        guard let value = descriptor?.value, let key = value.key else { routes[agentID] = nil; return nil }
        for address in value.addresses.prefix(8) where AgentLanDescriptor.isOnWiFiSubnet(address) {
            do {
                let data = try await request(address: address, descriptor: value, key: key, method: method, version: version, params: params)
                guard self.context == context else { throw CancellationError() }
                try Task.checkCancellation()
                routes[agentID] = address
                return data
            } catch is CancellationError { throw CancellationError() }
            catch {
                guard self.context == context else { throw CancellationError() }
                try Task.checkCancellation()
            }
        }
        // Queries can safely fall back; actions and administration never enter this transport.
        routes[agentID] = nil
        cache[agentID] = Cached(value: nil, expires: Date().addingTimeInterval(15))
        return nil
    }
    private func request(address: String, descriptor: AgentLanDescriptor, key: SymmetricKey,
                         method: String, version: Int, params: [String: Any]) async throws -> Data {
        guard let url = URL(string: "http://\(address):\(descriptor.port)/agent/v1/query") else { throw URLError(.badURL) }
        let id = UUID().uuidString
        let plain = try JSONSerialization.data(withJSONObject: ["id": id, "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
                                                               "method": method, "version": version, "params": params])
        guard plain.count <= 65536 else { throw URLError(.dataLengthExceedsMaximum) }
        let sealed = try AES.GCM.seal(plain, using: key, authenticating: Data("hako-agent-lan-v1:request".utf8))
        guard let combined = sealed.combined else { throw CocoaError(.coderInvalidValue) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["version": 1, "payload": combined.base64EncodedString()])
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        var body = Data()
        for try await byte in bytes {
            guard body.count < 96 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
            body.append(byte)
        }
        struct Wire: Decodable { let version: Int; let payload: String }
        let wire = try JSONDecoder().decode(Wire.self, from: body)
        guard wire.version == 1, let encrypted = Data(base64Encoded: wire.payload), (28...65564).contains(encrypted.count) else {
            throw URLError(.badServerResponse)
        }
        let result = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key,
                                      authenticating: Data("hako-agent-lan-v1:response".utf8))
        struct Correlation: Decodable { let id: String }
        guard try JSONDecoder().decode(Correlation.self, from: result).id == id else { throw URLError(.badServerResponse) }
        return result
    }
}
