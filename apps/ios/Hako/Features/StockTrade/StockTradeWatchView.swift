import SwiftUI

struct StockTradeWatchView: View {
    @ObservedObject var store: StockTradeStore
    @State private var mode = Mode.mine
    @State private var query = ""
    @State private var items: [StockTradeRecord] = []
    @State private var page: StockTradePage<StockTradeRecord>?
    @State private var loading = false
    @State private var message: String?
    @State private var displayedScope: UUID?
    private enum Mode: String, CaseIterable { case mine = "我的关注", search = "搜索" }
    private var key: String { "\(store.scope)|\(store.run?.snapshotId ?? "")|\(mode)|\(query)" }
    var body: some View {
        VStack(spacing: 0) {
            HakoUnderlineTabs(title: "关注范围", options: Mode.allCases, selection: $mode) { $0.rawValue }.padding(.horizontal, 18)
            Group {
                List {
                    if mode == .search {
                        Section {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("名称或完整股票代码").font(.subheadline).foregroundStyle(.secondary)
                                TextField("例如 600519.SH", text: $query).accessibilityLabel("搜索股票")
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                            }.stockTradeSeparator()
                        }
                    }
                    if let message { Section { StockTradeMessage(text: message) } }
                    Section {
                        ForEach(mode == .mine ? store.favorites : (displayedScope == store.scope ? items : [])) { record in
                            NavigationLink { StockTradeStockView(store: store, record: record, run: store.run) }
                            label: { StockTradeStockRow(record: record) }.stockTradeSeparator()
                        }
                        if loading { ProgressView("搜索已发布行情…") }
                        else if (mode == .mine ? store.favorites : items).isEmpty { Text(mode == .mine ? "尚无自选，可从股票详情加入。" : "没有匹配的已发布行情。").foregroundStyle(.secondary) }
                        if mode == .search, page?.nextCursor != nil { Button("加载更多") { Task { await search(append: true) } }.disabled(loading) }
                    } footer: {
                        Text(mode == .mine ? "自选仅保存在本机，按后台、issuer 和 subject 隔离；加入自选不会启用后台监控。自选中的名称与评分来自加入时的记录，详情重新读取当前快照。" : "只检索已发布行情，不会抓取新股票。")
                    }
                    if mode == .search, displayedScope == store.scope, let page {
                        Section { StockTradeFreshness(publishedAt: page.publishedAt, dataAsOf: page.dataAsOf, stale: page.stale) }
                    }
                }.listStyle(.insetGrouped)
            }
        }
        .task(id: key) {
            guard mode == .search else { return }
            items = []; page = nil
            do { try await Task.sleep(for: .milliseconds(300)); await search(append: false) } catch { }
        }
    }
    private func search(append: Bool) async {
        let activeKey = key
        loading = true; message = nil
        defer { if activeKey == key { loading = false } }
        do {
            var parameters = [URLQueryItem(name: "q", value: String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))), .init(name: "limit", value: "50")]
            if let snapshot = append ? page?.snapshotId : store.run?.snapshotId { parameters.append(.init(name: "snapshotId", value: snapshot)) }
            if append, let cursor = page?.nextCursor { parameters.append(.init(name: "cursor", value: cursor)) }
            let value: StockTradePage<StockTradeRecord> = try await store.read(["stocks"], query: parameters, as: StockTradePage<StockTradeRecord>.self)
            guard key == activeKey else { return }
            guard value.items.allSatisfy({ StockTradeStore.validSymbol($0.symbol) }),
                  !append || (value.snapshotId == page?.snapshotId && Set(items.map(\.symbol)).isDisjoint(with: value.items.map(\.symbol))) else { throw StockTradeFailure.invalidResponse }
            items = append ? items + value.items : value.items; page = value; displayedScope = store.scope
        } catch is CancellationError { }
        catch { if key == activeKey { message = error.localizedDescription } }
    }
}

enum StockTradeFeedKind: String { case monitor, alerts }

struct StockTradeFeedView: View {
    @ObservedObject var store: StockTradeStore
    let kind: StockTradeFeedKind
    @State private var state = ""
    @State private var items: [StockTradeRecord] = []
    @State private var page: StockTradePage<StockTradeRecord>?
    @State private var message: String?
    @State private var loading = false
    @State private var displayedScope: UUID?
    private var key: String { "\(store.scope)|\(kind.rawValue)|\(state)" }

    var body: some View {
        List {
            if kind == .monitor {
                Section {
                    NavigationLink("提醒记录") { StockTradeFeedView(store: store, kind: .alerts).navigationTitle("提醒记录") }.stockTradeSeparator()
                }
                Section {
                    Picker("监控状态", selection: $state) {
                        Text("全部").tag(""); Text("规则观察").tag("watch")
                        Text("模拟持有").tag("open"); Text("模拟结束").tag("closed")
                    }.stockTradeSeparator()
                } footer: { Text("以下均为规则观察与纸面模拟，没有券商持仓或实际成交。") }
            }
            if let message { Section { StockTradeMessage(text: message) } }
            if displayedScope == store.scope, let page {
                Section { StockTradeFreshness(publishedAt: page.publishedAt, dataAsOf: page.dataAsOf, stale: page.stale) }
            }
            Section {
                ForEach(displayedScope == store.scope ? items : []) { record in
                    if kind == .alerts {
                        NavigationLink {
                            StockTradeAlertView(store: store, record: record, snapshotID: page?.snapshotId)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("规则提醒").font(.headline)
                                Text(record.symbol).font(.subheadline)
                                Text(record.string("reason")).font(.subheadline).foregroundStyle(.secondary)
                                Text(StockTradeTime.display(record.string("alert_time")) + " · " + record.emailStatus).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }.stockTradeSeparator()
                    } else {
                        NavigationLink { StockTradeStockView(store: store, record: record, run: store.run) } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(record.name).font(.headline)
                                Text(record.symbol + " · " + record.monitorLabel).font(.subheadline).foregroundStyle(.secondary)
                                Text("来源推荐日 " + record["source_suggestion_date"].text).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }.stockTradeSeparator()
                    }
                }
                if loading { ProgressView("读取后台快照…") }
                else if items.isEmpty { Text("暂无已发布记录。").foregroundStyle(.secondary) }
                if page?.nextCursor != nil { Button("加载更多") { Task { await load(append: true) } }.disabled(loading) }
            } footer: {
                if kind == .alerts { Text("邮件和手机推送分别记录。邮件发送成功不代表手机已收到；已读状态不会改变监控。") }
            }
        }
        .listStyle(.insetGrouped)
        .task(id: key) { items = []; page = nil; await load(append: false) }
        .refreshable { await load(append: false) }
    }
    private func load(append: Bool) async {
        let activeKey = key
        loading = true; message = nil
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
        catch { if key == activeKey { message = error.localizedDescription } }
    }
}

struct StockTradeAlertView: View {
    @ObservedObject var store: StockTradeStore
    let record: StockTradeRecord
    let snapshotID: String?
    @State private var detail: StockTradeDetail?
    @State private var error: String?
    @State private var openedScope: UUID?
    var body: some View {
        List {
            if let error { StockTradeMessage(text: error) }
            if openedScope == store.scope, let detail {
                Section("规则事件") { StockTradeFields(fields: detail.item.fields.filter { !["channels", "alert_key"].contains($0.key) }) }
                Section("通知投递") {
                    LabeledContent("邮件", value: detail.item.emailStatus).stockTradeSeparator()
                    LabeledContent("手机推送", value: "尚未接入").stockTradeSeparator()
                }
                Section { StockTradeFreshness(publishedAt: detail.publishedAt, dataAsOf: detail.dataAsOf, stale: detail.stale) }
            }
            Section {
                if openedScope == store.scope {
                    NavigationLink("查看股票") { StockTradeStockView(store: store, record: record, run: store.run) }
                } else { Text("账号或连接已切换，请返回重新打开。") }
            } footer: { Text("规则事件与纸面模拟记录，不是券商成交回报。") }
        }
        .navigationTitle("提醒详情")
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
        List {
            if let error { StockTradeMessage(text: error) }
            Section("手动任务服务") {
                LabeledContent("执行服务", value: store.workflowOnline ? "在线" : "尚未确认在线").stockTradeSeparator()
                if let task = store.activeWorkflow { StockTradeWorkflowRow(task: task).stockTradeSeparator() }
                if let error = store.workflowError { StockTradeMessage(text: error) }
            }
            if displayedScope == store.scope, let detail {
                Section("后台监控状态") { StockTradeFields(fields: detail.item.fields) }
                Section { StockTradeFreshness(publishedAt: detail.publishedAt, dataAsOf: detail.dataAsOf, stale: detail.stale) }
            }
            if let run = store.run {
                Section("完整选股") {
                    LabeledContent("数据交易日", value: run.dataAsOf).stockTradeSeparator()
                    LabeledContent("发布时间", value: StockTradeTime.display(run.publishedAt)).stockTradeSeparator()
                }
            }
            Section { Button("刷新状态") { Task { await load() } }.buttonStyle(HakoActionButtonStyle()) }
            Section { Text("状态更新时间、行情采集时间和完整选股发布时间分别展示。所有任务仍由 Python 后台调度；刷新此页只读取已发布状态。").font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("后台与数据状态").task(id: store.scope) { await load() }.refreshable { await load() }
    }
    private func load() async {
        error = nil
        await store.refreshWorkflows()
        do { detail = try await store.read(["health"], as: StockTradeDetail.self); displayedScope = store.scope }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
