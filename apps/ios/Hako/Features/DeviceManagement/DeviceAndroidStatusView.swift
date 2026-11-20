import SwiftUI

extension ConsoleCapabilityData {
    var androidStatus: AndroidDeviceStatus? {
        guard version == 1, error == nil, let value = result?.decode(AndroidDeviceStatus.self), value.isValid else { return nil }
        return value
    }
    var androidSims: AndroidSimSnapshot? {
        guard version == 1, error == nil, let value = result?.decode(AndroidSimSnapshot.self), value.isValid else { return nil }
        return value
    }
}

struct DeviceAndroidStatusView: View {
    let entry: ConsoleCapabilityData?
    let storageEntry: ConsoleCapabilityData?
    let showsStorage: Bool
    let batteryEntry: ConsoleCapabilityData?
    let wifiEntry: ConsoleCapabilityData?
    let showsBattery: Bool
    let showsWifi: Bool
    let screenEntry: ConsoleCapabilityData?
    let showsScreen: Bool
    @State private var showingPermissions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let status = entry?.androidStatus {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), alignment: .top)], spacing: 12) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("电池电量").font(.subheadline).foregroundStyle(.secondary)
                        Text(status.batteryPercent < 0 ? "—" : "\(status.batteryPercent)%")
                            .font(.largeTitle.weight(.semibold)).monospacedDigit()
                        ProgressView(value: Double(max(0, status.batteryPercent)), total: 100).tint(.green)
                        Text(status.charging ? "正在充电" : "未充电").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).devicePagePanel()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("可用内存").font(.subheadline).foregroundStyle(.secondary)
                        Text(bytes(status.memoryAvailableBytes)).font(.title.weight(.semibold)).monospacedDigit()
                            .minimumScaleFactor(0.75).lineLimit(1)
                        ProgressView(value: Double(status.memoryAvailableBytes), total: Double(status.memoryTotalBytes))
                            .tint(.secondary)
                        Text("共 \(bytes(status.memoryTotalBytes))").font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).devicePagePanel()
                }
                if showsStorage { DeviceAndroidStorageView(entry: storageEntry) }
                VStack(alignment: .leading, spacing: 12) {
                    Text("设备信息").font(.subheadline.weight(.semibold))
                    LabeledContent("型号", value: "\(status.manufacturer) · \(status.model)")
                    Divider()
                    LabeledContent("系统", value: "Android \(status.androidVersion) · SDK \(status.sdk)")
                    Divider()
                    LabeledContent("Agent 版本", value: status.appVersion)
                    Divider()
                    LabeledContent("网络", value: status.networkLabel)
                    if showsScreen {
                        Divider()
                        DeviceAndroidScreenView(entry: screenEntry, compact: true)
                    }
                    Divider()
                    LabeledContent("开机时长", value: status.uptimeLabel)
                }.font(.subheadline).devicePagePanel()
                if showsBattery { DeviceAndroidBatteryView(entry: batteryEntry) }
                if showsWifi { DeviceAndroidWifiView(entry: wifiEntry) }
                VStack(alignment: .leading, spacing: 12) {
                    Text("权限与远程操作").font(.subheadline.weight(.semibold))
                    Button { showingPermissions = true } label: {
                        HStack {
                            Text("系统权限").foregroundStyle(.primary)
                            Spacer()
                            let count = AndroidDeviceStatus.permissionLabels.filter { status.permissions[$0.0] == true }.count
                            Text("\(count) / 5 已授权").foregroundStyle(count == 5 ? Color.green : Color.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.frame(minHeight: 32)
                    }.buttonStyle(.plain)
                    Divider()
                    LabeledContent("远程短信") { permission(status.allowSms) }
                    Divider()
                    LabeledContent("远程拨号") { permission(status.allowCalls) }
                }.font(.subheadline).devicePagePanel()
                Text("采样时间 · \(androidTimestamp(status.sampledAt))").font(.caption).foregroundStyle(.secondary)
            } else { AndroidEntryMessage(entry: entry) }
        }
        .sheet(isPresented: $showingPermissions) {
            SettingsSheet(title: "系统权限") {
                Form {
                    if let status = entry?.androidStatus {
                        Section {
                            ForEach(AndroidDeviceStatus.permissionLabels, id: \.0) { key, label in
                                LabeledContent(label) {
                                    if let granted = status.permissions[key] { permission(granted, authorized: true) }
                                    else { Text("未提供").foregroundStyle(.secondary) }
                                }
                            }
                        } footer: {
                            Text("权限由 Android 系统管理，请在 Android 手机上的应用权限设置中更改。")
                        }
                    }
                }
            }
        }
    }
    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .memory)
    }
    private func permission(_ enabled: Bool, authorized: Bool = false) -> some View {
        Text(enabled ? (authorized ? "已授权" : "已允许") : (authorized ? "未授权" : "未允许"))
            .foregroundStyle(enabled ? Color.green : Color.secondary)
    }
}

struct DeviceAndroidStorageView: View {
    let entry: ConsoleCapabilityData?
    private var snapshot: AndroidStorageSnapshot? {
        guard entry?.version == 1, entry?.error == nil,
              let value = entry?.result?.decode(AndroidStorageSnapshot.self), value.isValid else { return nil }
        return value
    }
    var body: some View {
        if let snapshot {
            VStack(alignment: .leading, spacing: 10) {
                Text("可用存储").font(.subheadline).foregroundStyle(.secondary)
                Text(bytes(snapshot.storageAvailableBytes)).font(.title.weight(.semibold)).monospacedDigit()
                ProgressView(value: Double(snapshot.storageAvailableBytes), total: Double(snapshot.storageTotalBytes))
                    .tint(.secondary)
                Text("共 \(bytes(snapshot.storageTotalBytes)) · 内部数据分区").font(.caption).foregroundStyle(.secondary)
                Text("采样时间 · \(androidTimestamp(snapshot.sampledAt))").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).devicePagePanel()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("可用存储").font(.subheadline)
                AndroidEntryMessage(entry: entry)
            }
        }
    }
    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(value, UInt64(Int64.max))), countStyle: .file)
    }
}

struct DeviceAndroidSimsView: View {
    let entry: ConsoleCapabilityData?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let snapshot = entry?.androidSims {
                if snapshot.items.isEmpty { Text("未发现可用 SIM 卡").foregroundStyle(.secondary).devicePagePanel() }
                ForEach(snapshot.items) { sim in
                    VStack(alignment: .leading, spacing: 12) {
                        Label("SIM \(sim.slotIndex + 1)", systemImage: "simcard").font(.headline)
                        LabeledContent("运营商", value: sim.carrierName.isEmpty ? "未提供" : sim.carrierName)
                        Divider()
                        LabeledContent("名称", value: sim.displayName.isEmpty ? "未提供" : sim.displayName)
                        Divider()
                        LabeledContent("订阅 ID", value: String(sim.subscriptionId))
                    }.font(.subheadline).devicePagePanel()
                }
                Text("采样时间 · \(androidTimestamp(snapshot.sampledAt))").font(.caption).foregroundStyle(.secondary)
            } else { AndroidEntryMessage(entry: entry) }
        }
    }
}

struct AndroidEntryMessage: View {
    let entry: ConsoleCapabilityData?
    var body: some View {
        Group {
            if let error = entry?.error { Text(error.localizedDescription).foregroundStyle(.red) }
            else { Text(entry == nil ? "等待查询数据" : "设备返回的数据格式无效，请刷新后重试。").foregroundStyle(.secondary) }
        }.font(.footnote).devicePagePanel()
    }
}
func androidTimestamp(_ value: String) -> String {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else { return value }
    return date.formatted(date: .numeric, time: .standard)
}
