import SwiftUI

struct StockTradeView: View {
    @StateObject private var store = StockTradeStore.shared
    @StateObject private var navigation = StockTradeNavigation()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var page = StockTradeTab.picks
    @State private var sheet: Sheet?
    @State private var localError: String?
    private enum Sheet: Identifiable {
        case settings, notifications
        var id: String {
            switch self {
            case .settings: "settings"
            case .notifications: "notifications"
            }
        }
    }
    var body: some View {
        Group {
            if !store.configured {
                ContentUnavailableView {
                    Label("连接 Cerno", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("填写独立后端的 HTTPS 地址与公开应用 ID，使用当前 Hako 身份登录。")
                } actions: {
                    Button("配置连接") { sheet = .settings }.buttonStyle(StockTradeAppearance.action).padding(.horizontal, 32)
                }
            } else if store.session == nil { loginState }
            else {
                ZStack {
                    Group {
                        switch page {
                        case .picks: picks
                        case .watch: StockTradeWatchView(store: store)
                        case .monitor: StockTradeFeedView(store: store, kind: .monitor)
                        case .work: StockTradeWorkbench(store: store, showResults: showResults, showSettings: { sheet = .settings })
                        }
                    }
                    .opacity(navigation.routes.isEmpty ? 1 : 0)
                    .allowsHitTesting(navigation.routes.isEmpty)
                    .accessibilityHidden(!navigation.routes.isEmpty)
                    ForEach(navigation.routes) { route in
                        StockTradeDestination(store: store, route: route, showResults: showResults)
                            .opacity(navigation.routes.last?.id == route.id ? 1 : 0)
                            .allowsHitTesting(navigation.routes.last?.id == route.id)
                            .accessibilityHidden(navigation.routes.last?.id != route.id)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    StockTradeBottomTabs(selection: Binding(get: { page }, set: { page = $0; navigation.reset() }))
                }
            }
        }
        .background(StockTradeAppearance.background).tint(StockTradeAppearance.tint)
        .navigationTitle("Cerno").navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(StockTradeAppearance.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .environmentObject(navigation)
        .onChange(of: page) { _, _ in navigation.reset() }
        .onChange(of: store.scope) { _, _ in navigation.reset(); sheet = nil; localError = nil }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if navigation.routes.isEmpty { dismiss() } else { navigation.pop() }
                } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel(navigation.routes.isEmpty ? "返回 Hako" : "返回上一页")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { sheet = .settings } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Cerno 连接设置")
            }
        }
        .sheet(item: $sheet, onDismiss: { Task { await store.activate() } }) { selected in
            switch selected {
            case .settings: StockTradeSettingsView(store: store)
            case .notifications: StockTradeNotificationSettings(store: store)
            }
        }
        .sheet(item: Binding(get: { store.consent }, set: { if $0 == nil { store.dismissConsent() } })) { consent in
            NativeApplicationConsentSheet(consent: consent) { try await store.confirmConsent() }
        }
        .task(id: store.activationKey) { if sheet == nil { await store.activate() } }
        .task(id: "\(store.scope)|\(store.session != nil)|\(scenePhase == .active)") {
            guard store.session != nil, scenePhase == .active else { return }
            repeat {
                await store.refreshWorkflows()
                do { try await Task.sleep(for: .seconds(store.activeWorkflow == nil ? 15 : 4)) } catch { return }
            } while !Task.isCancelled
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.activate() } } }
    }
    private func showResults() { sheet = nil; navigation.reset(); page = .picks }
    private func startOrShowTask() {
        if let task = store.activeWorkflow { navigation.push(.task(task)) }
        else { navigation.push(.create(.full)) }
    }
    private var loginState: some View {
        StockTradeScreen {
            StockTradeHeading(title: "A 股选股", subtitle: "发现机会，也看清入选依据")
            StockTradeCard {
                VStack(spacing: 20) {
                    ContentUnavailableView("使用 Hako 登录", systemImage: "person.crop.circle", description: Text("首次连接需要明确授权；有效授权期间可自动登录。"))
                    if store.authenticating { ProgressView("正在核验授权…") }
                    if let error = store.error { StockTradeMessage(text: error) }
                    Button("使用 Hako 身份登录") { Task { await store.login() } }.buttonStyle(StockTradeAppearance.action).disabled(store.authenticating)
                }
            }
        }
    }
    private var picks: some View {
        StockTradeScreen {
            StockTradeHeading(title: "A 股选股", subtitle: "发现机会，也看清入选依据", action: "搜索股票", symbol: "magnifyingglass") { navigation.push(.search) }
            if let task = store.activeWorkflow { StockTradeTaskBanner(task: task) { navigation.push(.task(task)) } }
            if let error = store.error, store.run != nil { StockTradeMessage(text: error) }
            if let failed = store.workflowTasks.first, failed.state == .failed {
                HStack(alignment: .top) {
                    StockTradeMessage(text: "最近任务未完成，继续展示上次完整结果。")
                    Button("查看失败原因") { navigation.push(.task(failed)) }.font(.footnote)
                }
            }
            if let run = store.run {
                summary(run)
                HStack {
                    Text("选股范围").font(.headline)
                    Spacer()
                    Picker("选股范围", selection: Binding(get: { store.pool }, set: { value in Task { await store.selectPool(value) } })) {
                        ForEach(StockTradePool.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu).labelsHidden().disabled(store.loading)
                }.padding(.horizontal, 4)
                StockTradeCard(padding: 18) {
                    ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, record in
                        Button { navigation.push(.stock(record, store.run)) }
                        label: { StockTradeStockRow(record: record, position: index + 1) }.buttonStyle(.plain)
                        if index < store.rows.count - 1 { Divider() }
                    }
                    if store.loading { ProgressView("读取快照…").padding(.vertical, 16) }
                    else if store.rows.isEmpty { Text(store.error == nil ? "当前范围没有已发布记录。" : "尚未载入选股数据，请查看上方提示。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 18) }
                    if store.nextCursor != nil { Button("加载更多") { Task { await store.loadResults(append: true) } }.disabled(store.loading).padding(.vertical, 12) }
                }
                HStack {
                    Text("沿用后台排名与门槛").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("重新选股", action: startOrShowTask).font(.subheadline)
                }.padding(.horizontal, 4)
                StockTradeFootnote(text: "候选与评分用于研究参考。打开或刷新页面只读取已发布结果，不会启动选股。")
                DisclosureGroup("本轮门槛与规则") { StockTradeFields(fields: run.thresholds).padding(.top, 8) }.font(.footnote).padding(.horizontal, 4)
            } else if store.loading { ProgressView("读取快照…").frame(maxWidth: .infinity).padding(.vertical, 32) }
            else { emptyState }
        }.refreshable { await store.refresh() }
    }
    private func summary(_ run: StockTradeRun) -> some View {
        StockTradeCard {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(store.displayedRunID == nil ? "最新完整结果" : "所选完整结果").font(.footnote).foregroundStyle(.secondary)
                    Text(run.dataAsOf).font(.headline)
                }
                Spacer()
                Button("历史记录 ›") { navigation.push(.publications) }.font(.subheadline)
            }
            Divider().padding(.vertical, 16)
            HStack {
                metric("\(run.candidateCount)", label: "初选候选")
                Spacer(minLength: 8)
                metric("\(run.recommendationCount)", label: "正式推荐")
                Spacer(minLength: 8)
                metric(publishedTime(run.publishedAt), label: "发布时间")
            }
            if run.stale { Text("数据待更新").font(.caption).foregroundStyle(.orange).padding(.top, 12) }
            if store.displayedRunID != nil {
                Button("返回最新结果") { Task { do { try await store.openPublishedRun(nil) } catch { localError = error.localizedDescription } } }.font(.footnote).padding(.top, 12)
            }
            if let localError { StockTradeMessage(text: localError) }
        }
    }
    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func publishedTime(_ text: String) -> String {
        guard let date = StockTradeTime.date(text) else { return "—" }
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: "Asia/Shanghai"); formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    private var emptyState: some View {
        let unavailable = store.error != nil && !store.missingSnapshot
        return StockTradeCard {
            VStack(spacing: 16) {
                Image(systemName: unavailable ? "wifi.exclamationmark" : "list.bullet.rectangle").font(.title).foregroundStyle(StockTradeAppearance.tint)
                    .frame(width: 64, height: 64).background(StockTradeAppearance.soft, in: RoundedRectangle(cornerRadius: 20))
                Text(unavailable ? "暂时无法载入选股数据" : "开始第一次完整选股").font(.title3.weight(.semibold))
                Text(unavailable ? "检查网络与后端连接。恢复连接后可重新载入，已有任务继续由后台执行。" : "抓取行情、策略初选、逐票复评，完成后自动发布。你可以离开页面，稍后回来查看。")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let error = store.error { StockTradeMessage(text: error) }
                if unavailable {
                    Button("检查连接") { sheet = .settings }.buttonStyle(StockTradeAppearance.action)
                } else {
                    Button(store.activeWorkflow == nil ? "启动完整选股" : "查看进行中的任务", action: startOrShowTask).buttonStyle(StockTradeAppearance.action)
                    Text("尚无已发布快照").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity).padding(.vertical, 18)
        }
    }
}

struct StockTradeStockRow: View {
    let record: StockTradeRecord
    var position: Int? = nil
    var body: some View {
        HStack(spacing: 12) {
            if let position { Text("\(position)").font(.caption).foregroundStyle(.secondary).frame(minWidth: 15) }
            VStack(alignment: .leading, spacing: 6) {
                Text(record.name).font(.headline)
                Text(record.symbol + (record.reason.isEmpty ? "" : " · " + record.reason)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                if let close = record["close"].number { Text(close, format: .number.precision(.fractionLength(2))).font(.body).monospacedDigit() }
                else { Text("—").foregroundStyle(.secondary) }
                Text("收盘 / 元").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 17).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).accessibilityElement(children: .combine)
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
