import SwiftUI

struct StockTradeChart: View {
    let bars: [StockTradeBar] // Ascending by actual trading date.
    @Binding var visibleCount: Int
    let period: String
    let weeklyWindows: Set<Int>
    @State private var selectedDate: String?
    @State private var initialCount: Int?
    @Environment(\.colorScheme) private var appearance
    private var visible: [StockTradeBar] { Array(bars.suffix(max(1, visibleCount))) }
    private var selected: StockTradeBar? { visible.first { $0.date == selectedDate } }
    private var lines: [(String, String, Color)] {
        period == "1d" ? [("short", "知行短期", .orange), ("long", "知行多空", .blue)] :
            [(5, Color.orange), (10, Color.green), (20, Color.blue), (60, Color.purple)].filter { weeklyWindows.contains($0.0) }.map { ("ma\($0.0)", "MA\($0.0)", $0.1) }
    }
    private var rising: Color { appearance == .dark ? Color(red: 0.95, green: 0.49, blue: 0.51) : Color(red: 0.75, green: 0.24, blue: 0.27) }
    private var falling: Color { appearance == .dark ? Color(red: 0.40, green: 0.73, blue: 0.61) : Color(red: 0.22, green: 0.51, blue: 0.42) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                ForEach(lines, id: \.0) { line in Text(line.1).foregroundStyle(line.2) }
                Spacer()
                Text("成交量 · 手").foregroundStyle(.secondary)
            }.font(.caption)
            if let selected {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selected.date + (selected.isComplete ? "" : " · 周期未完成"))
                    Text("开 \(price(selected.open))　高 \(price(selected.high))　低 \(price(selected.low))　收 \(price(selected.close))")
                    Text("成交量 \(selected.volume.formatted()) 手" + (selected.amount.map { " · 成交额 \($0.formatted()) 千元" } ?? " · 成交额未提供"))
                }.font(.caption).monospacedDigit().accessibilityElement(children: .combine)
            } else { Text("长按后拖动查看 OHLC · 双指缩放").font(.caption).foregroundStyle(.secondary) }
            GeometryReader { geometry in
                Canvas { context, size in draw(context: &context, size: size) }
                    .contentShape(Rectangle())
                    .gesture(LongPressGesture(minimumDuration: 0.18).sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { value in
                            if case .second(true, let drag?) = value {
                                let width = max(1, geometry.size.width - 48)
                                let index = max(0, min(visible.count - 1, Int(drag.location.x / width * Double(visible.count))))
                                if visible.indices.contains(index) { selectedDate = visible[index].date }
                            }
                        })
                    .simultaneousGesture(MagnifyGesture().onChanged { value in
                        if initialCount == nil { initialCount = min(visibleCount, bars.count) }
                        let count = Int(Double(initialCount ?? 60) / max(0.1, Double(value.magnification)))
                        visibleCount = max(min(20, bars.count), min(bars.count, count)); selectedDate = nil
                    }.onEnded { _ in initialCount = nil })
            }.frame(height: 290)
            HStack {
                Button { visibleCount = min(bars.count, visibleCount + 20); selectedDate = nil } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel("缩小 K 线图").frame(minWidth: 44, minHeight: 44).disabled(visibleCount >= bars.count)
                Spacer()
                Text("近 \(visible.count) 根").font(.caption).monospacedDigit()
                Spacer()
                Button { visibleCount = max(min(20, bars.count), visibleCount - 20); selectedDate = nil } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("放大 K 线图").frame(minWidth: 44, minHeight: 44).disabled(visible.count <= 20)
            }.buttonStyle(.plain)
            if !visible.isEmpty {
                HStack {
                    Button("上一根") { move(-1) }
                    Spacer()
                    Button("收起读数") { selectedDate = nil }.disabled(selectedDate == nil)
                    Spacer()
                    Button("下一根") { move(1) }
                }.font(.caption).frame(minHeight: 44)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("前复权 K 线、后台指标与成交量；红涨绿跌。使用上一根和下一根查看数据。")
        .onChange(of: bars.map(\.date)) { _, _ in selectedDate = nil }
    }
    private func price(_ n: Double) -> String { n.formatted(.number.precision(.fractionLength(2))) }
    private func move(_ step: Int) {
        let index = selectedDate.flatMap { date in visible.firstIndex { $0.date == date } } ?? (step < 0 ? visible.count : -1)
        let next = max(0, min(visible.count - 1, index + step))
        if visible.indices.contains(next) { selectedDate = visible[next].date }
    }
    private func draw(context: inout GraphicsContext, size: CGSize) {
        let rows = visible
        guard !rows.isEmpty else { return }
        let width = max(1, size.width - 48), top = 10.0, priceHeight = 180.0, volumeBottom = 257.0
        let range = StockTradeChartData.range(rows), step = width / Double(rows.count), bodyWidth = max(1, step * 0.62)
        let y: (Double) -> Double = { top + (range.upperBound - $0) / (range.upperBound - range.lowerBound) * priceHeight }
        for index in 0...3 {
            let price = range.upperBound - (range.upperBound - range.lowerBound) * Double(index) / 3
            let yy = y(price)
            var grid = Path(); grid.move(to: CGPoint(x: 0, y: yy)); grid.addLine(to: CGPoint(x: width, y: yy))
            context.stroke(grid, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
            context.draw(Text(price.formatted(.number.precision(.fractionLength(2)))).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: width + 5, y: yy), anchor: .leading)
        }
        let volumeMax = max(1, rows.map(\.volume).max() ?? 1)
        for (index, bar) in rows.enumerated() {
            let x = step * (Double(index) + 0.5), color = bar.close >= bar.open ? rising : falling
            var wick = Path(); wick.move(to: CGPoint(x: x, y: y(bar.high))); wick.addLine(to: CGPoint(x: x, y: y(bar.low)))
            context.stroke(wick, with: .color(color), lineWidth: 1)
            context.fill(Path(CGRect(x: x - bodyWidth / 2, y: min(y(bar.open), y(bar.close)), width: bodyWidth, height: max(1, abs(y(bar.open) - y(bar.close))))), with: .color(color))
            let height = bar.volume / volumeMax * 43
            context.fill(Path(CGRect(x: x - bodyWidth / 2, y: volumeBottom - height, width: bodyWidth, height: height)), with: .color(color.opacity(0.5)))
        }
        for (key, _, color) in lines {
            var path = Path(), started = false
            for index in rows.indices {
                guard let average = rows[index].lines[key] ?? nil else { started = false; continue }
                let point = CGPoint(x: step * (Double(index) + 0.5), y: y(average))
                if started { path.addLine(to: point) } else { path.move(to: point); started = true }
            }
            context.stroke(path, with: .color(color), lineWidth: 1)
        }
        for index in Set([0, rows.count / 2, rows.count - 1]).sorted() {
            let anchor: UnitPoint = index == 0 ? .leading : index == rows.count - 1 ? .trailing : .center
            let x = index == 0 ? 0 : index == rows.count - 1 ? width : width / 2
            context.draw(Text(String(rows[index].date.suffix(5))).font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: x, y: 280), anchor: anchor)
        }
        if let date = selectedDate, let index = rows.firstIndex(where: { $0.date == date }) {
            let x = step * (Double(index) + 0.5), yy = y(rows[index].close)
            var path = Path(); path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: volumeBottom))
            path.move(to: CGPoint(x: 0, y: yy)); path.addLine(to: CGPoint(x: width, y: yy))
            context.stroke(path, with: .color(.secondary), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
        }
    }
}

struct StockTradeStockView: View {
    @ObservedObject var store: StockTradeStore
    let record: StockTradeRecord
    let run: StockTradeRun?
    @State private var tab = Tab.chart
    @State private var period = "1d"
    @State private var bars: [StockTradeBar] = []
    @State private var response: StockTradeBars?
    @State private var review: StockTradeDetail?
    @State private var message: String?
    @State private var reviewError: String?
    @State private var loading = false
    @State private var visibleCount = 60
    @State private var requestedCount = 120
    @State private var weeklyWindows: Set<Int> = [5, 10, 20, 60]
    @State private var openedScope: UUID?
    private enum Tab: String, CaseIterable { case chart = "K 线", reason = "评分与原因" }
    private var key: String { "\(store.scope)|\(record.symbol)|\(period)|\(run?.snapshotId ?? "")" }
    var body: some View {
        Group {
            if let openedScope, openedScope != store.scope {
                ContentUnavailableView("账号或连接已切换", systemImage: "person.crop.circle", description: Text("请返回并重新打开股票。"))
            } else { content }
        }.onAppear { if openedScope == nil { openedScope = store.scope } }
    }
    private var content: some View {
        List {
            Section {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(record.name).font(.title2.weight(.semibold))
                        Text(record.symbol).font(.caption).foregroundStyle(.secondary)
                        if let last = bars.last {
                            Text(last.close, format: .number.precision(.fractionLength(2))).font(.largeTitle).monospacedDigit()
                            Text(last.date + " · 周期收盘价 / 元").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button { store.toggleFavorite(record) } label: {
                        Image(systemName: store.favorites.contains { $0.symbol == record.symbol } ? "star.fill" : "star")
                            .frame(minWidth: 44, minHeight: 44)
                    }.buttonStyle(.plain).accessibilityLabel(store.favorites.contains { $0.symbol == record.symbol } ? "移除自选" : "加入自选")
                }.stockTradeSeparator()
                HakoUnderlineTabs(title: "股票详情", options: Tab.allCases, selection: $tab) { $0.rawValue }.stockTradeSeparator()
            }
            if tab == .chart { chartSection }
            else { reasonSection }
        }
        .navigationTitle("单股看盘").navigationBarTitleDisplayMode(.inline)
        .task(id: key) { bars = []; response = nil; await loadBars(append: false); await loadRequestedBars() }
        .task(id: requestedCount) { await loadRequestedBars() }
        .task(id: "\(store.scope)|\(tab.rawValue)") { if tab == .reason { await loadReview() } }
    }
    @ViewBuilder private var chartSection: some View {
        Section {
            Picker("行情周期", selection: $period) { Text("日 K").tag("1d"); Text("周 K").tag("1w") }.pickerStyle(.segmented)
            Picker("显示 K 线数量", selection: $requestedCount) {
                Text("近 60 根").tag(60); Text("近 120 根").tag(120); Text("近 250 根").tag(250); Text("全部").tag(0)
            }.stockTradeSeparator()
            if period == "1w" {
                ForEach([5, 10, 20, 60], id: \.self) { window in
                    Toggle("MA\(window)", isOn: Binding(get: { weeklyWindows.contains(window) }, set: { value in
                        if value { weeklyWindows.insert(window) } else { weeklyWindows.remove(window) }
                    })).stockTradeSeparator()
                }
            }
            if let message { StockTradeMessage(text: message) }
            if !bars.isEmpty { StockTradeChart(bars: bars, visibleCount: $visibleCount, period: period, weeklyWindows: weeklyWindows) }
            if loading { ProgressView("读取行情快照…") }
            if !loading && bars.isEmpty { Text("此快照没有可用行情。").foregroundStyle(.secondary) }
            if response?.nextCursor != nil { Button("加载更早 K 线") { Task { await loadBars(append: true) } }.disabled(loading) }
            if let response {
                if !response.isComplete { Label("包含尚未完成的 K 线周期", systemImage: "clock").font(.caption).foregroundStyle(.orange) }
                StockTradeFreshness(publishedAt: response.publishedAt, dataAsOf: response.coverageEnd, stale: response.stale)
                LabeledContent("行情覆盖", value: response.coverageStart + " — " + response.coverageEnd).font(.caption).stockTradeSeparator()
            }
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("前复权 qfq · 来源缓存，整段复权基点尚未验证。仅供看盘，不作为已验证的回测行情源。")
                if period == "1w" { Text("周线以周五为桶终点；当前周或数据缺口可能导致周期未完成。") }
                Text("只提供已发布日线与周线，不提供分钟或实时行情。成交量单位为手，成交额缺失时不估算。")
            }
        }
    }
    @ViewBuilder private var reasonSection: some View {
        if let reviewError { Section { StockTradeMessage(text: reviewError) } }
        if let review {
            Section("确定性规则复评") { StockTradeFields(fields: review.item.fields) }
            Section { StockTradeFreshness(publishedAt: review.publishedAt, dataAsOf: review.dataAsOf, stale: review.stale) }
        } else if reviewError == nil { Section { ProgressView("读取复评…") } }
        Section { Text("保留后台评分、排名、风险和待验证事项，不在手机重新打分。规则结果不代表实际交易指令。").font(.footnote).foregroundStyle(.secondary) }
    }
    private func loadBars(append: Bool) async {
        let activeKey = key
        loading = true; message = nil
        defer { if activeKey == key { loading = false } }
        do {
            guard let snapshot = run?.snapshotId else { throw StockTradeFailure.api(status: 503, code: "snapshot_unavailable", requestID: "", retryable: true) }
            var query = [URLQueryItem(name: "period", value: period), .init(name: "snapshotId", value: snapshot), .init(name: "limit", value: "120")]
            if append, let cursor = response?.nextCursor { query.append(.init(name: "cursor", value: cursor)) }
            let value: StockTradeBars = try await store.read(["stocks", record.symbol, "bars"], query: query, as: StockTradeBars.self)
            guard key == activeKey else { return }
            _ = try value.validated(symbol: record.symbol, period: period, snapshot: snapshot)
            let older = Array(value.items.reversed())
            if append {
                guard Set(bars.map(\.date)).isDisjoint(with: older.map(\.date)),
                      older.last.map({ $0.date < (bars.first?.date ?? "9999") }) != false else { throw StockTradeFailure.invalidResponse }
                bars = older + bars
            } else { bars = older; visibleCount = requestedCount == 0 ? bars.count : requestedCount }
            response = value
        } catch is CancellationError { }
        catch { if key == activeKey { message = error.localizedDescription } }
    }
    private func loadRequestedBars() async {
        let activeKey = key
        repeat {
            guard activeKey == key, response?.nextCursor != nil, !loading,
                  requestedCount == 0 || bars.count < requestedCount else { break }
            let previous = response?.nextCursor
            await loadBars(append: true)
            if message != nil || previous == response?.nextCursor { break }
        } while !Task.isCancelled
        if activeKey == key { visibleCount = requestedCount == 0 ? bars.count : requestedCount }
    }
    private func loadReview() async {
        reviewError = nil
        do {
            guard let run else { throw StockTradeFailure.api(status: 503, code: "snapshot_unavailable", requestID: "", retryable: true) }
            let value: StockTradeDetail = try await store.read(["runs", run.runId, "reviews", record.symbol], query: [.init(name: "snapshotId", value: run.snapshotId)], as: StockTradeDetail.self)
            guard value.snapshotId == run.snapshotId, value.item.symbol == record.symbol else { throw StockTradeFailure.invalidResponse }
            review = value
        } catch is CancellationError { }
        catch { reviewError = error.localizedDescription }
    }
}
