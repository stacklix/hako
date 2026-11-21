import Foundation

@main struct DeviceKageAndroidTests {
    @MainActor static func main() async throws {
        let raw = """
        {"adbAvailable":true,"sampledAt":"2026-11-20T04:00:00Z","devices":[{"id":"aabb","name":"Xiaomi","model":"2109119DG","androidVersion":"14","connections":[{"serial":"731dd756","transportId":"1","kind":"usb","state":"device"},{"serial":"adb-demo._adb-tls-connect._tcp","transportId":"2","kind":"wifi","state":"device"}],"agentId":"GVAGD"}]}
        """
        let inventory = try JSONDecoder().decode(KageAndroidInventory.self, from: Data(raw.utf8))
        precondition(inventory.isValid && inventory.devices.count == 1)
        precondition(inventory.devices[0].connection?.kind == "usb" && inventory.devices[0].available)
        let invalid = raw.replacingOccurrences(of: "\"state\":\"device\"", with: "\"state\":\"unexpected\"")
        let invalidInventory = try JSONDecoder().decode(KageAndroidInventory.self, from: Data(invalid.utf8))
        precondition(!invalidInventory.isValid)
        let detail = """
        {"id":"aabb","screen":"unknown","batteryPercent":null,"charging":null,"memoryAvailableBytes":2147483648,"memoryTotalBytes":8589934592,"storageAvailableBytes":68719476736,"storageTotalBytes":137438953472,"uptimeSeconds":3600,"namiVersion":"1.0.14","namiVersionCode":15,"processRunning":true,"agentProcessRunning":true,"sampledAt":"2026-11-20T04:00:00Z"}
        """
        let snapshot = try JSONDecoder().decode(KageAndroidDetail.self, from: Data(detail.utf8))
        precondition(snapshot.isValid && snapshot.screenLabel == "未知" && snapshot.batteryPercent == nil)
        let bad = detail.replacingOccurrences(of: "\"uptimeSeconds\":3600", with: "\"uptimeSeconds\":-1")
        let invalidDetail = try JSONDecoder().decode(KageAndroidDetail.self, from: Data(bad.utf8))
        precondition(!invalidDetail.isValid)
        let operation = """
        {"id":"00000000-0000-0000-0000-000000000001","kind":"start","deviceId":"aabb","status":"unknown","phase":"stopped","message":"结果待确认","createdAt":"2026-11-20T04:00:00Z","updatedAt":"2026-11-20T04:00:00Z"}
        """
        let task = try JSONDecoder().decode(KageAndroidOperation.self, from: Data(operation.utf8))
        precondition(task.isValid && !task.active && task.statusLabel == "结果待确认")
        for (kind, status, artifact, expected) in [
            ("screenshot", "completed", "screen.png", true),
            ("screenshot", "running", "screen.png", false),
            ("screenshot", "failed", "screen.png", false),
            ("screenshot", "completed", "other.png", false),
            ("start", "completed", "screen.png", false),
        ] {
            let value = KageAndroidOperation(id: task.id, kind: kind, deviceId: task.deviceId, status: status,
                phase: "verified", message: "", createdAt: task.createdAt, updatedAt: task.updatedAt, artifact: artifact)
            precondition(value.hasScreenshot == expected)
        }
        try screenshotTransfer()
        try await parallelScreenshotDownload()
        precondition(KageAndroidCommand.supporting.contains(KageAndroidCommand.execute) && !KageAndroidCommand.supporting.contains(KageAndroidCommand.list))
        print("PASS: Kage Android inventory, explicit routes, unknown screen, optional sensors, bounds and uncertain operation models")
    }
    @MainActor private static func parallelScreenshotDownload() async throws {
        var payload = Data([137, 80, 78, 71, 13, 10, 26, 10])
        payload.append(Data(repeating: 7, count: 150_000))
        var active = 0, maximum = 0, calls: [Int] = [], fractions: [Double] = []
        let result = try await KageAndroidScreenshotDownload.read(fetch: { offset in
            active += 1; maximum = max(maximum, active); calls.append(offset)
            defer { active -= 1 }
            // Different latencies force replies out of order.
            try await Task.sleep(for: .milliseconds(offset % 3 == 0 ? 15 : 5))
            return KageAndroidArtifact(offset: Int64(offset), total: Int64(payload.count),
                data: payload.subdata(in: offset..<min(offset + 24576, payload.count)).base64EncodedString())
        }, progress: { fractions.append($0) })
        precondition(result == payload && maximum == 4 && active == 0)
        precondition(Set(calls).count == calls.count && calls.sorted() == Array(stride(from: 0, to: payload.count, by: 24576)))
        precondition(fractions == fractions.sorted() && fractions.last == 1)
        let jpeg = Data([255, 216, 255, 217])
        precondition(KageAndroidScreenshotPreview(contentType: "image/jpeg", total: jpeg.count, data: jpeg.base64EncodedString()).bytes == jpeg)
        precondition(KageAndroidScreenshotPreview(contentType: "image/png", total: jpeg.count, data: jpeg.base64EncodedString()).bytes == nil)
        precondition(KageAndroidScreenshotPreview(contentType: "image/jpeg", total: 40 * 1024 + 1, data: jpeg.base64EncodedString()).bytes == nil)
        precondition(KageAndroidScreenshotPreview(contentType: "image/jpeg", total: jpeg.count + 1, data: jpeg.base64EncodedString()).bytes == nil)
        precondition(KageAndroidScreenshotPreview(contentType: "image/jpeg", total: 4, data: "invalid").bytes == nil)
        print("PASS: four concurrent original-image reads, ordered byte assembly, monotonic progress, single-request preview bounds")
    }
    private static func screenshotTransfer() throws {
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        var payload = png
        payload.append(Data(repeating: 0, count: 55_000))
        var transfer = KageAndroidScreenshotTransfer()
        var offset = 0
        while offset < payload.count {
            let end = min(offset + 24576, payload.count)
            let complete = try transfer.append(KageAndroidArtifact(offset: Int64(offset), total: Int64(payload.count),
                data: payload.subdata(in: offset..<end).base64EncodedString()))
            precondition(complete == (end == payload.count))
            precondition(transfer.progress == Double(end) / Double(payload.count))
            offset = end
        }
        precondition(transfer.data == payload)
        let invalid = [
            KageAndroidArtifact(offset: 1, total: Int64(png.count), data: png.base64EncodedString()),
            KageAndroidArtifact(offset: 0, total: 0, data: ""),
            KageAndroidArtifact(offset: 0, total: 16 * 1024 * 1024 + 1, data: png.base64EncodedString()),
            KageAndroidArtifact(offset: 0, total: 1, data: png.base64EncodedString()),
            KageAndroidArtifact(offset: 0, total: 8, data: "not base64"),
            KageAndroidArtifact(offset: 0, total: 8, data: ""),
            KageAndroidArtifact(offset: 0, total: 8, data: Data(repeating: 0, count: 8).base64EncodedString()),
            KageAndroidArtifact(offset: 0, total: 24577, data: Data(repeating: 0, count: 24577).base64EncodedString()),
        ]
        for reply in invalid {
            var buffer = KageAndroidScreenshotTransfer()
            do { _ = try buffer.append(reply); preconditionFailure("Invalid screenshot chunk accepted") } catch { }
        }
        var changedTotal = KageAndroidScreenshotTransfer()
        _ = try changedTotal.append(KageAndroidArtifact(offset: 0, total: Int64(png.count), data: png.prefix(8).base64EncodedString()))
        do {
            _ = try changedTotal.append(KageAndroidArtifact(offset: 8, total: Int64(png.count + 1), data: png.dropFirst(8).base64EncodedString()))
            preconditionFailure("Changing screenshot length accepted")
        } catch { }
        // Exercise the exact multi-chunk file from a reported screenshot failure when supplied locally.
        if CommandLine.arguments.count > 1 {
            let real = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            var buffer = KageAndroidScreenshotTransfer()
            for start in stride(from: 0, to: real.count, by: 24576) {
                let end = min(start + 24576, real.count)
                _ = try buffer.append(KageAndroidArtifact(offset: Int64(start), total: Int64(real.count),
                    data: real.subdata(in: start..<end).base64EncodedString()))
            }
            precondition(buffer.data == real && buffer.progress == 1)
            print("PASS: reported screenshot reassembled (\(real.count) bytes)")
        }
        print("PASS: screenshot readiness, multi-chunk progress, byte identity and invalid transfer rejection")
    }
}
