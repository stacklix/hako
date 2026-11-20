import Foundation

enum AndroidDeviceCommand {
    static let status = "query.device.status"
    static let storage = "query.device.storage"
    static let battery = "query.device.battery"
    static let wifi = "query.network.wifi"
    static let screen = "query.device.screen"
    static let sims = "query.telephony.sims"
    static let messages = "query.sms.messages"
    static let calls = "query.telephony.calls"
    static let operation = "query.device.operation"
    static let send = "action.sms.send"
    static let call = "action.telephony.call"
    static let names: Set<String> = [status, storage, battery, wifi, screen, sims, messages, calls, operation, send, call]

    // A page can expose a query, an action, or both. Unknown versions stay separate.
    static func pageNames(_ supported: Set<String>) -> Set<String> {
        var pages = supported
        if supported.contains(status) { pages.subtract([storage, battery, wifi, screen]) }
        if supported.contains(messages) { pages.remove(send) }
        if supported.contains(calls) { pages.remove(call) }
        if supported.contains(send) || supported.contains(call) { pages.remove(operation) }
        return pages
    }

    static func validNumber(_ value: String) -> Bool {
        value.range(of: "\\A\\+?[0-9]{3,20}\\z", options: .regularExpression) != nil
    }
}

struct AndroidStorageSnapshot: Decodable {
    let storageTotalBytes: UInt64
    let storageAvailableBytes: UInt64
    let sampledAt: String
    var isValid: Bool { storageTotalBytes > 0 && storageAvailableBytes <= storageTotalBytes }
}

struct AndroidScreenSnapshot: Decodable {
    let displayState: String
    let interactive: Bool
    let sampledAt: String
    var isValid: Bool { ["on", "off", "doze", "doze_suspend", "on_suspend", "vr", "unknown"].contains(displayState) }
    var stateLabel: String {
        switch displayState {
        case "on": "亮屏"
        case "off": "熄屏"
        case "doze", "doze_suspend": "息屏显示"
        case "on_suspend": "亮屏（低功耗）"
        case "vr": "亮屏（VR）"
        default: "未知"
        }
    }
}

struct AndroidBatterySnapshot: Decodable {
    let levelPercent: Int?
    let temperatureCelsius: Double?
    let voltageVolts: Double?
    let currentMilliamps: Double?
    let state: String
    let powerSource: String
    let health: String
    let sampledAt: String
    var isValid: Bool {
        (levelPercent.map { (0...100).contains($0) } ?? true)
            && (temperatureCelsius.map { $0.isFinite && (-50...100).contains($0) } ?? true)
            && (voltageVolts.map { $0.isFinite && $0 > 0 } ?? true)
            && (currentMilliamps.map(\.isFinite) ?? true)
    }
    var stateLabel: String {
        switch state { case "charging": "正在充电"; case "discharging": "放电中"; case "full": "已充满"; case "not_charging": "未充电"; default: "未知" }
    }
    var sourceLabel: String {
        switch powerSource { case "ac": "电源适配器"; case "usb": "USB"; case "wireless": "无线充电"; case "dock": "充电底座"; case "battery": "电池供电"; case "other": "其他电源"; default: "未知" }
    }
    var healthLabel: String {
        switch health { case "good": "正常"; case "overheat": "过热"; case "cold": "温度过低"; case "dead": "失效"; case "over_voltage": "电压过高"; case "failure": "故障"; default: "未知" }
    }
}

struct AndroidWifiSnapshot: Decodable {
    let connected: Bool
    let ssid: String?
    let ssidState: String
    let rssiDbm: Int?
    let signalLevel: Int?
    let linkSpeedMbps: Int?
    let frequencyMhz: Int?
    let internetValidated: Bool
    let sampledAt: String
    var isValid: Bool {
        (rssiDbm.map { (-126 ... -1).contains($0) } ?? true)
            && (signalLevel.map { (0...4).contains($0) } ?? true)
            && (linkSpeedMbps.map { $0 > 0 } ?? true) && (frequencyMhz.map { $0 > 0 } ?? true)
            && (ssidState != "available" || (connected && ssid?.isEmpty == false))
            && (connected || (ssid == nil && ssidState == "not_connected" && !internetValidated))
    }
    var nameLabel: String {
        guard connected else { return "未连接" }
        if ssidState == "available", let ssid { return ssid }
        return "名称不可用"
    }
    var nameExplanation: String? {
        guard connected else { return nil }
        switch ssidState {
        case "available": return nil
        case "permission_required": return "请在 Android 手机的 Nami 系统设置 → Wi-Fi 信息中授权精确位置，以读取网络名称。"
        case "location_disabled": return "请在 Android 手机上开启系统定位服务，以读取 Wi-Fi 名称。"
        case "background_permission_required": return "系统未提供名称，请检查 Nami 的后台位置授权。"
        default: return "系统未提供 Wi-Fi 名称，请检查手机权限、定位服务及后台访问限制。"
        }
    }
}

struct AndroidDeviceStatus: Decodable {
    let platform: String
    let manufacturer: String
    let model: String
    let androidVersion: String
    let sdk: Int
    let appVersion: String
    let minimumServerVersion: String
    let uptimeMs: Int64
    let network: String
    let memoryTotalBytes: UInt64
    let memoryAvailableBytes: UInt64
    let permissions: [String: Bool]
    let allowSms: Bool
    let allowCalls: Bool
    let sampledAt: String
    static let permissionLabels = [
        ("readSms", "读取短信"), ("sendSms", "发送短信"), ("readCalls", "读取通话记录"),
        ("callPhone", "拨打电话"), ("readPhoneState", "读取电话状态")
    ]
    var isValid: Bool {
        platform == "android" && sdk > 0 && uptimeMs >= 0
            && memoryTotalBytes > 0 && memoryAvailableBytes <= memoryTotalBytes
    }
    var networkLabel: String {
        switch network {
        case "wifi": "Wi-Fi"
        case "cellular": "移动网络"
        case "ethernet": "以太网"
        case "offline": "无网络"
        default: "其他网络"
        }
    }
    var uptimeLabel: String { "\(uptimeMs / 3_600_000) 小时 \(uptimeMs / 60_000 % 60) 分钟" }
}

struct AndroidSimSnapshot: Decodable {
    let items: [AndroidSim]
    let sampledAt: String
    var isValid: Bool { items.allSatisfy { $0.subscriptionId >= 0 && $0.slotIndex >= 0 }
        && Set(items.map(\.subscriptionId)).count == items.count }
}
struct AndroidSim: Decodable, Identifiable {
    let subscriptionId: Int
    let slotIndex: Int
    let displayName: String
    let carrierName: String
    var id: Int { subscriptionId }
    var label: String { "SIM \(slotIndex + 1) · \(carrierName.isEmpty ? displayName : carrierName)" }
}

struct AndroidHistoryPage: Decodable {
    let items: [AndroidHistoryItem]
    let nextCursor: String?
    func isValid(sms: Bool) -> Bool {
        items.count <= 50 && Set(items.map(\.id)).count == items.count
            && items.allSatisfy { $0.isValid(sms: sms) }
            && (nextCursor == nil || Self.validID(nextCursor!))
    }
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber } && UInt64(value) != nil
    }
}
struct AndroidHistoryItem: Decodable, Identifiable {
    let id: String
    let number: String
    let timestamp: Int64
    let type: Int
    let text: String?
    let subscriptionId: Int?
    let durationSeconds: Int64?
    func isValid(sms: Bool) -> Bool {
        AndroidHistoryPage.validID(id) && timestamp >= 0
            && (sms ? text != nil && subscriptionId != nil : durationSeconds.map { $0 >= 0 } == true)
    }
    func typeLabel(sms: Bool) -> String {
        if sms {
            switch type {
            case 1: return "收到"
            case 2: return "已发送"
            case 3: return "草稿"
            case 4: return "发件箱"
            case 5: return "发送失败"
            case 6: return "待发送"
            default: return "其他短信"
            }
        }
        switch type {
        case 1: return "呼入"
        case 2: return "呼出"
        case 3: return "未接"
        case 4: return "语音信箱"
        case 5: return "已拒接"
        case 6: return "已拦截"
        default: return "其他通话"
        }
    }
}

struct AndroidOperation: Codable {
    let requestId: String
    let kind: String
    let status: String
    let message: String
    let updatedAt: String
    var isValid: Bool {
        UUID(uuidString: requestId)?.uuidString.lowercased() == requestId && ["sms", "call"].contains(kind)
            && ["submitting", "submitted", "sent", "failed", "unknown"].contains(status)
    }
    var title: String {
        switch status {
        case "submitting": "已记录操作，等待确认"
        case "submitted": kind == "sms" ? "已提交短信发送" : "已提交拨号"
        case "sent": "短信发送成功，未确认送达"
        case "failed": "操作失败"
        default: "结果未确认"
        }
    }
    var finished: Bool { status == "failed" || status == "sent" || (kind == "call" && status == "submitted") }
}

// Save identity before issuing an action. A timeout or reopening the page must
// lead to lookup of this ID, never an automatic resend with a new ID.
struct AndroidPendingOperation: Codable {
    let requestId: String
    let kind: String
    var result: AndroidOperation?
    init(kind: String) { self.kind = kind; requestId = UUID().uuidString.lowercased() }
    var isValid: Bool {
        UUID(uuidString: requestId)?.uuidString.lowercased() == requestId && ["sms", "call"].contains(kind)
            && (result == nil || (result!.isValid && result!.requestId == requestId && result!.kind == kind))
    }
}
