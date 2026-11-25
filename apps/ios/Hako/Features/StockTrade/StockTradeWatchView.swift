import SwiftUI

struct StockTradeWatchView: View {
    @EnvironmentObject private var navigation: StockTradeNavigation
    @ObservedObject var store: StockTradeStore
    var body: some View {
        StockTradeScreen {
            StockTradeHeading(title: "我的关注", subtitle: "把需要持续观察的股票放在一起", action: "添加") { navigation.push(.search) }
            StockTradeCard(padding: 18) {
                ForEach(Array(store.favorites.enumerated()), id: \.element.id) { index, record in
                    Button { navigation.push(.stock(record, store.run)) }
                    label: { StockTradeStockRow(record: record) }.buttonStyle(.plain)
                    if index < store.favorites.count - 1 { Divider() }
                }
                if store.favorites.isEmpty { Text("还没有关注股票，可通过代码搜索添加。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 22) }
            }
            StockTradeFootnote(text: "关注列表与后台规则监控分别管理。")
            if !store.favorites.isEmpty { StockTradeFootnote(text: "列表信息来自关注时的记录；详情重新读取当前快照。") }
        }
    }
}

struct StockTradeSearchView: View {
    @EnvironmentObject private var navigation: StockTradeNavigation
    @ObservedObject var store: StockTradeStore
    @State private var query = ""
    @State private var items: [StockTradeRecord] = []
    @State private var page: StockTradePage<StockTradeRecord>?
    @State private var loading = false
    @State private var message: String?
    @State private var displayedScope: UUID?
    private var term: String { String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)) }
    private var key: String { "\(store.scope)|\(store.run?.snapshotId ?? "")|\(term)" }
    var body: some View {
        StockTradeScreen {
            StockTradeHeading(title: "查找股票", subtitle: "候选快速选择，或输入 6 位代码")
            VStack(alignment: .leading, spacing: 6) {
                Text("股票名称或代码").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("例如 600519", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder).submitLabel(.search).accessibilityLabel("股票名称或代码")
                        .onSubmit { Task { await search(append: false) } }
                    Button("搜索") { Task { await search(append: false) } }.buttonStyle(.bordered).disabled(loading)
                }
            }
            StockTradeSectionLabel(title: term.isEmpty ? "本轮候选 · 快速选择" : "搜索结果")
            if let message { StockTradeMessage(text: message) }
            StockTradeCard(padding: 18) {
                if displayedScope == store.scope {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, record in
                        Button { navigation.push(.stock(record, store.run)) }
                        label: { StockTradeStockRow(record: record) }.buttonStyle(.plain)
                        if index < items.count - 1 { Divider() }
                    }
                }
                if loading { ProgressView("读取已发布行情…").padding(.vertical, 22) }
                else if items.isEmpty && message == nil { Text("没有找到匹配股票。请检查代码或名称。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 22) }
                if page?.nextCursor != nil { Button("加载更多") { Task { await search(append: true) } }.disabled(loading).padding(.vertical, 12) }
            }
            StockTradeFootnote(text: "只检索已发布行情，不会抓取新股票。")
        }
        .task(id: key) {
            items = []; page = nil; loading = true
            do { try await Task.sleep(for: .milliseconds(300)); await search(append: false) } catch { }
        }
    }
    private func search(append: Bool) async {
        let activeKey = key
        loading = true; message = nil
        defer { if activeKey == key { loading = false } }
        do {
            var parameters = [URLQueryItem(name: "limit", value: "50")]
            let path: [String]
            if term.isEmpty, let run = store.run { path = ["runs", run.runId, "candidates"] }
            else { path = ["stocks"]; parameters.append(.init(name: "q", value: term)) }
            if let snapshot = append ? page?.snapshotId : store.run?.snapshotId { parameters.append(.init(name: "snapshotId", value: snapshot)) }
            if append, let cursor = page?.nextCursor { parameters.append(.init(name: "cursor", value: cursor)) }
            let value = try await store.read(path, query: parameters, as: StockTradePage<StockTradeRecord>.self)
            guard key == activeKey else { return }
            guard value.items.allSatisfy({ StockTradeStore.validSymbol($0.symbol) }), Set(value.items.map(\.symbol)).count == value.items.count,
                  !append || value.snapshotId == page?.snapshotId && Set(items.map(\.symbol)).isDisjoint(with: value.items.map(\.symbol)) else { throw StockTradeFailure.invalidResponse }
            items = append ? items + value.items : value.items; page = value; displayedScope = store.scope
        } catch is CancellationError { }
        catch { if key == activeKey { message = error.localizedDescription } }
    }
}

enum StockTradeFeedKind: String { case monitor, alerts }

struct StockTradeFeedView: View {
    @EnvironmentObject private var navigation: StockTradeNavigation
    @ObservedObject var store: StockTradeStore
    let kind: StockTradeFeedKind
    @State private var state = "watch"
    @State private var items: [StockTradeRecord] = []
    @State private var page: StockTradePage<StockTradeRecord>?
    @State private var recent: [StockTradeRecord] = []
    @State private var recentSnapshot: String?
    @State private var recentScope: UUID?
    @State private var recentError: String?
    @State private var monitorUnavailable = false
    @State private var message: String?
    @State private var loading = false
    @State private var notifications = false
    @State private var displayedScope: UUID?
    private var key: String { "\(store.scope)|\(kind.rawValue)|\(state)" }
    var body: some View {
        StockTradeScreen {
            if kind == .monitor {
                StockTradeHeading(title: "规则监控", subtitle: "观察条件变化，保留每次触发记录", action: "通知配置", symbol: "bell") { notifications = true }
                Picker("监控状态", selection: $state) {
                    Text("观察中").tag("watch"); Text("纸面持仓").tag("open"); Text("已结束").tag("closed")
                }.pickerStyle(.segmented)
            } else { StockTradeHeading(title: "提醒记录", subtitle: "监控与任务事件集中查看") }
            if let message { StockTradeMessage(text: message) }
            if kind == .monitor && monitorUnavailable {
                Button("启用规则监控") { navigation.push(.create(.monitor)) }
                    .buttonStyle(StockTradeAppearance.action)
            }
            StockTradeCard(padding: 18) {
                if displayedScope == store.scope {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, record in
                        if kind == .alerts { alertLink(record, snapshot: page?.snapshotId) }
                        else {
                            Button { navigation.push(.stock(record, store.run)) }
                            label: { StockTradeStockRow(record: record) }.buttonStyle(.plain)
                        }
                        if index < items.count - 1 { Divider() }
                    }
                }
                if loading { ProgressView("读取后台快照…").padding(.vertical, 20) }
                else if items.isEmpty { Text(message == nil ? "暂无已发布记录。" : "尚未载入监控快照。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20) }
                if page?.nextCursor != nil { Button("加载更多") { Task { await load(append: true) } }.disabled(loading).padding(.vertical, 12) }
            }
            if kind == .monitor {
                HStack {
                    StockTradeSectionLabel(title: "最近提醒")
                    Spacer()
                    Button("全部记录 ›") { navigation.push(.alerts) }.font(.subheadline)
                }
                if let recentError { StockTradeMessage(text: recentError) }
                StockTradeCard(padding: 18) {
                    ForEach(Array((recentScope == store.scope ? recent : []).enumerated()), id: \.element.id) { index, record in
                        alertLink(record, snapshot: recentSnapshot)
                        if index < recent.count - 1 { Divider() }
                    }
                    if recent.isEmpty { Text(recentError == nil ? "暂无提醒记录。" : "尚未载入提醒记录。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 20) }
                }
                StockTradeFootnote(text: "纸面记录来自后台规则监控，不会下单。交易时段与采样状态可在工作台查看。")
            } else { StockTradeFootnote(text: "邮件与手机推送分别记录。邮件成功不代表手机已收到，也不代表券商成交。") }
            if displayedScope == store.scope, let page { StockTradeFreshness(publishedAt: page.publishedAt, dataAsOf: page.dataAsOf, stale: page.stale).padding(.horizontal, 4) }
        }
        .sheet(isPresented: $notifications) { StockTradeNotificationSettings(store: store) }
        .task(id: key) { items = []; recent = []; recentSnapshot = nil; recentScope = nil; page = nil; await load(append: false); if kind == .monitor { await loadRecent() } }
        .refreshable { await load(append: false); if kind == .monitor { await loadRecent() } }
    }
    private func alertLink(_ record: StockTradeRecord, snapshot: String?) -> some View {
        Button { navigation.push(.alert(record, snapshot)) } label: {
            StockTradeEntryRow(title: record.string("reason").isEmpty ? "规则提醒" : record.string("reason"), subtitle: record.name + " · " + StockTradeTime.display(record.string("alert_time")), separator: false)
        }.buttonStyle(.plain)
    }
    private func loadRecent() async {
        let scope = store.scope
        do {
            let value = try await store.read(["alerts"], query: [.init(name: "limit", value: "2")], as: StockTradePage<StockTradeRecord>.self)
            guard scope == store.scope else { return }
            guard value.items.allSatisfy({ !$0.id.isEmpty && StockTradeStore.validSymbol($0.symbol) }), Set(value.items.map(\.id)).count == value.items.count else { throw StockTradeFailure.invalidResponse }
            recent = value.items; recentSnapshot = value.snapshotId; recentScope = scope; recentError = nil
        } catch is CancellationError { }
        catch { if scope == store.scope { recentError = error.localizedDescription } }
    }
    private func load(append: Bool) async {
        let activeKey = key
        loading = true; message = nil; monitorUnavailable = false
        defer { if activeKey == key { loading = false } }
        do {
            var query = [URLQueryItem(name: "limit", value: "50")]
            if kind == .monitor, !state.isEmpty { query.append(.init(name: "state", value: state)) }
            if append, let cursor = page?.nextCursor { query.append(.init(name: "cursor", value: cursor)) }
            let value: StockTradePage<StockTradeRecord> = try await store.read(kind == .monitor ? ["monitor", "items"] : ["alerts"], query: query, as: StockTradePage<StockTradeRecord>.self)
            guard key == activeKey else { return }
            guard kind != .monitor || value.mode == "paper",
                  value.items.allSatisfy({ !$0.id.isEmpty && StockTradeStore.validSymbol($0.symbol) }),
                  Set(value.items.map(\.id)).count == value.items.count,
                  !append || (value.snapshotId == page?.snapshotId && Set(items.map(\.id)).isDisjoint(with: value.items.map(\.id))) else { throw StockTradeFailure.invalidResponse }
            items = append ? items + value.items : value.items; page = value; displayedScope = store.scope
        } catch is CancellationError { }
        catch {
            if key == activeKey {
                message = error.localizedDescription
                if let failure = error as? StockTradeFailure, case .api(_, let code, _, _) = failure {
                    monitorUnavailable = code == "monitor_unavailable"
                }
            }
        }
    }
}

struct StockTradeAlertView: View {
    @EnvironmentObject private var navigation: StockTradeNavigation
    @ObservedObject var store: StockTradeStore
    let record: StockTradeRecord
    let snapshotID: String?
    @State private var detail: StockTradeDetail?
    @State private var error: String?
    @State private var openedScope: UUID?
    var body: some View {
        StockTradeScreen {
            StockTradeHeading(title: "规则提醒", subtitle: record.symbol + " · " + StockTradeTime.display(record.string("alert_time")))
            if let error { StockTradeMessage(text: error) }
            if openedScope == store.scope, let detail {
                StockTradeCard {
                    Text(record.name).font(.headline).padding(.bottom, 12)
                    Text(detail.item.string("reason")).font(.subheadline).padding(.bottom, 16)
                    LabeledContent("邮件投递", value: detail.item.emailStatus).font(.subheadline).padding(.vertical, 12)
                    Divider()
                    LabeledContent("手机推送", value: "尚未接入").font(.subheadline).padding(.vertical, 12)
                    DisclosureGroup("规则事件详情") { StockTradeFields(fields: detail.item.fields.filter { !["channels", "alert_key"].contains($0.key) }).padding(.top, 12) }.font(.subheadline).padding(.bottom, 16)
                    Button { navigation.push(.stock(record, store.run)) }
                    label: { Text("查看股票") }.buttonStyle(StockTradeAppearance.action)
                }
                StockTradeFreshness(publishedAt: detail.publishedAt, dataAsOf: detail.dataAsOf, stale: detail.stale).padding(.horizontal, 4)
            } else if openedScope != nil && openedScope != store.scope { Text("账号或连接已切换，请返回重新打开。") }
            else if error == nil { ProgressView("读取提醒详情…") }
            StockTradeFootnote(text: "规则事件与纸面模拟记录，不是券商成交回报。")
        }
        .navigationTitle("Cerno").navigationBarTitleDisplayMode(.inline)
        .task(id: store.scope) {
            guard openedScope == nil || openedScope == store.scope else { detail = nil; return }
            openedScope = store.scope
            do {
                guard let snapshotID else { throw StockTradeFailure.invalidResponse }
                detail = try await store.read(["alerts", record.id], query: [.init(name: "snapshotId", value: snapshotID)], as: StockTradeDetail.self)
                guard detail?.snapshotId == snapshotID, detail?.item.id == record.id else { detail = nil; throw StockTradeFailure.invalidResponse }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct StockTradeHealthView: View {
    @ObservedObject var store: StockTradeStore
    @State private var detail: StockTradeDetail?
    @State private var error: String?
    @State private var displayedScope: UUID?
    var body: some View {
        StockTradeScreen {
            StockTradeHeading(title: "调度与后台状态", subtitle: "核对服务、数据与自动任务")
            if let error { StockTradeMessage(text: error) }
            if let error = store.workflowError { StockTradeMessage(text: error) }
            StockTradeMonitorControlStatus(store: store)
            StockTradeCard {
                VStack(spacing: 14) {
                    LabeledContent("执行服务", value: store.workflowOnline ? "在线 · 心跳正常" : "尚未确认在线").font(.subheadline)
                    Divider()
                    LabeledContent("调度时区", value: "Asia/Shanghai").font(.subheadline)
                    Divider()
                    LabeledContent("行情日期", value: store.run?.dataAsOf ?? "尚未载入").font(.subheadline)
                    Divider()
                    LabeledContent("最新发布", value: store.run.map { StockTradeTime.display($0.publishedAt) } ?? "尚无快照").font(.subheadline)
                }
                if let task = store.activeWorkflow { StockTradeWorkflowRow(task: task).padding(.top, 14) }
                if displayedScope == store.scope, let detail {
                    DisclosureGroup("监控采样与调度详情") { StockTradeFields(fields: detail.item.fields).padding(.top, 12) }.font(.subheadline).padding(.top, 14)
                    StockTradeFreshness(publishedAt: detail.publishedAt, dataAsOf: detail.dataAsOf, stale: detail.stale).padding(.top, 14)
                }
            }
            Button("刷新状态") { Task { await load() } }.buttonStyle(HakoActionButtonStyle(primary: false, outlined: true))
            StockTradeFootnote(text: "自动任务沿用后台调度计划，手动选股在工作台启动。执行服务心跳与监控采样状态分别展示；刷新只读取状态。")
        }.navigationTitle("Cerno").navigationBarTitleDisplayMode(.inline).task(id: store.scope) { await load() }.refreshable { await load() }
    }
    private func load() async {
        error = nil
        await store.refreshWorkflows()
        do { detail = try await store.read(["health"], as: StockTradeDetail.self); displayedScope = store.scope }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
