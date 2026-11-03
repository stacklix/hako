import Foundation

// React Router single-fetch uses the turbo-stream v2 reference-table wire format.
// Decode data only; never evaluate JavaScript supplied by the remote service.
enum HeadplaneStream {
    static func decode(_ data: Data) throws -> HeadplaneJSON {
        guard data.count <= 8 * 1024 * 1024,
              let first = data.split(separator: 10, omittingEmptySubsequences: true).first else { throw HeadplaneFailure.incompatible }
        let parsed: HeadplaneJSON
        do { parsed = try JSONDecoder().decode(HeadplaneJSON.self, from: Data(first)) }
        catch { throw HeadplaneFailure.incompatible }
        guard let values = parsed.array else { return parsed }
        guard !values.isEmpty, values.count <= 200_000 else { throw HeadplaneFailure.incompatible }
        var decoder = Table(values: values)
        return try decoder.resolve(0)
    }

    private struct Table {
        let values: [HeadplaneJSON]
        var visits = 0
        var active = Set<Int>()
        var cache: [Int: HeadplaneJSON] = [:]
        mutating func ref(_ value: HeadplaneJSON) throws -> HeadplaneJSON {
            guard let i = value.int else { throw HeadplaneFailure.incompatible }
            return try resolve(i)
        }
        mutating func object(_ fields: [String: HeadplaneJSON]) throws -> HeadplaneJSON {
            var result: [String: HeadplaneJSON] = [:]
            for (key, value) in fields {
                guard key.hasPrefix("_"), let index = Int(key.dropFirst()), let name = try resolve(index).string,
                      result[name] == nil else { throw HeadplaneFailure.incompatible }
                result[name] = try ref(value)
            }
            return .object(result)
        }
        mutating func resolve(_ i: Int) throws -> HeadplaneJSON {
            visits += 1
            guard visits < 500_000, active.count < 100 else { throw HeadplaneFailure.incompatible }
            if [-7, -5, -1].contains(i) { return .null }
            if i == -4 { return .number(0) }
            guard values.indices.contains(i), !active.contains(i) else { throw HeadplaneFailure.incompatible }
            if let value = cache[i] { return value }
            active.insert(i); defer { active.remove(i) }
            let value = values[i], result: HeadplaneJSON
            switch value {
            case .object(let fields): result = try object(fields)
            case .array(let list):
                if let tag = list.first?.string {
                    switch tag {
                    case "D":
                        guard list.count == 2, case .number(let milliseconds) = list[1] else { throw HeadplaneFailure.incompatible }
                        result = .string(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: milliseconds / 1000)))
                    case "U", "B": guard list.count > 1 else { throw HeadplaneFailure.incompatible }; result = list[1]
                    case "N": guard list.count == 2 else { throw HeadplaneFailure.incompatible }; result = try object(list[1].object)
                    case "S": result = .array(try list.dropFirst().map { try ref($0) })
                    case "P", "SingleFetchFallback": result = .null // optional deferred metadata is not a core resource
                    case "SingleFetchClassInstance", "Z": guard list.count > 1 else { throw HeadplaneFailure.incompatible }; result = try ref(list[1])
                    case "SingleFetchRedirect": guard list.count > 1 else { throw HeadplaneFailure.incompatible }; result = try ref(list[1])
                    case "ErrorResponse":
                        guard list.count >= 3 else { throw HeadplaneFailure.incompatible }
                        result = .object(["data": try ref(list[1]), "status": try ref(list[2])])
                    case "SanitizedError":
                        guard list.count >= 3 else { throw HeadplaneFailure.incompatible }
                        result = .object(["message": try ref(list[2])])
                    case "E": result = .object(["message": list.count > 1 ? list[1] : .string("Headplane 内部错误")])
                    default: throw HeadplaneFailure.incompatible
                    }
                } else { result = .array(try list.map { try ref($0) }) }
            default: result = value
            }
            cache[i] = result; return result
        }
    }

    static func payload(_ root: HeadplaneJSON, resource: HeadplaneResource, action: Bool = false) throws -> HeadplaneJSON {
        if !root["redirect"].text.isEmpty {
            throw HeadplaneFailure(message: "Headplane 会话已失效，请重新连接。", status: 401)
        }
        let envelope = action ? root : root[resource.routeID]
        if envelope.object["error"] != nil {
            let error = envelope["error"]
            throw HeadplaneFailure(message: error["data"].string ?? error["message"].string ?? "Headplane 无法读取此功能。", status: error["status"].int)
        }
        guard let data = envelope.object["data"] else { throw HeadplaneFailure.incompatible }
        return data
    }
}
