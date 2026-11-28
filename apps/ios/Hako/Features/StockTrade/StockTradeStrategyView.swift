import SwiftUI

extension StockTradeStore {
    func strategyConfiguration() async throws -> StockTradeStrategyConfiguration {
        let value = try await read(["strategy"], as: StockTradeStrategyConfiguration.self)
        guard value.valid else { throw StockTradeFailure.invalidResponse }
        return value
    }
    func saveStrategy(_ value: StockTradeStrategySettings, revision: String) async throws -> StockTradeStrategyConfiguration {
        struct Save: Encodable { let expectedRevision: String; let settings: StockTradeStrategySettings }
        let result = try await read(["strategy"], method: "PUT", payload: JSONEncoder().encode(Save(expectedRevision: revision, settings: value)), as: StockTradeStrategyConfiguration.self)
        guard result.valid, result.settings == value else { throw StockTradeFailure.invalidResponse }
        return result
    }
}

struct StockTradeStrategySheet: View {
    @ObservedObject var store: StockTradeStore
    @State private var loaded: StockTradeStrategyConfiguration?
    @State private var draft: StockTradeStrategySettings?
    @State private var error: String?
    @State private var busy = false
    @State private var uncertain = false
    @State private var reloadConfirmation = false
    @State private var openedScope: UUID?
    @State private var fieldsRevision = UUID()
    @Environment(\.dismiss) private var dismiss
    private var changed: Bool { draft != nil && draft != loaded?.settings }
    private var sameScope: Bool { openedScope == store.scope }
    var body: some View {
        SettingsSheet(title: "策略配置", hasChanges: changed, isBusy: busy,
            saveEnabled: changed && draft?.valid == true && sameScope && !uncertain,
            onSave: { Task { await save() } }, saveInProgress: busy) {
            Form {
                if let draft {
                    StockTradeStrategyFields(value: Binding(get: { self.draft ?? draft }, set: { self.draft = $0 }))
                        .id(fieldsRevision)
                    if !draft.valid {
                        Section { Text("请检查数值范围，至少选择一个板块；四个知行周期需从小到大排列。").font(.footnote).foregroundStyle(.orange) }
                    }
                } else if busy { ProgressView("读取策略配置…") }
                if !sameScope && openedScope != nil { Text("账号或连接已切换，请关闭后重新打开。").foregroundStyle(.orange) }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.orange) } }
                Section {
                    if let loaded {
                        LabeledContent("配置版本", value: String(loaded.revision.prefix(12))).font(.caption.monospaced())
                        if let at = loaded.updatedAt { Text("保存于 " + StockTradeTime.display(at)).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("这是此 Cerno 后台的共享配置。保存后用于新任务，已提交任务继续使用提交时的配置；保存不会启动选股或修改历史结果。").font(.footnote).foregroundStyle(.secondary)
                    Button(loaded == nil ? "重新读取" : "重新读取并替换本页内容") {
                        if changed { reloadConfirmation = true } else { Task { await load() } }
                    }.disabled(busy || !sameScope)
                }
            }.disabled(busy || openedScope != nil && !sameScope)
        }
        .task {
            openedScope = store.scope
            await load()
        }
        .alert("丢弃本页修改并重新读取？", isPresented: $reloadConfirmation) {
            Button("取消", role: .cancel) {}
            Button("重新读取", role: .destructive) { Task { await load() } }
        }
    }
    private func load() async {
        guard sameScope, !busy else { return }
        busy = true; defer { busy = false }
        do {
            let result = try await store.strategyConfiguration()
            guard sameScope else { return }
            loaded = result; draft = result.settings; error = nil; uncertain = false
            fieldsRevision = UUID()
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
    private func save() async {
        guard sameScope, !busy, !uncertain, let draft, draft.valid, let loaded else { return }
        busy = true; defer { busy = false }
        do {
            let result = try await store.saveStrategy(draft, revision: loaded.revision)
            guard sameScope else { return }
            self.loaded = result; self.draft = result.settings; dismiss()
        } catch {
            // Keep the draft and require a fresh read before another write if the reply was lost.
            uncertain = true
            self.error = error.localizedDescription + " 请重新读取核对已保存配置后再修改。"
        }
    }
}

private struct StockTradeStrategyFields: View {
    @Binding var value: StockTradeStrategySettings
    var body: some View {
        Section("股票范围") {
            Toggle("主板", isOn: $value.includeMainBoard)
            Toggle("创业板", isOn: $value.includeGrowthBoard)
            Toggle("科创板", isOn: $value.includeStarBoard)
            Toggle("北交所", isOn: $value.includeBeijing)
            Toggle("正式推荐排除 ST", isOn: $value.excludeST)
            Toggle("正式推荐排除停牌股", isOn: $value.excludeSuspended)
            integer("最短上市天数 · 0–1000 个自然日", $value.minListingDays)
        }
        Section("初选参数") {
            integer("流动性池股票数 · 1–6000", $value.liquidityCount)
            integer("成交额窗口 · 1–250 个交易日", $value.turnoverDays)
            Toggle("启用 B1 策略", isOn: $value.b1Enabled)
            decimal("KDJ J 值上限 · −100–100", $value.jThreshold)
            decimal("J 值分位阈值 · 0–1", $value.jQuantile)
            ForEach(0..<4, id: \.self) { index in
                integer("知行均线周期 \(index + 1) · 1–500", Binding(get: { value.zxPeriods[index] }, set: { value.zxPeriods[index] = $0 }))
            }
        }
        Section("推荐门槛") {
            decimal("最低总分 · 0–5", $value.minScore)
            decimal("最低排序分 · 0–100", $value.minRankScore)
            decimal("最低市场状态分 · 0–1", $value.minMarketScore)
            decimal("最高风险分 · 0–100", $value.maxRiskScore)
            integer("最多推荐股票数 · 1–20", $value.recommendationCount)
            Text("还需通过既有风险否决规则；符合条件的股票不足时，推荐数量可以少于上限。").font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func integer(_ title: String, _ binding: Binding<Int>) -> some View {
        StockTradeStrategyInteger(title: title, value: binding)
    }
    private func decimal(_ title: String, _ binding: Binding<Double>) -> some View {
        StockTradeStrategyDecimal(title: title, value: binding)
    }
}

private struct StockTradeStrategyInteger: View {
    let title: String
    @Binding var value: Int
    @State private var text: String
    init(title: String, value: Binding<Int>) {
        self.title = title; _value = value; _text = State(initialValue: String(value.wrappedValue))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            TextField(title, text: $text).keyboardType(.numberPad).accessibilityLabel(title)
                .onChange(of: text) { _, next in value = Int(next) ?? Int.min }
        }
    }
}

private struct StockTradeStrategyDecimal: View {
    let title: String
    @Binding var value: Double
    @State private var text: String
    init(title: String, value: Binding<Double>) {
        self.title = title; _value = value; _text = State(initialValue: String(value.wrappedValue))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            TextField(title, text: $text).keyboardType(.numbersAndPunctuation).accessibilityLabel(title)
                .onChange(of: text) { _, next in value = Double(next.replacingOccurrences(of: ",", with: ".")) ?? .nan }
        }
    }
}
