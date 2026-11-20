import SwiftUI

struct DeviceAndroidTelephonyView: View {
    let agent: ConsoleAgent
    let sms: Bool
    @ObservedObject private var client = DeviceMonitorClient.shared
    @AppStorage private var operationData: Data
    @State private var number = ""
    @State private var message = ""
    @State private var subscription = -1
    @State private var confirming = false
    @State private var working = false
    @State private var lookingUp = false
    @State private var actionError: String?
    @State private var inputError: String?
    @State private var historyError: String?
    @State private var records: [AndroidHistoryItem] = []
    @State private var nextCursor: String?
    @State private var queried = false
    @State private var loading = false
    @State private var pageSize = 20

    init(agent: ConsoleAgent, sms: Bool) {
        self.agent = agent; self.sms = sms
        let client = DeviceMonitorClient.shared
        let key = DeviceCardOrder.storageKey(server: client.serverURL, account: client.username,
            agent: agent.id, group: sms ? "android-sms-operation" : "android-call-operation")
        _operationData = AppStorage(wrappedValue: Data(), key)
    }
    private var kind: String { sms ? "sms" : "call" }
    private var queryCommand: String { sms ? AndroidDeviceCommand.messages : AndroidDeviceCommand.calls }
    private var actionCommand: String { sms ? AndroidDeviceCommand.send : AndroidDeviceCommand.call }
    private func supports(_ name: String) -> Bool {
        agent.capabilities?.contains { $0.name == name && $0.version == 1 } == true
    }
    private var status: AndroidDeviceStatus? { client.deviceData[agent.id]?.entries[AndroidDeviceCommand.status]?.androidStatus }
    private var sims: [AndroidSim] { client.deviceData[agent.id]?.entries[AndroidDeviceCommand.sims]?.androidSims?.items ?? [] }
    private var pending: AndroidPendingOperation? {
        guard let value = try? JSONDecoder().decode(AndroidPendingOperation.self, from: operationData), value.isValid,
              value.kind == kind else { return nil }
        return value
    }
    private var blockedByPending: Bool { pending != nil && pending?.result?.finished != true }
    private var allowed: Bool {
        guard let status else { return true }
        return sms ? status.allowSms && status.permissions["sendSms"] != false
            : status.allowCalls && status.permissions["callPhone"] != false
    }
    private var validInput: Bool {
        AndroidDeviceCommand.validNumber(number.trimmingCharacters(in: .whitespacesAndNewlines))
            && (!sms || (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.utf16.count <= 4000))
            && (!sms || subscription == -1 || sims.contains { $0.subscriptionId == subscription })
    }
    private var canPreview: Bool { agent.online && client.authenticated && !client.logoutPending
        && allowed && !working && !lookingUp && !blockedByPending && operationData.isEmpty }
    private var canSubmit: Bool { canPreview && validInput }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if supports(actionCommand) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(sms ? "发送短信" : "呼出电话").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 8)
                    if status != nil {
                        Text((sms ? "远程短信" : "远程拨号") + (allowed ? "已允许" : "未允许"))
                            .font(.caption).foregroundStyle(allowed ? Color.green : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                actionForm
            }
            if !operationData.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    if let pending {
                        AndroidOperationReceipt(operation: pending.result, requestId: pending.requestId)
                        if supports(AndroidDeviceCommand.operation) {
                            Button(lookingUp ? "查询中…" : "查询操作结果") { Task { await lookup() } }
                                .buttonStyle(HakoActionButtonStyle(primary: false)).disabled(lookingUp || working || !agent.online)
                        }
                        if pending.result?.finished == true {
                            Button("开始新操作") { operationData = Data(); actionError = nil }
                                .buttonStyle(HakoActionButtonStyle(primary: false)).disabled(working || lookingUp)
                        } else {
                            Text("上次操作尚未确认，请先查询结果，不要重复提交。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("已保存的操作记录无法读取，请保留记录并在 Android 手机上核对，暂不重复提交。")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }.devicePagePanel()
            }
            if let actionError { Text(actionError).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
            if supports(queryCommand) { history }
        }
        .onChange(of: number) { _, _ in inputError = nil }
        .onChange(of: message) { _, _ in inputError = nil }
        .onChange(of: subscription) { _, _ in inputError = nil }
        .sheet(isPresented: $confirming) {
            SettingsSheet(title: sms ? "确认发送短信" : "确认呼出电话", isBusy: working) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        LabeledContent("操作设备", value: agent.name)
                        LabeledContent(sms ? "收件号码" : "呼叫号码", value: number.trimmingCharacters(in: .whitespacesAndNewlines))
                        if sms {
                            LabeledContent("发送 SIM 卡", value: sims.first { $0.subscriptionId == subscription }?.label ?? "系统默认短信卡")
                            Text("短信内容").font(.subheadline).foregroundStyle(.secondary)
                            Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).devicePagePanel()
                        }
                        Text(sms ? "将通过 Android 手机的 SIM 卡发送短信，资费以运营商为准。" : "将通过 Android 手机发起呼叫，提交不代表对方已接通。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if !allowed || !agent.online { Text("设备离线或未允许此操作，请先检查 Android 手机。").foregroundStyle(.red) }
                        Button(working ? "提交中…" : (sms ? "确认发送短信" : "确认呼出电话")) { Task { await execute() } }
                            .buttonStyle(HakoActionButtonStyle()).disabled(!canSubmit)
                    }.padding(20)
                }.background(HakoStyle.background)
            }
        }
    }

    private var actionForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(sms ? "收件号码" : "呼叫号码").font(.subheadline).foregroundStyle(.secondary)
                TextField("输入电话号码", text: $number).keyboardType(.phonePad)
                    .textContentType(.telephoneNumber).accessibilityLabel(sms ? "收件号码" : "呼叫号码")
                    .androidTelephonyField()
            }
            if sms {
                VStack(alignment: .leading, spacing: 6) {
                    Text("发送 SIM 卡").font(.subheadline).foregroundStyle(.secondary)
                    Menu {
                        Button("系统默认短信卡") { subscription = -1 }
                        ForEach(sims) { sim in Button(sim.label) { subscription = sim.subscriptionId } }
                    } label: {
                        HStack(spacing: 8) {
                            Text(sims.first { $0.subscriptionId == subscription }?.label ?? "系统默认短信卡")
                                .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.down").font(.caption).foregroundStyle(.secondary)
                        }.androidTelephonyField()
                    }.buttonStyle(.plain).accessibilityLabel("发送 SIM 卡")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("短信内容").font(.subheadline).foregroundStyle(.secondary)
                    TextField("输入短信内容", text: $message, axis: .vertical).lineLimit(4...6)
                        .accessibilityLabel("短信内容").androidTelephonyField()
                    if message.utf16.count > 4000 {
                        Text("短信内容过长，请缩短后发送。").font(.caption).foregroundStyle(.red)
                    }
                }
                Text("使用 \(agent.name) 的 SIM 卡发送，资费以运营商为准。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("通过 \(agent.name) 发起呼叫，使用手机的系统通话账户。手机可能显示 SIM 卡选择或系统确认。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !allowed {
                Text("请在 Android 手机上授予系统权限，并开启对应的远程操作开关。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let inputError { Text(inputError).font(.footnote).foregroundStyle(.red) }
            Button(sms ? "预览发送" : "预览呼叫", action: preview)
                .buttonStyle(HakoActionButtonStyle()).disabled(!canPreview)
        }.disabled(working || blockedByPending).padding(3).devicePagePanel()
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(sms ? "短信记录" : "通话记录").font(.headline)
                Spacer()
                Menu {
                    ForEach([5, 10, 20, 50], id: \.self) { size in
                        Button("每页 \(size) 条") { pageSize = size }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text("每页 \(pageSize) 条")
                        Image(systemName: "chevron.down")
                    }.font(.caption).foregroundStyle(.secondary).frame(minHeight: 44)
                }.disabled(loading).accessibilityLabel("每页条数")
            }
            Text(queried ? "按需读取手机上的历史记录。" : "尚未查询\(sms ? "短信" : "通话") · 历史记录按需读取")
                .font(.caption).foregroundStyle(.secondary)
            Button(loading ? "查询中…" : (queried ? "刷新记录" : "查询记录")) { Task { await loadHistory(reset: true) } }
                .buttonStyle(HakoActionButtonStyle(primary: false)).disabled(loading || !agent.online)
            if let historyError { Text(historyError).font(.footnote).foregroundStyle(.red) }
            if queried && records.isEmpty { Text("暂无记录").font(.footnote).foregroundStyle(.secondary) }
            ForEach(records) { item in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top) {
                        Text(item.number.isEmpty ? "未知号码" : item.number).font(.headline).textSelection(.enabled)
                        Spacer()
                        Text(item.typeLabel(sms: sms)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(Date(timeIntervalSince1970: Double(item.timestamp) / 1000).formatted(date: .numeric, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                    if sms {
                        Text(item.text ?? "").font(.subheadline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if let id = item.subscriptionId { Text("SIM 订阅 ID · \(id)").font(.caption).foregroundStyle(.secondary) }
                    } else { Text("通话时长 · \(item.durationSeconds ?? 0) 秒").font(.subheadline).foregroundStyle(.secondary) }
                }.devicePagePanel()
            }
            if nextCursor != nil {
                Button("加载更多") { Task { await loadHistory(reset: false) } }
                    .buttonStyle(HakoActionButtonStyle(primary: false)).disabled(loading || !agent.online)
            }
        }
    }

    private func preview() {
        guard canPreview else { return }
        guard AndroidDeviceCommand.validNumber(number.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            inputError = "请输入 3–20 位数字，可带 + 国际区号。"; return
        }
        if sms {
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                inputError = "请输入短信内容。"; return
            }
            guard message.utf16.count <= 4000 else { inputError = "短信内容过长，请缩短后发送。"; return }
            guard subscription == -1 || sims.contains(where: { $0.subscriptionId == subscription }) else {
                inputError = "请选择当前可用的短信 SIM 卡。"; return
            }
        }
        inputError = nil; confirming = true
    }

    @MainActor private func loadHistory(reset: Bool) async {
        guard !loading else { return }
        loading = true; historyError = nil
        defer { loading = false }
        let cursor = reset ? nil : nextCursor
        var params: [String: Any] = ["limit": pageSize]
        if let cursor { params["cursor"] = cursor }
        do {
            let page = try await client.invokeAgent(agent, method: queryCommand, version: 1, params: params, as: AndroidHistoryPage.self)
            guard page.isValid(sms: sms), page.nextCursor == nil || page.nextCursor != cursor else {
                throw HakoError(message: "设备返回的历史记录格式或分页游标无效。")
            }
            if reset { records = page.items }
            else {
                let existing = Set(records.map(\.id))
                records += page.items.filter { !existing.contains($0.id) }
            }
            nextCursor = page.nextCursor; queried = true
        } catch is CancellationError { }
        catch { historyError = DeviceMonitorFailure.message(for: error) }
    }

    @MainActor private func execute() async {
        guard canSubmit else { return }
        let record = AndroidPendingOperation(kind: kind)
        do { operationData = try JSONEncoder().encode(record) }
        catch { actionError = "无法保存操作 ID，未提交操作。"; confirming = false; return }
        working = true; actionError = nil
        defer { working = false; confirming = false }
        var params: [String: Any] = ["requestId": record.requestId, "number": number.trimmingCharacters(in: .whitespacesAndNewlines)]
        if sms {
            params["text"] = message
            if subscription >= 0 { params["subscriptionId"] = subscription }
        }
        do {
            let result = try await client.invokeAgent(agent, method: actionCommand, version: 1, params: params, as: AndroidOperation.self)
            try store(result, for: record)
        } catch is CancellationError { }
        catch let error as ConsoleAgentError where ["invalid_params", "permission_denied", "action_disabled"].contains(error.code) {
            // These v1 errors are raised before Android records or executes the action.
            operationData = Data()
            actionError = error.localizedDescription
        }
        catch {
            actionError = "\(DeviceMonitorFailure.message(for: error))\n操作未能确认，请查询原请求结果，不要重复提交。"
        }
    }
    @MainActor private func lookup() async {
        guard let record = pending, !lookingUp, !working else { return }
        lookingUp = true; actionError = nil
        defer { lookingUp = false }
        do {
            let result = try await client.invokeAgent(agent, method: AndroidDeviceCommand.operation, version: 1,
                params: ["requestId": record.requestId], as: AndroidOperation.self)
            try store(result, for: record)
        } catch is CancellationError { }
        catch { actionError = DeviceMonitorFailure.message(for: error) }
    }
    private func store(_ result: AndroidOperation, for record: AndroidPendingOperation) throws {
        guard result.isValid, result.requestId == record.requestId, result.kind == record.kind else {
            throw HakoError(message: "设备返回的操作结果与当前请求不一致。")
        }
        var updated = record; updated.result = result
        operationData = try JSONEncoder().encode(updated)
    }
}

private extension View {
    func androidTelephonyField() -> some View {
        self.padding(12).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(HakoStyle.background, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(HakoStyle.line, lineWidth: 1) }
    }
}

struct AndroidOperationReceipt: View {
    let operation: AndroidOperation?
    let requestId: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(operation?.title ?? "操作结果未确认").font(.headline)
            if let operation {
                Text(operation.message).font(.subheadline)
                Text(androidTimestamp(operation.updatedAt)).font(.caption).foregroundStyle(.secondary)
            }
            Text("请求 ID · \(requestId)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

struct DeviceAndroidOperationLookupView: View {
    let agent: ConsoleAgent
    @ObservedObject private var client = DeviceMonitorClient.shared
    @State private var requestID = ""
    @State private var result: AndroidOperation?
    @State private var error: String?
    @State private var loading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("请求 ID").font(.subheadline).foregroundStyle(.secondary)
            TextField("输入操作的 UUID", text: $requestID).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityLabel("请求 ID").disabled(loading)
            Button(loading ? "查询中…" : "查询操作结果") { Task { await lookup() } }
                .buttonStyle(HakoActionButtonStyle()).disabled(loading || !agent.online || UUID(uuidString: requestID) == nil)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
            if let result { AndroidOperationReceipt(operation: result, requestId: result.requestId) }
        }.devicePagePanel()
    }
    @MainActor private func lookup() async {
        loading = true; error = nil; result = nil
        defer { loading = false }
        let id = requestID.lowercased()
        do {
            let value = try await client.invokeAgent(agent, method: AndroidDeviceCommand.operation, version: 1,
                params: ["requestId": id], as: AndroidOperation.self)
            guard value.isValid, value.requestId == id else { throw HakoError(message: "操作结果与请求 ID 不一致。") }
            result = value
        } catch is CancellationError { }
        catch { self.error = DeviceMonitorFailure.message(for: error) }
    }
}
