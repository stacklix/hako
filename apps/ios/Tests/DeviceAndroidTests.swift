import Foundation

@main struct DeviceAndroidTests {
    static func main() throws {
        let decoder = JSONDecoder()
        let payload = #"{"platform":"android","manufacturer":"Xiaomi","model":"2109119DG","androidVersion":"14","sdk":34,"appVersion":"1.0.10","minimumServerVersion":"0.8.0","uptimeMs":29157274,"batteryPercent":89,"charging":false,"network":"wifi","memoryTotalBytes":7563886592,"memoryAvailableBytes":2520469504,"permissions":{"readSms":true,"sendSms":true,"readCalls":true,"callPhone":true,"readPhoneState":true},"allowSms":true,"allowCalls":true,"sampledAt":"2026-11-19T14:51:05.575192Z"}"#
        let status = try decoder.decode(AndroidDeviceStatus.self, from: Data(payload.utf8))
        precondition(status.isValid && status.networkLabel == "Wi-Fi" && status.uptimeLabel == "8 小时 5 分钟")
        let invalid = payload.replacingOccurrences(of: "2520469504", with: "9999999999")
        let invalidStatus = try decoder.decode(AndroidDeviceStatus.self, from: Data(invalid.utf8))
        precondition(!invalidStatus.isValid)
        let unknownBattery = payload.replacingOccurrences(of: "\"batteryPercent\":89", with: "\"batteryPercent\":-1")
        let unknownBatteryStatus = try decoder.decode(AndroidDeviceStatus.self, from: Data(unknownBattery.utf8))
        precondition(unknownBatteryStatus.isValid)
        let batteryJSON = #"{"levelPercent":70,"temperatureCelsius":32.5,"voltageVolts":4.123,"currentMilliamps":-550,"state":"discharging","powerSource":"battery","health":"good","sampledAt":"2026-11-19T14:51:05Z"}"#
        let battery = try decoder.decode(AndroidBatterySnapshot.self, from: Data(batteryJSON.utf8))
        precondition(battery.isValid && battery.temperatureCelsius == 32.5 && battery.healthLabel == "正常")
        precondition(battery.sourceLabel == "电池供电" && battery.currentMilliamps == -550)
        let unknownBatteryInfo = try decoder.decode(AndroidBatterySnapshot.self, from: Data(#"{"levelPercent":null,"temperatureCelsius":null,"voltageVolts":null,"currentMilliamps":null,"state":"unknown","powerSource":"unknown","health":"unknown","sampledAt":"now"}"#.utf8))
        precondition(unknownBatteryInfo.isValid && unknownBatteryInfo.healthLabel == "未知")
        let wifiJSON = #"{"connected":true,"ssid":"Test Network","ssidState":"available","rssiDbm":-55,"signalLevel":3,"linkSpeedMbps":433,"frequencyMhz":5180,"internetValidated":true,"sampledAt":"2026-11-19T14:51:05Z"}"#
        let wifi = try decoder.decode(AndroidWifiSnapshot.self, from: Data(wifiJSON.utf8))
        precondition(wifi.isValid && wifi.nameLabel == "Test Network" && wifi.nameExplanation == nil)
        let hiddenWifiJSON = wifiJSON.replacingOccurrences(of: "\"Test Network\"", with: "null").replacingOccurrences(of: "available", with: "permission_required")
        let hiddenWifi = try decoder.decode(AndroidWifiSnapshot.self, from: Data(hiddenWifiJSON.utf8))
        precondition(hiddenWifi.isValid && hiddenWifi.nameLabel == "名称不可用" && hiddenWifi.nameExplanation != nil)
        let invalidWifi = try decoder.decode(AndroidWifiSnapshot.self, from: Data(wifiJSON.replacingOccurrences(of: "-55", with: "-127").utf8))
        precondition(!invalidWifi.isValid)
        let storageJSON = #"{"storageTotalBytes":113252478976,"storageAvailableBytes":92627828736,"sampledAt":"2026-11-19T14:51:05Z"}"#
        let storage = try decoder.decode(AndroidStorageSnapshot.self, from: Data(storageJSON.utf8))
        precondition(storage.isValid && storage.storageAvailableBytes == 92627828736)
        for invalidStorage in [storageJSON.replacingOccurrences(of: "113252478976", with: "0"),
                               storageJSON.replacingOccurrences(of: "92627828736", with: "113252478977")] {
            let value = try decoder.decode(AndroidStorageSnapshot.self, from: Data(invalidStorage.utf8))
            precondition(!value.isValid)
        }
        let sims = try decoder.decode(AndroidSimSnapshot.self, from: Data(#"{"items":[{"subscriptionId":7,"slotIndex":1,"carrierName":"中国移动","displayName":"我的卡"}],"sampledAt":"2026-11-19T14:51:05Z"}"#.utf8))
        precondition(sims.isValid && sims.items[0].label == "SIM 2 · 中国移动")
        let sms = try decoder.decode(AndroidHistoryPage.self, from: Data(#"{"items":[{"id":"200","number":"10086","text":"内容","timestamp":1795100000000,"type":1,"subscriptionId":7}],"nextCursor":"200"}"#.utf8))
        precondition(sms.isValid(sms: true) && !sms.isValid(sms: false) && sms.items[0].typeLabel(sms: true) == "收到")
        let calls = try decoder.decode(AndroidHistoryPage.self, from: Data(#"{"items":[{"id":"99","number":"10086","timestamp":1795100000000,"type":3,"durationSeconds":0}],"nextCursor":null}"#.utf8))
        precondition(calls.isValid(sms: false) && !calls.isValid(sms: true) && calls.items[0].typeLabel(sms: false) == "未接")
        precondition(!AndroidHistoryPage.validID("-1") && !AndroidHistoryPage.validID("1e2") && !AndroidHistoryPage.validID("１２"))
        precondition(AndroidDeviceCommand.validNumber("+8613800000000") && AndroidDeviceCommand.validNumber("10086"))
        for number in ["12", "+", "138 0000", "123\n", "１２３", String(repeating: "1", count: 21)] {
            precondition(!AndroidDeviceCommand.validNumber(number))
        }
        let all: Set<String> = [AndroidDeviceCommand.status, AndroidDeviceCommand.storage, AndroidDeviceCommand.battery, AndroidDeviceCommand.wifi, AndroidDeviceCommand.sims, AndroidDeviceCommand.messages,
            AndroidDeviceCommand.calls, AndroidDeviceCommand.operation, AndroidDeviceCommand.send, AndroidDeviceCommand.call]
        precondition(AndroidDeviceCommand.pageNames(all) == [AndroidDeviceCommand.status, AndroidDeviceCommand.sims,
            AndroidDeviceCommand.messages, AndroidDeviceCommand.calls])
        precondition(AndroidDeviceCommand.pageNames([AndroidDeviceCommand.send]) == [AndroidDeviceCommand.send])
        precondition(AndroidDeviceCommand.pageNames([AndroidDeviceCommand.messages]) == [AndroidDeviceCommand.messages])
        precondition(AndroidDeviceCommand.pageNames([AndroidDeviceCommand.operation]) == [AndroidDeviceCommand.operation])
        precondition(AndroidDeviceCommand.pageNames([AndroidDeviceCommand.storage]) == [AndroidDeviceCommand.storage])
        precondition(AndroidDeviceCommand.pageNames([AndroidDeviceCommand.battery, AndroidDeviceCommand.wifi]) == [AndroidDeviceCommand.battery, AndroidDeviceCommand.wifi])
        let pending = AndroidPendingOperation(kind: "sms")
        precondition(pending.isValid && pending.result == nil)
        let restored = try decoder.decode(AndroidPendingOperation.self, from: JSONEncoder().encode(pending))
        precondition(restored.requestId == pending.requestId && restored.isValid)
        let receipt = #"{"requestId":"REQUEST","kind":"sms","status":"submitted","message":"已提交","updatedAt":"2026-11-19T14:51:05Z"}"#.replacingOccurrences(of: "REQUEST", with: pending.requestId)
        let submitted = try decoder.decode(AndroidOperation.self, from: Data(receipt.utf8))
        precondition(submitted.isValid && !submitted.finished && submitted.title == "已提交短信发送")
        let sent = try decoder.decode(AndroidOperation.self, from: Data(receipt.replacingOccurrences(of: "submitted", with: "sent").utf8))
        precondition(sent.finished && sent.title.contains("未确认送达"))
        let call = try decoder.decode(AndroidOperation.self, from: Data(receipt.replacingOccurrences(of: "\"sms\"", with: "\"call\"").utf8))
        precondition(call.finished && call.title == "已提交拨号")
        let unknown = try decoder.decode(AndroidOperation.self, from: Data(receipt.replacingOccurrences(of: "submitted", with: "unknown").utf8))
        precondition(!unknown.finished && unknown.isValid)
        let unrelated = try decoder.decode(AndroidOperation.self, from: Data(receipt.replacingOccurrences(of: pending.requestId, with: UUID().uuidString.lowercased()).utf8))
        var mismatched = pending; mismatched.result = unrelated
        precondition(!mismatched.isValid)
        print("PASS: Android status, SIMs, history, capability grouping, phone validation and durable operation identity")
    }
}
