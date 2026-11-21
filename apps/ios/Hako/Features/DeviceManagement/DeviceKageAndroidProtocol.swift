import Foundation

enum KageAndroidCommand {
    static let list = "query.android.devices"
    static let detail = "query.android.device"
    static let operations = "query.android.operations"
    static let operation = "query.android.operation"
    static let logs = "query.android.logs"
    static let artifact = "query.android.artifact"
    static let preview = "query.android.preview"
    static let execute = "action.android.execute"
    static let upload = "action.android.upload"
    static let stream = "action.android.stream"
    static let supporting: Set<String> = [detail, operations, operation, logs, artifact, preview, execute, upload, stream]
}

struct KageAndroidConnection: Codable, Identifiable {
    let serial: String
    let transportId: String
    let kind: String
    let state: String
    var id: String { serial }
    var label: String { kind == "usb" ? "USB" : "无线调试" }
    var available: Bool { state == "device" }
}
struct KageAndroidDevice: Codable, Identifiable {
    let id: String
    let name: String
    let model: String?
    let androidVersion: String?
    let connections: [KageAndroidConnection]
    let agentId: String?
    var connection: KageAndroidConnection? {
        connections.first { $0.available && $0.kind == "usb" } ?? connections.first { $0.available } ?? connections.first
    }
    var available: Bool { connections.contains(where: \.available) }
    var stateLabel: String { available ? "ADB 已连接" : connections.contains { $0.state == "unauthorized" } ? "等待授权" : "ADB 不可用" }
    var isValid: Bool {
        !id.isEmpty && id.count <= 128 && !name.isEmpty && name.count <= 256
        && connections.count <= 32 && Set(connections.map(\.serial)).count == connections.count
        && connections.allSatisfy { !$0.serial.isEmpty && $0.serial.count <= 256
            && ["usb", "wifi"].contains($0.kind) && ["device", "offline", "unauthorized"].contains($0.state) }
    }
}
struct KageAndroidInventory: Decodable {
    let adbAvailable: Bool
    let devices: [KageAndroidDevice]
    let sampledAt: String
    var isValid: Bool { devices.count <= 128 && Set(devices.map(\.id)).count == devices.count && devices.allSatisfy(\.isValid) }
}
struct KageAndroidDetail: Decodable {
    let id: String
    let screen: String
    let batteryPercent: Int?
    let charging: Bool?
    let memoryAvailableBytes: Int64?
    let memoryTotalBytes: Int64?
    let storageAvailableBytes: Int64?
    let storageTotalBytes: Int64?
    let uptimeSeconds: Double?
    let namiVersion: String?
    let namiVersionCode: Int64?
    let processRunning: Bool
    let agentProcessRunning: Bool
    let sampledAt: String
    var screenLabel: String {
        switch screen { case "on": "亮屏"; case "off": "熄屏"; case "doze": "息屏显示"; default: "未知" }
    }
    var isValid: Bool {
        ["on", "off", "doze", "unknown"].contains(screen)
        && (batteryPercent.map { (0...100).contains($0) } ?? true)
        && [memoryAvailableBytes, memoryTotalBytes, storageAvailableBytes, storageTotalBytes, namiVersionCode].allSatisfy { $0.map { $0 >= 0 } ?? true }
        && (memoryAvailableBytes == nil || memoryTotalBytes == nil || memoryAvailableBytes! <= memoryTotalBytes!)
        && (storageAvailableBytes == nil || storageTotalBytes == nil || storageAvailableBytes! <= storageTotalBytes!)
        && (uptimeSeconds.map { $0.isFinite && $0 >= 0 && $0 < 31_557_600_000 } ?? true)
    }
}
struct KageAndroidOperation: Codable, Identifiable {
    let id: String
    let kind: String
    let deviceId: String
    let status: String
    let phase: String
    let message: String
    let createdAt: String
    let updatedAt: String
    let artifact: String?
    var active: Bool { status == "queued" || status == "running" }
    var hasScreenshot: Bool { kind == "screenshot" && status == "completed" && artifact == "screen.png" }
    var title: String {
        switch kind {
        case "wake": "手机亮屏"; case "sleep": "手机熄屏"; case "screenshot": "获取截图"
        case "start": "启动 Nami"; case "restart": "重新启动 Nami"; case "install": "覆盖安装 Nami"
        case "pair": "无线调试配对"; case "connect": "建立无线连接"; case "tools": "下载 ADB 工具"
        case "associate": "关联 Nami Agent"; default: "Android 操作"
        }
    }
    var statusLabel: String {
        switch status { case "queued": "已提交"; case "running": "执行中"; case "completed": "已完成"
        case "failed": "执行失败"; default: "结果待确认" }
    }
    var isValid: Bool { UUID(uuidString: id) != nil && ["queued", "running", "completed", "failed", "unknown"].contains(status) }
}
struct KageAndroidOperations: Decodable { let operations: [KageAndroidOperation] }
struct KageAndroidLog: Decodable { let text: String; let sampledAt: String }
struct KageAndroidArtifact: Decodable, Sendable { let offset: Int64; let total: Int64; let data: String }
struct KageAndroidScreenshotPreview: Decodable {
    let contentType: String
    let total: Int
    let data: String
    var bytes: Data? {
        guard contentType == "image/jpeg", (3...40 * 1024).contains(total), data.count <= 54616,
              let value = Data(base64Encoded: data), value.count == total,
              value.starts(with: [255, 216, 255]) else { return nil }
        return value
    }
}
enum KageAndroidScreenshotDownload {
    @MainActor static func read(fetch: @escaping @MainActor @Sendable (Int) async throws -> KageAndroidArtifact,
                               progress: @MainActor (Double) -> Void) async throws -> Data {
        var transfer = KageAndroidScreenshotTransfer()
        var complete = try transfer.append(await fetch(0))
        progress(transfer.progress)
        while !complete {
            let offsets = Array(stride(from: transfer.data.count, to: Int(transfer.total!), by: 24576).prefix(4))
            let replies = try await withThrowingTaskGroup(of: KageAndroidArtifact.self) { group in
                for offset in offsets { group.addTask { @MainActor in try await fetch(offset) } }
                var replies: [KageAndroidArtifact] = []
                for try await reply in group { replies.append(reply) }
                return replies.sorted { $0.offset < $1.offset }
            }
            for reply in replies { complete = try transfer.append(reply); progress(transfer.progress) }
        }
        return transfer.data
    }
}
struct KageAndroidScreenshotTransfer {
    private(set) var data = Data()
    private(set) var total: Int64?
    var progress: Double { total.map { Double(data.count) / Double($0) } ?? 0 }
    mutating func append(_ reply: KageAndroidArtifact) throws -> Bool {
        guard reply.offset == data.count, (1...16 * 1024 * 1024).contains(reply.total),
              total == nil || total == reply.total, reply.data.count <= 32768,
              let bytes = Data(base64Encoded: reply.data), !bytes.isEmpty, bytes.count <= 24576,
              data.count + bytes.count <= reply.total else { throw TransferError.invalid }
        total = reply.total
        data.append(bytes)
        let complete = data.count == reply.total
        if complete, !data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { throw TransferError.invalid }
        return complete
    }
    private enum TransferError: LocalizedError {
        case invalid
        var errorDescription: String? { "截图传输数据无效，请重新读取。" }
    }
}
struct KageAndroidUpload: Decodable { let uploadId: String; let received: Int64; let completed: Bool }
