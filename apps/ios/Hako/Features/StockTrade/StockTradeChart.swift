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
            if let selected {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selected.date + (selected.isComplete ? "" : " · 周期未完成"))
                    Text("开 \(price(selected.open))　高 \(price(selected.high))　低 \(price(selected.low))　收 \(price(selected.close))")
                    Text("成交量 \(selected.volume.formatted()) 手" + (selected.amount.map { " · 成交额 \($0.formatted()) 千元" } ?? " · 成交额未提供"))
                }.font(.caption).monospacedDigit().accessibilityElement(children: .combine)
            } else { Text("长按后拖动查看 OHLC · 双指缩放").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("当前显示 \(visible.count) 根")
                Spacer()
                Text("缩放")
            }.font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(min(max(1, visibleCount), max(1, bars.count))) }, set: { value in
                visibleCount = min(bars.count, max(1, Int(value))); selectedDate = nil
            }), in: 1...Double(max(2, bars.count)), step: 1)
                .tint(StockTradeAppearance.tint).disabled(bars.count < 2).accessibilityLabel("缩放 K 线")
            if period == "1d" {
                HStack {
                    ForEach(lines, id: \.0) { line in Text(line.1).foregroundStyle(line.2) }
                }.font(.caption)
            }
            DisclosureGroup("逐根读数与缩放") {
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
            }.font(.caption)
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
        let candleRange = StockTradeChartData.range(rows)
        let indicators = rows.flatMap { bar in lines.compactMap { bar.lines[$0.0] ?? nil } }
        let range = min(candleRange.lowerBound, indicators.min() ?? candleRange.lowerBound)...max(candleRange.upperBound, indicators.max() ?? candleRange.upperBound)
        let step = width / Double(rows.count), bodyWidth = max(1, step * 0.62)
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
    @State private var showReview = false
    @State private var period = "1d"
    @State private var bars: [StockTradeBar] = []
    @State private var response: StockTradeBars?
    @State private var review: StockTradeDetail?
    @State private var message: String?
    @State private var reviewError: String?
    @State private var loading = false
    @State private var visibleCount = 40
    @State private var requestedCount = 120
    @State private var weeklyWindows: Set<Int> = [5, 10, 20, 60]
    @State private var openedScope: UUID?
    private var chartBars: [StockTradeBar] { Array(bars.suffix(requestedCount == 0 ? bars.count : requestedCount)) }
    private var key: String { "\(store.scope)|\(record.symbol)|\(period)|\(run?.snapshotId ?? "")" }
    var body: some View {
        Group {
            if let openedScope, openedScope != store.scope {
                ContentUnavailableView("账号或连接已切换", systemImage: "person.crop.circle", description: Text("请返回并重新打开股票。"))
            } else { content }
        }.onAppear { if openedScope == nil { openedScope = store.scope } }
    }
    private var content: some View {
        StockTradeScreen {
            StockTradeHeading(title: record.name, subtitle: record.symbol + " · " + (run?.dataAsOf ?? "已发布行情"), action: store.favorites.contains { $0.symbol == record.symbol } ? "已关注" : "＋ 关注") { store.toggleFavorite(record) }
            HStack(alignment: .firstTextBaseline) {
                if let last = bars.last { Text(last.close, format: .number.precision(.fractionLength(2))).font(.largeTitle.weight(.bold)).monospacedDigit() }
                else { Text("—").font(.largeTitle) }
                Spacer()
                Text("周期收盘 / 元").font(.footnote).foregroundStyle(.secondary)
            }
            StockTradeCard {
                Picker("行情周期", selection: $period) { Text("日线").tag("1d"); Text("周线").tag("1w") }.pickerStyle(.segmented).padding(.bottom, 12)
                HStack {
                    Text("K 线（元）· 成交量").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Picker("显示 K 线数量", selection: $requestedCount) {
                        Text("近 60 根").tag(60); Text("近 120 根").tag(120); Text("近 250 根").tag(250); Text("全部").tag(0)
                    }.pickerStyle(.menu).labelsHidden()
                }
                if let message { StockTradeMessage(text: message) }
                if !bars.isEmpty { StockTradeChart(bars: chartBars, visibleCount: $visibleCount, period: period, weeklyWindows: weeklyWindows) }
                if loading { ProgressView("读取行情快照…").padding(.vertical, 12) }
                if !loading && bars.isEmpty { Text("此快照没有可用行情。").font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 18) }
                if period == "1w" {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) { weeklyControls }
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) { weeklyControls }
                    }.padding(.top, 8)
                }
                if response?.nextCursor != nil { Button("加载更早 K 线") { Task { await loadBars(append: true) } }.disabled(loading).font(.footnote).padding(.top, 10) }
                if let response, !response.isComplete { Label("包含尚未完成的 K 线周期", systemImage: "clock").font(.caption).foregroundStyle(.orange).padding(.top, 10) }
            }
            StockTradeSectionLabel(title: "候选与复评")
            StockTradeCard {
                HStack {
                    Text("规则复评").font(.headline)
                    Spacer()
                    if let score = record["total_score"].number { Text("规则评分 " + score.formatted()).font(.caption).foregroundStyle(StockTradeAppearance.tint) }
                }
                if !record.reason.isEmpty { Text(record.reason).font(.subheadline).padding(.vertical, 12) }
                LabeledContent("选股日", value: run?.dataAsOf ?? "未提供").font(.subheadline).padding(.vertical, 12)
                if case .null = record["brick_growth"] { }
                else { Divider(); LabeledContent("砖型增长", value: record["brick_growth"].text).font(.subheadline).padding(.vertical, 12) }
                DisclosureGroup("复评依据与风险", isExpanded: $showReview) {
                    if let reviewError { StockTradeMessage(text: reviewError) }
                    else if let review { StockTradeFields(fields: review.item.fields).padding(.top, 10) }
                    else { ProgressView("读取复评…").padding(.vertical, 12) }
                }.font(.subheadline)
            }
            if let response { StockTradeFreshness(publishedAt: response.publishedAt, dataAsOf: response.coverageEnd, stale: response.stale).padding(.horizontal, 4) }
            StockTradeFootnote(text: "前复权 qfq · 来源缓存，整段复权基点尚未验证。仅供看盘，不作为已验证的回测行情源。仅提供已发布日线与周线，无实时或分钟报价。")
            if period == "1w" { StockTradeFootnote(text: "周线以周五为桶终点；当前周或数据缺口可能导致周期未完成。") }
        }
        .navigationTitle("Cerno").navigationBarTitleDisplayMode(.inline)
        .task(id: key) { bars = []; response = nil; review = nil; await loadBars(append: false); await loadRequestedBars() }
        .task(id: requestedCount) { await loadRequestedBars() }
        .task(id: "\(key)|\(showReview)") { if showReview { await loadReview() } }
    }
    @ViewBuilder private var weeklyControls: some View {
        ForEach([5, 10, 20, 60], id: \.self) { window in
            Button {
                if weeklyWindows.contains(window) { weeklyWindows.remove(window) } else { weeklyWindows.insert(window) }
            } label: { Label("MA\(window)", systemImage: weeklyWindows.contains(window) ? "checkmark.square.fill" : "square").font(.caption).fixedSize().frame(minHeight: 44) }
                .buttonStyle(.plain).foregroundStyle(weeklyWindows.contains(window) ? StockTradeAppearance.tint : Color.secondary)
                .accessibilityAddTraits(weeklyWindows.contains(window) ? [.isSelected] : [])
        }
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
            } else { bars = older; visibleCount = min(40, bars.count) }
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
        if activeKey == key { visibleCount = min(max(1, visibleCount), max(1, chartBars.count)) }
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
