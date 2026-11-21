import SwiftUI
import UniformTypeIdentifiers

struct DeviceKageAndroidView: View {
    let agent: ConsoleAgent
    let entry: ConsoleCapabilityData?
    @StateObject private var store: KageAndroidStore
    @State private var selected: KageAndroidDevice?
    @State private var adding = false
    init(agent: ConsoleAgent, entry: ConsoleCapabilityData?) {
        self.agent = agent; self.entry = entry
        _store = StateObject(wrappedValue: KageAndroidStore.session(agent))
    }
    private var snapshot: KageAndroidInventory? {
        guard entry?.version == 1, entry?.error == nil else { return nil }
        return entry?.result?.decode(KageAndroidInventory.self)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Android 设备").font(.headline)
                Spacer()
                Button { adding = true } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("添加 Android 设备").disabled(!store.computerOnline || !store.canRequest)
            }
            if !store.computerOnline { androidNotice("管理电脑离线", "当前显示上次读取的数据，远程操作暂不可用。") }
            if store.inventory?.adbAvailable == false {
                VStack(alignment: .leading, spacing: 12) {
                    Text("工作站尚未配置 ADB").font(.subheadline.weight(.semibold))
                    Text("下载 Google 官方平台工具后，即可发现 USB 和无线调试设备。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("下载官方 ADB 工具") { Task { _ = await store.submit("tools") } }
                        .buttonStyle(HakoActionButtonStyle()).disabled(store.submitting || !store.computerOnline)
                }.devicePagePanel()
            }
            ForEach(store.inventory?.devices ?? []) { device in
                Button { selected = device } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(device.name).font(.title3.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        Text("Android \(device.androidVersion ?? "—") · \(device.connection?.label ?? "未连接")")
                            .font(.caption).foregroundStyle(.secondary)
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 7) { badges(device) }
                            VStack(alignment: .leading, spacing: 7) { badges(device) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).devicePagePanel()
                }.buttonStyle(.plain)
            }
            if store.inventory?.devices.isEmpty == true, store.inventory?.adbAvailable == true {
                Text("尚未发现 Android 设备。连接 USB 并在手机上授权，或点击加号进行无线配对。")
                    .font(.subheadline).foregroundStyle(.secondary).devicePagePanel()
            }
            if let operation = store.operations.first, operation.deviceId == "computer" {
                AndroidTaskRow(operation: operation) { Task { await store.check(operation.id) } }.devicePagePanel()
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            Text("点按设备查看 Android 数据与控制选项。").font(.caption).foregroundStyle(.secondary)
            Button { Task { await store.refresh() } } label: {
                Text(store.loading ? "正在刷新…" : "刷新设备列表").frame(maxWidth: .infinity)
            }.buttonStyle(HakoActionButtonStyle(primary: false)).disabled(store.loading || !store.computerOnline)
        }
        .task { store.accept(snapshot); await store.refresh() }
        .onChange(of: snapshot?.sampledAt) { _, _ in store.accept(snapshot) }
        .sheet(item: $selected) { device in
            SettingsSheet(title: device.name) { KageAndroidDeviceSheet(store: store, original: device) }
        }
        .sheet(isPresented: $adding) {
            SettingsSheet(title: "添加 Android 连接") { AndroidPairSheet(store: store) }
        }
    }
    @ViewBuilder private func badges(_ device: KageAndroidDevice) -> some View {
        AndroidBadge(text: device.stateLabel, good: device.available && store.computerOnline)
        AndroidBadge(text: store.namiLabel(device), good: store.namiLabel(device) == "Nami 在线")
    }
}

private struct AndroidBadge: View {
    let text: String
    var good = false
    var body: some View {
        Text(text).font(.caption2).foregroundStyle(good ? Color.green : Color.secondary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background((good ? Color.green : Color.secondary).opacity(0.1), in: Capsule())
    }
}
private func androidNotice(_ title: String, _ message: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.subheadline.weight(.medium))
        Text(message).font(.caption)
    }.frame(maxWidth: .infinity, alignment: .leading).padding(13)
        .foregroundStyle(.orange).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
}

private struct KageAndroidDeviceSheet: View {
    enum Page: String, CaseIterable { case overview = "概览", control = "控制", maintenance = "维护", records = "记录" }
    @ObservedObject var store: KageAndroidStore
    let original: KageAndroidDevice
    @ObservedObject private var client = DeviceMonitorClient.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = Page.overview
    @State private var live = false
    @State private var serial: String?
    @State private var confirmOperation: String?
    @State private var importing = false
    @State private var importURL: URL?
    @State private var showingConnections = false
    @State private var showingAssociation = false
    @State private var showingTask: KageAndroidOperation?
    @State private var logText: String?
    private var device: KageAndroidDevice { store.current(original) }
    private var detail: KageAndroidDetail? { store.details[device.id] }
    private var available: Bool { store.canControl(device) && !store.submitting && store.uploadProgress == nil }
    private var task: KageAndroidOperation? { store.operations.first { $0.deviceId == device.id } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("\(device.model ?? device.name) · Android \(device.androidVersion ?? "—")").font(.subheadline.weight(.semibold))
                        Spacer()
                        AndroidBadge(text: store.canControl(device) ? "可控制" : "不可控制", good: store.canControl(device))
                    }
                    Text("\(device.connection?.label ?? "未连接") · \(device.connection?.serial ?? "—")")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack(spacing: 7) {
                        AndroidBadge(text: device.stateLabel, good: store.canControl(device))
                        AndroidBadge(text: store.namiLabel(device), good: store.namiLabel(device) == "Nami 在线")
                    }
                    HStack {
                        Text(detail.map { "采样 · " + androidTimestamp($0.sampledAt) } ?? "等待数据")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button { live.toggle() } label: {
                            Label("实时刷新", systemImage: live ? "checkmark.square.fill" : "square")
                                .font(.caption).frame(minHeight: 44)
                        }.buttonStyle(.plain).disabled(!store.canControl(device))
                    }
                }
                HStack(spacing: 0) {
                    ForEach(Page.allCases, id: \.self) { item in
                        Button { page = item } label: {
                            Text(item.rawValue).font(.subheadline.weight(page == item ? .semibold : .regular))
                                .foregroundStyle(page == item ? HakoStyle.text : HakoStyle.muted)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .overlay(alignment: .bottom) { if page == item { Rectangle().frame(height: 2).padding(.horizontal, 10) } }
                        }.buttonStyle(.plain).accessibilityAddTraits(page == item ? .isSelected : [])
                    }
                }.overlay(alignment: .bottom) { Rectangle().fill(HakoStyle.line).frame(height: 0.5) }
                if !store.canControl(device) {
                    androidNotice(store.computerOnline ? device.stateLabel : "管理电脑离线", "请检查工作站、数据线或无线调试。手机需要单独允许电脑调试；已读取的数据会保留。")
                }
                switch page {
                case .overview: overview
                case .control: control
                case .maintenance: maintenance
                case .records: records
                }
                if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            }.padding(20)
        }
        .background(HakoStyle.background).foregroundStyle(HakoStyle.text)
        .refreshable { await refresh() }
        .task { await refresh() }
        .task(id: live && scenePhase == .active) {
            guard live, scenePhase == .active else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
        .onChange(of: page) { _, next in if next == .records { Task { await store.loadOperations(device) } } }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmOperation != nil }, set: { if !$0 { confirmOperation = nil } }), titleVisibility: .visible) {
            let operation = confirmOperation ?? "start"
            Button(confirmTitle, role: operation == "restart" || operation == "sleep" ? .destructive : nil) {
                confirmOperation = nil
                Task { if let value = await store.submit(operation, device: device, serial: serial) { showingTask = value } }
            }
            Button("取消", role: .cancel) { confirmOperation = nil }
        } message: { Text("目标：\(device.name)；执行电脑：\(store.agent.name)。重新启动可能中断当前任务，亮屏不会解除锁屏。") }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data]) { result in
            switch result { case .success(let url): importURL = url; case .failure(let error): store.error = error.localizedDescription }
        }
        .alert("确认覆盖安装 Nami？", isPresented: Binding(get: { importURL != nil }, set: { if !$0 { importURL = nil } })) {
            Button("取消", role: .cancel) { importURL = nil }
            Button("上传并覆盖安装") { if let url = importURL { store.upload(url, device: device, serial: serial) }; importURL = nil }
        } message: { Text("\(importURL?.lastPathComponent ?? "APK")\n上传至工作站后检查包名和版本，签名由 Android 安装器校验。保留数据，不自动卸载或降级。") }
        .sheet(isPresented: $showingConnections) {
            SettingsSheet(title: "管理连接") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(device.connections) { connection in
                            Button { serial = connection.serial; showingConnections = false } label: {
                                HStack { VStack(alignment: .leading, spacing: 5) {
                                    Text(connection.label).font(.headline)
                                    Text(connection.serial).font(.caption).foregroundStyle(.secondary)
                                }; Spacer(); Text(connection.state == "device" ? "已连接" : "不可用").font(.caption) }
                                .devicePagePanel()
                            }.buttonStyle(.plain).disabled(!connection.available)
                        }
                        Text("只在操作前选择连接，执行中断开时不切换连接重复执行。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(20)
                }.background(HakoStyle.background)
            }
        }
        .sheet(isPresented: $showingAssociation) {
            SettingsSheet(title: "关联 Nami Agent") {
                List {
                    ForEach(client.agents.filter { $0.capabilities?.contains { $0.name == AndroidDeviceCommand.status } == true }) { agent in
                        Button {
                            Task { _ = await store.submit("associate", device: device, extra: ["agentId": agent.id]); await store.refresh(); showingAssociation = false }
                        } label: { VStack(alignment: .leading, spacing: 5) {
                            Text(agent.name); Text(agent.id).font(.caption).foregroundStyle(.secondary)
                        } }.disabled(store.submitting)
                    }
                    Text("关联保存在工作站，Nami 离线时仍可保留。关联不授予 ADB 权限。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(item: $showingTask) { operation in SettingsSheet(title: operation.title) { AndroidOperationSheet(store: store, id: operation.id) } }
        .sheet(isPresented: Binding(get: { logText != nil }, set: { if !$0 { logText = nil } })) {
            SettingsSheet(title: "Nami 近期日志") { ScrollView { Text(logText ?? "").font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20) }.background(HakoStyle.background) }
        }
    }
    private var confirmTitle: String {
        switch confirmOperation { case "restart": "重新启动 Nami"; case "sleep": "将手机熄屏"; default: "启动 Nami" }
    }
    private func refresh() async { await store.refresh(); await store.refreshDetail(device, serial: serial); await store.loadOperations(device) }
    private func bytes(_ value: Int64?) -> String { value.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .binary) } ?? "暂不可用" }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("设备信息").font(.headline)
            VStack(spacing: 12) {
                LabeledContent("型号", value: device.model ?? "暂不可用")
                LabeledContent("系统", value: "Android " + (device.androidVersion ?? "—"))
                LabeledContent("可用内存", value: bytes(detail?.memoryAvailableBytes) + " / " + bytes(detail?.memoryTotalBytes))
                LabeledContent("可用存储", value: bytes(detail?.storageAvailableBytes) + " / " + bytes(detail?.storageTotalBytes))
                LabeledContent("开机时长", value: detail?.uptimeSeconds.map { "\(Int($0) / 3600) 小时 \(Int($0) % 3600 / 60) 分钟" } ?? "暂不可用")
                LabeledContent("屏幕状态", value: detail?.screenLabel ?? "暂不可用")
                LabeledContent("电池电量", value: detail?.batteryPercent.map { "\($0)%" } ?? "暂不可用")
                LabeledContent("充电状态", value: detail?.charging.map { $0 ? "正在充电" : "未充电" } ?? "暂不可用")
            }.font(.subheadline).devicePagePanel()
            Text("管理连接").font(.headline)
            VStack(spacing: 0) {
                row(device.connection?.label ?? "未连接", note: serial ?? device.connection?.serial ?? "", action: { showingConnections = true })
                Divider()
                row("关联 Nami", note: device.agentId ?? "尚未关联 Agent", action: { showingAssociation = true })
            }.devicePagePanel()
        }
    }
    private var control: some View {
        VStack(alignment: .leading, spacing: 14) {
            AndroidLiveScreenView(agent: store.agent, device: device, serial: serial, available: store.canControl(device))
            VStack(alignment: .leading, spacing: 17) {
                Text("当前屏幕状态").font(.caption).foregroundStyle(.secondary)
                Text(detail?.screenLabel ?? "未知").font(.title.weight(.medium))
                HStack(spacing: 8) {
                    Button("亮屏") { Task { if let op = await store.submit("wake", device: device, serial: serial) { showingTask = op } } }.buttonStyle(HakoActionButtonStyle())
                    Button("熄屏") { confirmOperation = "sleep" }.buttonStyle(HakoActionButtonStyle(primary: false))
                    Button("截图") { Task { if let op = await store.submit("screenshot", device: device, serial: serial) { showingTask = op } } }.buttonStyle(HakoActionButtonStyle(primary: false))
                }.disabled(!available)
            }.devicePagePanel()
            Text("亮屏不会解除锁屏。部分小米设备需要允许「USB 调试（安全设置）」。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var maintenance: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let task { AndroidTaskRow(operation: task) { showingTask = task }.devicePagePanel() }
            if let progress = store.uploadProgress { VStack(alignment: .leading) { Text("正在上传 APK 到工作站…").font(.subheadline); ProgressView(value: progress) }.devicePagePanel() }
            if let id = store.pending.first(where: { $0.value == device.id })?.key, !store.operations.contains(where: { $0.id == id }) {
                Button("查询原操作结果（\(id)）") { Task { await store.check(id) } }.font(.caption).buttonStyle(HakoActionButtonStyle(primary: false))
            }
            HStack { Text("Nami").font(.headline); Spacer(); AndroidBadge(text: store.namiLabel(device), good: store.namiLabel(device) == "Nami 在线") }
            VStack(spacing: 13) {
                LabeledContent("已安装版本", value: detail?.namiVersion ?? "未确认")
                LabeledContent("应用进程", value: detail.map { $0.processRunning ? "运行中" : "未运行" } ?? "未确认")
                LabeledContent("关联 Agent", value: device.agentId ?? "未关联")
                Button("启动 Nami") { confirmOperation = "start" }.buttonStyle(HakoActionButtonStyle()).disabled(!available)
                Button("重新启动 Nami") { confirmOperation = "restart" }.buttonStyle(HakoActionButtonStyle(primary: false)).disabled(!available)
            }.font(.subheadline).devicePagePanel()
            VStack(spacing: 0) {
                row("覆盖安装", note: "选择 APK，保留应用数据", action: { importing = true }).disabled(!available)
                Divider()
                row("查看运行日志", note: "读取近期 Nami 日志", action: { Task { logText = await store.logs(device, serial: serial) } }).disabled(!available)
            }.devicePagePanel()
            Text("操作由工作站执行。收起此页不会终止已提交的任务；应用进程运行与 Agent 在线分别确认。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var records: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("最近操作").font(.headline)
            ForEach(store.operations.filter { $0.deviceId == device.id }) { operation in
                AndroidTaskRow(operation: operation) { showingTask = operation }.devicePagePanel()
            }
            if store.operations.filter({ $0.deviceId == device.id }).isEmpty { Text("暂无操作记录").foregroundStyle(.secondary) }
            Text("等待超时不代表未执行。按原操作编号查询结果，不自动重复提交。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func row(_ title: String, note: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack { VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.medium))
                Text(note).font(.caption).foregroundStyle(.secondary)
            }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct AndroidTaskRow: View {
    let operation: KageAndroidOperation
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: operation.active ? "clock" : operation.status == "completed" ? "checkmark.circle" : "exclamationmark.circle")
                VStack(alignment: .leading, spacing: 5) {
                    Text(operation.title).font(.subheadline.weight(.medium))
                    Text(operation.statusLabel + " · " + operation.message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
private struct AndroidOperationSheet: View {
    @ObservedObject var store: KageAndroidStore
    let id: String
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let operation = store.operations.first(where: { $0.id == id }) {
                    Text(operation.statusLabel).font(.title2.weight(.semibold))
                    Text(operation.message).font(.subheadline)
                    if operation.hasScreenshot { AndroidScreenshotView(store: store, id: id) }
                    VStack(alignment: .leading, spacing: 15) {
                        step("Kage 已收到指令", done: true)
                        step(operation.kind == "install" ? "Android 安装器校验并覆盖安装" : "在手机上执行操作",
                             done: ["verifying", "verified", "process_verified"].contains(operation.phase))
                        step(operation.kind == "screenshot" ? "截图已保存到工作站" : "回查手机实际状态", done: operation.status == "completed")
                        if ["start", "restart", "install"].contains(operation.kind),
                           let device = store.inventory?.devices.first(where: { $0.id == operation.deviceId }) {
                            step(store.namiLabel(device), done: store.namiLabel(device) == "Nami 在线")
                        }
                    }.devicePagePanel()
                    Text("操作编号 · " + id).font(.caption.monospaced()).textSelection(.enabled)
                    Text("由工作站执行。可关闭此页，稍后从维护页或操作记录查看结果。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("查询原操作结果") { Task { await store.check(id) } }.buttonStyle(HakoActionButtonStyle())
                if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }.padding(20)
        }.background(HakoStyle.background)
        .task(id: id) { await store.check(id) }
    }
    private func step(_ title: String, done: Bool) -> some View {
        Label(title, systemImage: done ? "checkmark.circle.fill" : "circle")
            .font(.subheadline).foregroundStyle(done ? HakoStyle.text : HakoStyle.muted)
    }
}

private struct AndroidScreenshotView: View {
    @ObservedObject var store: KageAndroidStore
    let id: String
    @State private var showingPreview = false
    private var data: Data? { store.screenshots[id] ?? store.screenshotPreviews[id] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let data, let image = UIImage(data: data) {
                Button { showingPreview = true } label: {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 460).frame(maxWidth: .infinity)
                }.buttonStyle(.plain).accessibilityLabel("查看屏幕截图，可放大")
                Text("轻点图片可放大预览。").font(.caption).foregroundStyle(.secondary)
                Button(store.screenshots[id] == nil ? "查看原图" : "查看大图") {
                    Task { await store.loadOriginalScreenshot(id); if store.screenshots[id] != nil { showingPreview = true } }
                }.buttonStyle(HakoActionButtonStyle(primary: false))
                    .disabled(store.screenshotProgress[id] != nil || (store.screenshots[id] == nil && (!store.canRequest || !store.computerOnline)))
            } else if store.screenshotPreviewLoading.contains(id) {
                ProgressView("正在读取截图预览")
            }
            if let progress = store.screenshotProgress[id] {
                Text("正在读取原图 · \(Int(progress * 100))%").font(.subheadline)
                ProgressView(value: progress)
            }
            if let error = store.screenshotErrors[id] { Text(error).font(.caption).foregroundStyle(.orange) }
            if data == nil, !store.screenshotPreviewLoading.contains(id) {
                Button("重新读取截图") { Task { await store.loadScreenshot(id, reload: true) } }
                    .buttonStyle(HakoActionButtonStyle(primary: false)).disabled(!store.canRequest || !store.computerOnline)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).devicePagePanel()
        .task(id: id) { await store.loadScreenshot(id) }
        .sheet(isPresented: $showingPreview) {
            if let data { AssistantPhotoPreview(images: [data], selection: 0) }
        }
    }
}

private struct AndroidPairSheet: View {
    @ObservedObject var store: KageAndroidStore
    @State private var ip = ""
    @State private var port = ""
    @State private var code = ""
    @State private var connectPort = ""
    @State private var pairId: String?
    private var pair: KageAndroidOperation? { store.operations.first { $0.id == pairId } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("USB 连接").font(.headline)
                Text("将手机连接到工作站，开启 USB 调试并在手机上允许电脑。返回后刷新设备列表即可发现。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("无线调试配对").font(.headline)
                Text("手机与工作站连接同一 Wi-Fi，在手机的无线调试设置中打开配对码窗口。")
                    .font(.caption).foregroundStyle(.secondary)
                field("手机 IP", text: $ip, placeholder: "192.168.0.9")
                if pair?.status == "completed" {
                    Text("配对成功。连接端口与配对端口不同，请填写无线调试主页面上的连接端口。")
                        .font(.caption).foregroundStyle(.secondary)
                    field("连接端口", text: $connectPort, placeholder: "37895")
                    Button("通过工作站连接") { Task { _ = await store.submit("connect", extra: ["address": ip + ":" + connectPort]); await store.refresh() } }
                        .buttonStyle(HakoActionButtonStyle()).disabled(!validPort(connectPort) || store.submitting)
                } else {
                    field("配对端口", text: $port, placeholder: "37123")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("6 位配对码").font(.subheadline).foregroundStyle(.secondary)
                        SecureField("输入手机显示的配对码", text: $code).keyboardType(.numberPad).textFieldStyle(.roundedBorder).accessibilityLabel("6 位配对码")
                    }
                    Button("通过工作站配对") { Task { pairId = await store.submit("pair", extra: ["address": ip + ":" + port, "code": code])?.id; code = "" } }
                        .buttonStyle(HakoActionButtonStyle()).disabled(store.submitting || !validPort(port) || code.count != 6 || code.contains { !$0.isASCII || !$0.isNumber } || ip.isEmpty || pair?.active == true)
                }
                if let pair { Text(pair.statusLabel + " · " + pair.message).font(.caption).foregroundStyle(.secondary) }
                if let error = store.error { Text(error).font(.caption).foregroundStyle(.orange) }
                Text("配对密钥保存在工作站，Hako 仅转发本次请求。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }.background(HakoStyle.background)
    }
    private func validPort(_ value: String) -> Bool { Int(value).map { (1...65535).contains($0) } ?? false }
    private func field(_ name: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.subheadline).foregroundStyle(.secondary)
            TextField(placeholder, text: text).keyboardType(.decimalPad).textInputAutocapitalization(.never).autocorrectionDisabled().textFieldStyle(.roundedBorder).accessibilityLabel(name)
        }
    }
}
