import SwiftUI

struct DeviceAndroidScreenView: View {
    let entry: ConsoleCapabilityData?
    var compact = false
    private var snapshot: AndroidScreenSnapshot? {
        guard entry?.version == 1, entry?.error == nil,
              let value = entry?.result?.decode(AndroidScreenSnapshot.self), value.isValid else { return nil }
        return value
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let value = snapshot {
                LabeledContent("屏幕状态", value: value.stateLabel)
                if !compact {
                    LabeledContent("设备交互状态", value: value.interactive ? "可交互" : "不可交互")
                    Text("采样时间 · \(androidTimestamp(value.sampledAt))").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("屏幕状态", value: entry == nil ? "等待数据" : "暂不可用")
                if let error = entry?.error { Text(error.localizedDescription).font(.caption).foregroundStyle(.red) }
            }
        }.font(.subheadline)
    }
}
