import SwiftUI

struct StockTradeView: View {
    @StateObject private var store = StockTradeStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = Page.picks
    @State private var showingSettings = false
    @State private var showingNotifications = false
    private enum Page: String, CaseIterable { case picks = "选股", watch = "关注", alerts = "提醒" }

    var body: some View {
        Group {
            if !store.configured {
                ContentUnavailableView {
                    Label("连接 Cerno", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("填写独立后端的 HTTPS 地址与公开应用 ID，使用当前 Hako 身份登录。")
                } actions: {
                    Button("配置连接") { showingSettings = true }.buttonStyle(HakoActionButtonStyle()).padding(.horizontal, 32)
                }
            } else if store.session == nil {
                loginState
            } else {
                VStack(spacing: 0) {
                    if let error = store.error { StockTradeMessage(text: error).padding(.horizontal, 18) }
                    switch page {
                    case .picks: picks
                    case .watch: StockTradeWatchView(store: store)
                    case .alerts: StockTradeFeedView(store: store, kind: .alerts)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    HakoUnderlineTabs(title: "A 股选股导航", options: Page.allCases, selection: $page) { $0.rawValue }
                        .padding(.horizontal, 18).background(.bar)
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("A 股选股")
        .toolbar {
            if page == .alerts, store.session != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingNotifications = true } label: { Image(systemName: "bell.badge") }
                        .accessibilityLabel("Cerno 通知配置")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Cerno 连接设置")
            }
        }
        .sheet(isPresented: $showingSettings, onDismiss: { Task { await store.activate() } }) { StockTradeSettingsView(store: store) }
        .sheet(isPresented: $showingNotifications) { StockTradeNotificationSettings(store: store) }
        .sheet(item: Binding(get: { store.consent }, set: { if $0 == nil { store.dismissConsent() } })) { consent in
            NativeApplicationConsentSheet(consent: consent) { try await store.confirmConsent() }
        }
        .task(id: store.activationKey) { if !showingSettings { await store.activate() } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.activate() } } }
    }

    private var loginState: some View {
        ScrollView {
            VStack(spacing: 20) {
                ContentUnavailableView("使用 Hako 登录", systemImage: "person.crop.circle",
                    description: Text("业务数据直连 Cerno。首次连接需要明确授权；有效授权期间可自动登录。"))
                if store.authenticating { ProgressView("正在核验授权…") }
                if let error = store.error { StockTradeMessage(text: error) }
                Button("使用 Hako 身份登录") { Task { await store.login() } }
                    .buttonStyle(HakoActionButtonStyle()).disabled(store.authenticating)
            }.padding(24)
        }
    }

    private var picks: some View {
        List {
            if let run = store.run {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("最近完整选股 · " + run.dataAsOf).font(.headline)
                        Text("候选 \(run.candidateCount) · 复评 \(run.reviewCount) · 推荐 \(run.recommendationCount)")
                            .font(.subheadline).monospacedDigit()
                        StockTradeFreshness(publishedAt: run.publishedAt, dataAsOf: run.dataAsOf, stale: run.stale)
                    }.stockTradeSeparator()
                    NavigationLink("后台与数据状态") { StockTradeHealthView(store: store) }.stockTradeSeparator()
                    DisclosureGroup("本轮门槛与规则") {
                        StockTradeFields(fields: run.thresholds)
                    }.stockTradeSeparator()
                }
            }
            Section {
                Picker("选股范围", selection: Binding(get: { store.pool }, set: { value in Task { await store.selectPool(value) } })) {
                    ForEach(StockTradePool.allCases) { Text($0.title).tag($0) }
                }.disabled(store.loading || store.run == nil).stockTradeSeparator()
                ForEach(store.rows) { record in
                    NavigationLink {
                        StockTradeStockView(store: store, record: record, run: store.run)
                    } label: { StockTradeStockRow(record: record) }.stockTradeSeparator()
                }
                if store.loading { ProgressView("读取快照…") }
                else if store.rows.isEmpty {
                    Text(store.error == nil ? "当前范围没有已发布记录。" : "尚未载入选股数据，请查看上方提示。")
                        .foregroundStyle(.secondary)
                }
                if store.nextCursor != nil {
                    Button("加载更多") { Task { await store.loadResults(append: true) } }.disabled(store.loading)
                }
            } footer: {
                Text("沿用后台排名与门槛。候选及规则评分不是实际交易指令；打开或刷新页面不会启动扫描。")
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { await store.refresh() }
    }
}

struct StockTradeStockRow: View {
    let record: StockTradeRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.name).font(.headline)
                Spacer(minLength: 8)
                if let rank = record.rank { Text(rank, format: .number.precision(.fractionLength(1))).font(.title3.weight(.medium)).monospacedDigit() }
            }
            Text(record.symbol).font(.caption).foregroundStyle(.secondary)
            if record.rank != nil {
                Text("排序分 · 评分 \(record["total_score"].text) · 风险 \(record["risk_score"].text)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !record.reason.isEmpty { Text(record.reason).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
        }.padding(.vertical, 5).accessibilityElement(children: .combine)
    }
}

struct StockTradeFreshness: View {
    let publishedAt: String
    let dataAsOf: String?
    let stale: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text((stale ? "数据待更新 · " : "数据截至 ") + StockTradeTime.display(dataAsOf ?? "未提供"))
                .foregroundStyle(stale ? Color.orange : Color.secondary)
            Text("发布 " + StockTradeTime.display(publishedAt) + " · 上海时间").foregroundStyle(.secondary)
        }.font(.caption)
    }
}

struct StockTradeMessage: View {
    let text: String
    var body: some View { Label(text, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12) }
}

struct StockTradeFields: View {
    let fields: [String: StockTradeValue]
    var body: some View {
        ForEach(fields.keys.sorted(), id: \.self) { key in
            VStack(alignment: .leading, spacing: 6) {
                Text(StockTradeLabels.title(key)).font(.subheadline).foregroundStyle(.secondary)
                Text(fields[key]!.text).font(.subheadline).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading).stockTradeSeparator()
        }
    }
}

enum StockTradeLabels {
    static func title(_ key: String) -> String {
        ["rank_score":"排序分", "total_score":"规则评分", "risk_score":"风险分", "rank_reason":"排序原因", "rank_factors":"排序因子", "risk_flags":"风险标记", "risk_categories":"风险分类", "exclusion_reasons":"排除原因", "why_candidate":"入选依据", "missing_checks":"待验证事项", "comment":"复评说明", "verdict":"复评结论", "evidence":"评分依据", "min_score_threshold":"最低规则评分", "min_rank_score_threshold":"最低排序分", "max_risk_score_for_recommendation":"最高风险分", "trading_rules":"纸面模拟规则", "status":"状态", "updated_at":"状态更新时间", "last_tick_at":"最近调度", "last_quote_at":"最近行情", "last_alert_at":"最近提醒", "open_positions":"模拟进行中数量", "pending_alerts":"等待投递提醒数", "alert_type":"事件类型", "alert_time":"事件时间", "reason":"触发原因", "price":"触发价", "source_suggestion_date":"来源推荐日", "entry_time":"模拟开始时间", "exit_time":"模拟结束时间", "entry_price":"模拟参考价", "stop_price":"规则止损价", "take_profit_price":"规则止盈价"][key] ?? key
    }
}

extension View {
    func stockTradeSeparator() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}
