import SwiftUI

struct StockTradeSettingsView: View {
    @ObservedObject var store: StockTradeStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = StockTradeConnection()
    @State private var original = StockTradeConnection()
    @State private var loaded = false
    @State private var message: String?
    @State private var loggingOut = false
    @State private var showingNotifications = false
    var body: some View {
        SettingsSheet(title: "Cerno 连接设置", hasChanges: loaded && draft != original, isBusy: loggingOut,
                      saveEnabled: loaded && draft != original && !store.authenticating && !store.loading,
                      onSave: save) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("后端基础地址（HTTPS）").font(.subheadline).foregroundStyle(.secondary)
                        TextField("https://example.com/cerno/", text: $draft.origin).keyboardType(.URL)
                            .accessibilityLabel("Cerno 后端基础地址")
                    }.stockTradeSeparator()
                    if let origin = draft.applicationOrigin {
                        HakoLabeledValue(label: "Hako 登记来源", value: origin).stockTradeSeparator()
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Hako 应用 ID（公开）").font(.subheadline).foregroundStyle(.secondary)
                        TextField("后台登记的 clientId", text: $draft.clientID).accessibilityLabel("Cerno Hako 应用 ID")
                    }.stockTradeSeparator()
                } header: { Text("独立后端") } footer: { Text("可填写域名根地址或应用子路径，例如 https://example.com/cerno/，无需追加 api/v1。Hako 应用登记来源仍使用域名根地址。应用 ID 应与后台登记一致；不填写 appSecret、Tushare 或邮件凭据。") }
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .disabled(store.authenticating || store.loading || loggingOut)
                Section {
                    LabeledContent("认证方式", value: "Cerno 本地会话 · 设备续期").stockTradeSeparator()
                    LabeledContent("当前账号", value: store.accountName).stockTradeSeparator()
                    if let session = store.session {
                        LabeledContent("访问令牌到期", value: StockTradeTime.display(session.expiresAt)).stockTradeSeparator()
                        Button("退出 Cerno 并撤销设备续期", role: .destructive) { loggingOut = true }
                            .disabled(store.authenticating || store.loading)
                            .confirmationDialog("退出 Cerno 并撤销此设备的续期凭据？", isPresented: $loggingOut, titleVisibility: .visible) {
                                Button("退出并撤销授权", role: .destructive) { Task { await store.logout() } }
                            } message: { Text("Cerno 将撤销本设备的续期凭据和关联会话。退出不依赖 Hako；Cerno 网络故障时保留凭据，供你重试。") }
                    }
                    if let error = store.error { StockTradeMessage(text: error) }
                } header: { Text("账号") } footer: { Text("访问令牌有效期为 12 小时；设备标识和续期密钥匹配时自动续期。凭据仅保存在本设备钥匙串，不通过 iCloud 同步；Hako 仅在首次或重新登录时确认身份。") }
                Section {
                    Button("通知配置") { showingNotifications = true }.disabled(store.session == nil)
                    NavigationLink("后台与数据状态") { StockTradeHealthView(store: store) }.disabled(store.session == nil).stockTradeSeparator()
                }
                if let message { Section { Text(message).foregroundStyle(.red).font(.footnote) } }
            }
            .onAppear { if !loaded { draft = store.connection; original = draft; loaded = true } }
        }
        .sheet(isPresented: $showingNotifications) { StockTradeNotificationSettings(store: store) }
    }
    private func save() {
        do { try store.configure(draft); original = store.connection; dismiss() }
        catch { message = error.localizedDescription }
    }
}

struct StockTradeNotificationSettings: View {
    @ObservedObject var store: StockTradeStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = StockTradeNotificationPreferences()
    @State private var original = StockTradeNotificationPreferences()
    @State private var loaded = false
    @State private var error: String?
    @State private var preview = false
    @State private var scopeKey: String?
    private var sameAccount: Bool { scopeKey != nil && scopeKey == store.preferenceKey }
    var body: some View {
        SettingsSheet(title: "通知配置", hasChanges: loaded && draft != original,
                      saveEnabled: loaded && sameAccount && draft.valid && draft != original,
                      onSave: save, saveAccessibilityLabel: "保存本机通知偏好") {
            Form {
                Section {
                    Label("本机偏好 · 尚未同步后台", systemImage: "iphone")
                    Text("当前 API 只有只读提醒记录。以下偏好保存在本机，不影响后台现有邮件投递；待后端支持后才能实际应用。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("邮件通知偏好", isOn: $draft.email).stockTradeSeparator()
                    LabeledContent("邮件收件人", value: "由 Cerno 后台配置").stockTradeSeparator()
                    LabeledContent("手机推送", value: "尚未接入").stockTradeSeparator()
                } header: { Text("接收方式") } footer: { Text("邮件已有后台能力。Cerno 尚未提供 APNs 投递和设备绑定接口，此处不申请通知权限，也不显示虚构的启用状态。") }
                Section("提醒内容偏好") {
                    Toggle("每日推荐", isOn: $draft.daily).stockTradeSeparator()
                    Toggle("监控规则触发", isOn: $draft.rule).stockTradeSeparator()
                    Toggle("风险观察", isOn: $draft.risk).stockTradeSeparator()
                    Toggle("后台异常", isOn: $draft.health).stockTradeSeparator()
                }
                Section {
                    Toggle("规则提醒仅交易日", isOn: $draft.tradingDays).stockTradeSeparator()
                    Toggle("免打扰", isOn: $draft.quiet).stockTradeSeparator()
                    if draft.quiet {
                        DatePicker("开始", selection: timeBinding(\.quietStart), displayedComponents: .hourAndMinute).stockTradeSeparator()
                        DatePicker("结束", selection: timeBinding(\.quietEnd), displayedComponents: .hourAndMinute).stockTradeSeparator()
                    }
                } header: { Text("提醒时段偏好") } footer: { Text("上海时间（Asia/Shanghai）。预期仅交易日约束监控与风险提醒；免打扰结束不补发历史事件。当前仅保存偏好，不改变后台调度。") }
                Section("重复提醒偏好") {
                    Picker("同股票、同事件间隔", selection: $draft.duplicateMinutes) {
                        ForEach([15, 30, 60], id: \.self) { Text("\($0) 分钟").tag($0) }
                    }.stockTradeSeparator()
                }
                if !draft.valid { Section { Text("免打扰开始和结束时间不能相同。").foregroundStyle(.red) } }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
                Section {
                    Button("预览测试通知") { preview = true }.buttonStyle(HakoActionButtonStyle())
                } footer: { Text("只预览内容，不投递邮件、系统本地通知或手机推送。") }
            }
            .environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
            .disabled(!loaded || !sameAccount)
            .onAppear(perform: load)
            .onChange(of: store.preferenceKey) { _, value in if value != scopeKey { dismiss() } }
        }
        .sheet(isPresented: $preview) {
            SettingsSheet(title: "测试通知预览") {
                Form {
                    Section("内容示例 · 不是真实推荐") {
                        Label("Cerno", systemImage: "chart.xyaxis.line")
                        Text("每日推荐已更新").font(.headline)
                        Text("本次完整选股结果已发布，可查看排名与评分原因。")
                    }
                    Section { Text("这是本机内容预览，没有真实投递。实际送达取决于后台渠道、系统权限与已应用的时段规则。").font(.footnote).foregroundStyle(.secondary) }
                }
            }
        }
    }
    private func load() {
        guard !loaded else { return }
        scopeKey = store.preferenceKey
        guard let key = scopeKey else { return }
        if let data = UserDefaults.standard.data(forKey: key) {
            do {
                let value = try JSONDecoder().decode(StockTradeNotificationPreferences.self, from: data)
                guard value.valid else { throw StockTradeFailure.invalidResponse }
                draft = value
            } catch { self.error = "原偏好无法读取，已保留；保存将替换它。" }
        }
        original = draft; loaded = true
    }
    private func save() {
        guard sameAccount, let key = scopeKey, draft.valid else { return }
        do { UserDefaults.standard.set(try JSONEncoder().encode(draft), forKey: key); original = draft; dismiss() }
        catch { self.error = "本机通知偏好保存失败，请重试。" }
    }
    private func timeBinding(_ key: WritableKeyPath<StockTradeNotificationPreferences, Int>) -> Binding<Date> {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let base = calendar.startOfDay(for: .now)
        return Binding(get: { calendar.date(byAdding: .minute, value: draft[keyPath: key], to: base)! },
                       set: { date in let parts = calendar.dateComponents([.hour, .minute], from: date); draft[keyPath: key] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) })
    }
}
