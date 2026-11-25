import SwiftUI

struct StockTradeSettingsView: View {
    @ObservedObject var store: StockTradeStore
    @State private var draft = StockTradeConnection()
    @State private var original = StockTradeConnection()
    @State private var loaded = false
    @State private var message: String?
    @State private var loggingOut = false
    @State private var showingNotifications = false
    var body: some View {
        SettingsSheet(title: "Cerno 设置", hasChanges: loaded && draft != original, isBusy: loggingOut) {
            StockTradeScreen {
                StockTradeSectionLabel(title: "连接")
                StockTradeCard {
                    NavigationLink {
                        StockTradeConnectionSettingsView(store: store, draft: $draft, message: $message,
                            hasChanges: loaded && draft != original,
                            save: save, discard: { draft = original; message = nil })
                    } label: {
                        StockTradeEntryRow(title: "连接设置", subtitle: store.configured ? "后端地址与应用 ID" : "尚未配置", separator: false)
                    }.buttonStyle(.plain).accessibilityIdentifier("cerno.settings.connection")
                }
                StockTradeSectionLabel(title: "账号与授权")
                StockTradeCard {
                    VStack(alignment: .leading, spacing: 14) {
                        LabeledContent("登录授权", value: "Hako 原生授权 · PKCE").font(.subheadline)
                        Divider()
                        LabeledContent("当前账号", value: store.accountName).font(.subheadline)
                        Divider()
                        NavigationLink { StockTradeDeviceAuthorizations(store: store) }
                        label: { StockTradeEntryRow(title: "设备授权", subtitle: store.session == nil ? "尚未连接" : "查看已授权设备", separator: false) }.buttonStyle(.plain).disabled(store.session == nil)
                        if let session = store.session {
                            LabeledContent("访问令牌到期", value: StockTradeTime.display(session.expiresAt)).font(.caption).foregroundStyle(.secondary)
                            Button("退出 Cerno 并撤销设备续期", role: .destructive) { loggingOut = true }
                                .disabled(store.authenticating || store.loading)
                                .confirmationDialog("退出 Cerno 并撤销此设备的续期凭据？", isPresented: $loggingOut, titleVisibility: .visible) {
                                    Button("退出并撤销授权", role: .destructive) { Task { await store.logout() } }
                                } message: { Text("Cerno 将撤销本设备的续期凭据和关联会话。退出不依赖 Hako；Cerno 网络故障时保留凭据，供你重试。") }
                        }
                        if let error = store.error { StockTradeMessage(text: error) }
                    }
                }
                StockTradeFootnote(text: "Cerno 本地访问令牌有效期为 12 小时，通过本设备钥匙串中的设备凭据自动续期。Hako 仅在首次或重新登录时确认身份。")
                StockTradeSectionLabel(title: "选股说明")
                StockTradeCard {
                    ForEach(StockTradeGuideTopic.allCases) { topic in
                        NavigationLink { StockTradeGuideView(topic: topic, store: store) }
                        label: { StockTradeEntryRow(title: topic.rawValue, subtitle: topic.subtitle, separator: topic != .terms) }
                            .buttonStyle(.plain).accessibilityIdentifier("cerno.guide.\(topic.id)")
                    }
                }
                StockTradeCard(padding: 18) {
                    Button { showingNotifications = true } label: { StockTradeEntryRow(title: "通知配置") }.buttonStyle(.plain).disabled(store.session == nil)
                    NavigationLink { StockTradeHealthView(store: store) }
                    label: { StockTradeEntryRow(title: "调度与后台状态", separator: false) }.buttonStyle(.plain).disabled(store.session == nil)
                }
            }
            .onAppear { if !loaded { draft = store.connection; original = draft; loaded = true } }
        }
        .sheet(isPresented: $showingNotifications) { StockTradeNotificationSettings(store: store) }
    }
    private func save() -> Bool {
        do { try store.configure(draft); original = store.connection; message = nil; return true }
        catch { message = error.localizedDescription; return false }
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
            StockTradeScreen {
                StockTradeHeading(title: "通知配置", subtitle: "选择接收渠道与提醒内容")
                StockTradeFootnote(text: "本机偏好 · 尚未同步后台。以下设置暂不改变后台现有邮件投递。")
                StockTradeSectionLabel(title: "接收方式")
                StockTradeCard {
                    Toggle("邮件通知", isOn: $draft.email).padding(.vertical, 10)
                    LabeledContent("邮件收件人", value: "由 Cerno 后台配置").font(.caption).foregroundStyle(.secondary).padding(.bottom, 12)
                    Divider()
                    LabeledContent("手机推送", value: "尚未接入").font(.subheadline).padding(.vertical, 14)
                }
                StockTradeSectionLabel(title: "提醒内容")
                StockTradeCard {
                    Toggle("每日推荐", isOn: $draft.daily).padding(.vertical, 12); Divider()
                    Toggle("监控规则触发", isOn: $draft.rule).padding(.vertical, 12); Divider()
                    Toggle("风险观察", isOn: $draft.risk).padding(.vertical, 12); Divider()
                    Toggle("任务失败与后台异常", isOn: $draft.health).padding(.vertical, 12)
                }
                StockTradeSectionLabel(title: "接收时间")
                StockTradeCard {
                    Toggle("规则提醒仅交易日", isOn: $draft.tradingDays).padding(.vertical, 12); Divider()
                    Toggle("免打扰时段", isOn: $draft.quiet).padding(.vertical, 12)
                    if draft.quiet {
                        Divider()
                        DatePicker("开始", selection: timeBinding(\.quietStart), displayedComponents: .hourAndMinute).padding(.vertical, 10)
                        DatePicker("结束", selection: timeBinding(\.quietEnd), displayedComponents: .hourAndMinute).padding(.vertical, 10)
                    }
                }
                StockTradeFootnote(text: "上海时间。当前只保存本机偏好，不改变后台调度或补发历史事件。")
                StockTradeCard {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("同股票、同事件最短提醒间隔").font(.subheadline).foregroundStyle(.secondary)
                        Picker("重复提醒间隔", selection: $draft.duplicateMinutes) { ForEach([15, 30, 60], id: \.self) { Text("\($0) 分钟").tag($0) } }.pickerStyle(.menu)
                    }
                }
                if !draft.valid { Text("免打扰开始和结束时间不能相同。").font(.footnote).foregroundStyle(.red) }
                if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                Button("预览测试提醒") { preview = true }.buttonStyle(HakoActionButtonStyle(primary: false, outlined: true))
                StockTradeFootnote(text: "只预览内容，不投递邮件或推送；手机推送尚未接入，不申请系统权限。")
            }
            .environment(\.timeZone, TimeZone(identifier: "Asia/Shanghai")!)
            .disabled(!loaded || !sameAccount)
            .onAppear(perform: load)
            .onChange(of: store.preferenceKey) { _, value in if value != scopeKey { dismiss() } }
        }
        .sheet(isPresented: $preview) {
            SettingsSheet(title: "测试通知预览") {
                StockTradeScreen {
                    StockTradeHeading(title: "测试提醒", subtitle: "内容预览 · 不发送真实通知")
                    StockTradeCard {
                        Text("Cerno · 内容示例").font(.caption).foregroundStyle(.secondary)
                        Text("选股结果已更新").font(.title3.weight(.semibold)).padding(.vertical, 12)
                        Text("本次完整选股结果已发布，可查看排名与评分原因。").font(.subheadline)
                    }
                    StockTradeFootnote(text: "这是本机内容预览，没有真实投递。实际送达取决于后台渠道、系统权限与已应用的时段规则。")
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
