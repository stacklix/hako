import Foundation
import Combine

@MainActor protocol AuthenticatedServerAccess: AnyObject {
    var changes: AnyPublisher<Void, Never> { get }
    var serverURL: String { get }
    var username: String { get }
    var authenticated: Bool { get }
    var hasSavedSession: Bool { get }
    var logoutPending: Bool { get }
    var busy: Bool { get }
    var message: String? { get }
    var requestContext: String { get }
    func restore() async
    func send(_ path: String, method: String, body: [String: Any]?, logSource: HakoLogSource) async throws -> Data
}

struct ServerHTTPError: Error, LocalizedError {
    let status: Int
    let code: String
    var errorDescription: String? {
        switch code {
        case "device_not_registered": return "账号或设备公钥尚未在服务端登记。"
        case "invalid_login_challenge": return "登录挑战无效或已过期，请重新登录。"
        case "rate_limited", "too_many_requests": return "请求过于频繁或设备繁忙，请稍后重试。"
        case "session_revoked": return "登录会话已撤销，请重新登录。"
        case "storage_unavailable": return "服务器暂时无法保存更改，请稍后重试。"
        case "login_request_expired": return "二维码已过期，请在网页刷新后重新扫码。"
        case "login_request_not_found", "login_request_finished": return "登录请求已失效或已处理，请刷新网页二维码。"
        case "login_confirmation_mismatch": return "登录确认码或签名挑战不匹配，请重新扫码。"
        case "login_confirmation_locked": return "确认码输错次数过多，此请求已拒绝。请从原应用重新发起登录。"
        case "admin_approval_not_allowed", "approver_revoked": return "Console 会话无效，请检查服务端公钥配置后重新登录。"
        case "invalid_device_proof", "invalid_session_or_proof": return "设备身份验证失败，请检查手机与服务器时间。"
        default: return "服务器请求失败（\(status)：\(code)）。"
        }
    }
}

// Host resolves the concrete authenticated client; children only receive this contract.
@MainActor enum AuthenticatedServerService {
    static var shared: any AuthenticatedServerAccess { ConsoleClient.shared }
}
