import SwiftUI

struct DeviceAndroidBatteryView: View {
    let entry: ConsoleCapabilityData?
    private var snapshot: AndroidBatterySnapshot? {
        guard entry?.version == 1, entry?.error == nil,
              let value = entry?.result?.decode(AndroidBatterySnapshot.self), value.isValid else { return nil }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("电池信息").font(.subheadline.weight(.semibold))
            if let value = snapshot {
                LabeledContent("状态", value: value.stateLabel)
                Divider()
                LabeledContent("供电方式", value: value.sourceLabel)
                Divider()
                LabeledContent("温度", value: value.temperatureCelsius.map { "\($0.formatted(.number.precision(.fractionLength(1)))) °C" } ?? "未提供")
                Divider()
                LabeledContent("电压", value: value.voltageVolts.map { "\($0.formatted(.number.precision(.fractionLength(2)))) V" } ?? "未提供")
                Divider()
                LabeledContent("瞬时电流", value: value.currentMilliamps.map { "\($0.formatted(.number.precision(.fractionLength(0)))) mA" } ?? "未提供")
                Text("正值表示流入电池，负值表示电池放电。").font(.caption).foregroundStyle(.secondary)
                Divider()
                LabeledContent("健康状态", value: value.healthLabel)
                Text("健康状态由系统报告，不代表剩余寿命百分比。").font(.caption).foregroundStyle(.secondary)
                Text("采样时间 · \(androidTimestamp(value.sampledAt))").font(.caption).foregroundStyle(.secondary)
            } else { AndroidEntryMessage(entry: entry) }
        }.font(.subheadline).devicePagePanel()
    }
}

struct DeviceAndroidWifiView: View {
    let entry: ConsoleCapabilityData?
    private var snapshot: AndroidWifiSnapshot? {
        guard entry?.version == 1, entry?.error == nil,
              let value = entry?.result?.decode(AndroidWifiSnapshot.self), value.isValid else { return nil }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wi-Fi 信息").font(.subheadline.weight(.semibold))
            if let value = snapshot {
                LabeledContent("连接状态", value: value.connected ? "已连接" : "未连接")
                if value.connected {
                    Divider()
                    LabeledContent("网络名称", value: value.nameLabel).textSelection(.enabled)
                    if let explanation = value.nameExplanation { Text(explanation).font(.caption).foregroundStyle(.secondary) }
                    Divider()
                    LabeledContent("信号强度", value: value.rssiDbm.map { "\($0) dBm" } ?? "未提供")
                    Divider()
                    LabeledContent("协商速率", value: value.linkSpeedMbps.map { "\($0) Mbps" } ?? "未提供")
                    Text("协商速率是手机与接入点的连接速率，不是实际下载速度。").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    LabeledContent("频率", value: value.frequencyMhz.map { "\($0) MHz" } ?? "未提供")
                    Divider()
                    LabeledContent("互联网验证", value: value.internetValidated ? "已通过" : "未通过")
                }
                Text("采样时间 · \(androidTimestamp(value.sampledAt))").font(.caption).foregroundStyle(.secondary)
            } else { AndroidEntryMessage(entry: entry) }
        }.font(.subheadline).devicePagePanel()
    }
}
