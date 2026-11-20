import Foundation

@main struct DeviceKageAndroidTests {
    static func main() throws {
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
        precondition(KageAndroidCommand.supporting.contains(KageAndroidCommand.execute) && !KageAndroidCommand.supporting.contains(KageAndroidCommand.list))
        print("PASS: Kage Android inventory, explicit routes, unknown screen, optional sensors, bounds and uncertain operation models")
    }
}
