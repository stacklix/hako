import Foundation

@main struct DeviceProcessTests {
    static func main() throws {
        func sample(cpu: Any = 12.5, id: Int = 10, name: String = "worker", count: Int = 2, duplicate: Bool = false) throws -> DeviceProcessSnapshot {
            let row: [String: Any] = ["processId": id, "processName": name, "cpuUsagePercent": cpu, "memoryBytes": 4096]
            return try JSONDecoder().decode(DeviceProcessSnapshot.self, from: JSONSerialization.data(withJSONObject: [
                "collectedAt": "2026-11-17T09:00:00Z", "sampleWindowMs": 1000, "processCount": count,
                "cpuTop": duplicate ? [row, row] : [row], "memoryTop": [row]
            ]))
        }
        let valid = try sample()
        precondition(valid.isValid && valid.cpuTop.first?.cpuUsagePercent == 12.5 && valid.memoryTop.first?.memoryBytes == 4096)
        for invalid in try [sample(cpu: 101), sample(cpu: -1), sample(cpu: NSNull()), sample(id: 0),
                            sample(name: " "), sample(count: 0), sample(duplicate: true)] {
            precondition(!invalid.isValid)
        }
        let memoryOnly = try JSONDecoder().decode(DeviceProcessSnapshot.self, from: Data(#"{"collectedAt":"2026-11-17T09:00:00Z","sampleWindowMs":1000,"processCount":1,"cpuTop":[],"memoryTop":[{"processId":20,"processName":"new","memoryBytes":1024}]}"#.utf8))
        precondition(memoryOnly.isValid && memoryOnly.memoryTop[0].cpuUsagePercent == nil)
        print("PASS: process top-ten decoding, invalid values/duplicate PIDs and unavailable CPU samples")
    }
}
