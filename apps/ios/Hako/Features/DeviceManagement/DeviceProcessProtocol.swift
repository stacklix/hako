import Foundation

enum DeviceProcessCommand {
    static let status = "query.system.processes"
}

struct DeviceProcessSnapshot: Decodable {
    let collectedAt: String
    let sampleWindowMs: Int
    let processCount: Int
    let cpuTop: [DeviceProcessResource]
    let memoryTop: [DeviceProcessResource]

    var isValid: Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: collectedAt) ?? ISO8601DateFormatter().date(from: collectedAt)
        return date != nil && sampleWindowMs > 0 && processCount >= 0
            && cpuTop.count <= min(10, processCount) && memoryTop.count <= min(10, processCount)
            && Set(cpuTop.map(\.processId)).count == cpuTop.count
            && Set(memoryTop.map(\.processId)).count == memoryTop.count
            && cpuTop.allSatisfy { $0.isValid && $0.cpuUsagePercent != nil }
            && memoryTop.allSatisfy(\.isValid)
    }
}

struct DeviceProcessResource: Decodable, Identifiable {
    let processId: Int
    let processName: String
    let cpuUsagePercent: Double?
    let memoryBytes: UInt64
    var id: Int { processId }
    var isValid: Bool {
        processId > 0 && !processName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && cpuUsagePercent.map { $0.isFinite && (0...100).contains($0) } != false
    }
}
