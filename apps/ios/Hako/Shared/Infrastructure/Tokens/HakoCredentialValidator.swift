import Foundation

struct HakoCredentialValidationResult: Equatable {
    enum Status: String { case passed, invalidCredentials, permissionDenied, rateLimited, unavailable }
    let status: Status
    let message: String
    var checkedAt = Date()
    var title: String {
        switch status {
        case .passed: "验证通过"
        case .invalidCredentials: "鉴权失败"
        case .permissionDenied: "权限不足"
        case .rateLimited: "请求受限"
        case .unavailable: "暂未验证通过"
        }
    }
}

protocol HakoCredentialValidator {
    static var identifier: String { get }
    static var keys: Set<String> { get }
    static func validate(_ credentials: [String: String]) async throws -> HakoCredentialValidationResult
}

@MainActor final class HakoCredentialValidatorRegistry {
    private struct Handler {
        let keys: Set<String>
        let run: ([String: String]) async throws -> HakoCredentialValidationResult
    }
    private var handlers: [String: Handler] = [:]
    private(set) var registrationErrors: [String] = []
    var identifiers: Set<String> { Set(handlers.keys) }

    func register<Validator: HakoCredentialValidator>(_ validator: Validator.Type) {
        guard !validator.identifier.isEmpty, !validator.keys.isEmpty, handlers[validator.identifier] == nil else {
            registrationErrors.append("验证器标识缺失或重复：" + validator.identifier)
            return
        }
        handlers[validator.identifier] = Handler(keys: validator.keys, run: validator.validate)
    }

    func supports(_ definition: HakoTokenDefinition) -> Bool {
        registrationErrors.isEmpty && handlers[definition.validatorID]?.keys == Set(definition.fields.map(\.key))
    }

    func validate(_ definition: HakoTokenDefinition, credentials: [String: String]) async throws -> HakoCredentialValidationResult {
        guard supports(definition), let handler = handlers[definition.validatorID] else {
            return .init(status: .unavailable, message: "验证器未注册或与声明的密钥组不一致。")
        }
        guard Set(credentials.keys) == handler.keys,
              credentials.values.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (33...126).contains($0) } }) else {
            return .init(status: .invalidCredentials, message: "请先在主应用中保存完整凭据。")
        }
        do {
            try Task.checkCancellation()
            let result = try await handler.run(credentials)
            try Task.checkCancellation()
            // Child callbacks may include a provider message; never expose values.
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
            let variants = credentials.values.flatMap { value in
                [value, value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value, Data(value.utf8).base64EncodedString()]
            }.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
            let message = variants.reduce(result.message) { $0.replacingOccurrences(of: $1, with: "[已隐藏]") }
            return .init(status: result.status, message: String(message.prefix(2_048)), checkedAt: result.checkedAt)
        } catch is CancellationError { throw CancellationError() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            return .init(status: .unavailable, message: "验证请求未完成，请检查网络后重试。尚不能据此判断密钥无效。")
        }
    }
}
