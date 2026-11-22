import Foundation

struct ConsoleAgent: Codable, Identifiable {
    var dataQueryEnabled: Bool? = nil
    var modules: ConsoleAgentModules? = nil
    let id: String
    let name: String
    let online: Bool
    let lastSeen: String
    let capabilities: [ConsoleAgentCapability]?
    var supportsCommands: Bool { capabilities?.isEmpty == false }
    var supportsWorkshop: Bool { modules?.workshop?.version == 1 }
    var supportsProxy: Bool { modules?.proxy?.version == 1 }
}
struct ConsoleAgentModules: Codable {
    struct Service: Codable {
        struct LAN: Codable { let addresses: [String]; let port: Int }
        let version: Int
        let lan: LAN?
    }
    let workshop: Service?
    let proxy: Service?
}
struct ConsoleAgentCapability: Codable, Identifiable {
    let name: String
    let version: Int
    var id: String { name }
}

struct ConsoleAgentError: Decodable, Error, LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message.isEmpty ? "设备执行失败（\(code)）。" : message }
}
enum ConsoleAgentReply<Result: Decodable>: Decodable {
    case result(Result)
    case failure(ConsoleAgentError)
    private enum CodingKeys: String, CodingKey { case result, error }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.result) != container.contains(.error) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Expected result or error"))
        }
        if container.contains(.error) { self = .failure(try container.decode(ConsoleAgentError.self, forKey: .error)) }
        else { self = .result(try container.decode(Result.self, forKey: .result)) }
    }
}
