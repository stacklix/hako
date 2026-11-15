import Foundation

enum DeviceServiceCommand {
    static let status = "query.services.status"
    static let start = "action.services.start"
}

struct DeviceServiceSnapshot: Decodable {
    let collectedAt: String
    let services: [DeviceServiceStatus]
    let warnings: [String]
    var isValid: Bool {
        !collectedAt.isEmpty && services.count <= 128
            && Set(services.map(\.id)).count == services.count && services.allSatisfy(\.isValid)
    }
}

enum DeviceServiceState: String, Decodable {
    case responding, httpError = "http_error", stopped, unreachable, unknown

    var title: String {
        switch self {
        case .responding: "已响应"
        case .httpError: "服务异常"
        case .stopped: "未监听"
        case .unreachable: "HTTP 探测失败"
        case .unknown: "状态未知"
        }
    }
}

struct DeviceServiceStatus: Decodable, Identifiable {
    let name: String
    let port: Int
    let description: String?
    let status: DeviceServiceState
    let processes: [ConsoleListenerProcess]
    let http: DeviceServiceHTTP?
    let canStart: Bool
    let startup: DeviceServiceStartup?
    var id: String { name }
    var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1...65535).contains(port),
              Set(processes.map(\.id)).count == processes.count, processes.allSatisfy(\.isValid),
              http == nil || http!.isValid,
              !canStart || (status == .stopped && startup?.state != "starting" && startup?.state != "unknown") else { return false }
        switch status {
        case .responding: return !processes.isEmpty && http?.statusCode.map { (100..<500).contains($0) } == true
        case .httpError: return !processes.isEmpty && http?.statusCode.map { (500...599).contains($0) } == true
        case .stopped: return processes.isEmpty && http == nil
        case .unreachable: return !processes.isEmpty && http != nil && http?.statusCode == nil
        case .unknown: return http == nil
        }
    }
}

struct DeviceServiceStartup: Decodable {
    let state: String
    let message: String
    let requestedAt: String
}

struct DeviceServiceStartReply: Decodable {
    let name: String
    let requestId: String
    let state: String
    let message: String
}

struct DeviceServiceHTTP: Decodable {
    let url: String
    let statusCode: Int?
    let elapsedMs: Int64
    let failure: String?
    var isValid: Bool {
        guard let address = URLComponents(string: url), address.scheme == "http", address.host != nil,
              address.user == nil, address.password == nil, elapsedMs >= 0 else { return false }
        return statusCode.map { (100...599).contains($0) && failure == nil }
            ?? (failure?.isEmpty == false)
    }
}
