import Charts
import SwiftUI

struct InvestmentBalanceSankey: View {
    let snapshot: InvestmentBalanceSnapshot
    let debtCount: Int
    @ScaledMetric(relativeTo: .caption2) private var height = 153.0

    private struct Band {
        let title: String
        let amount: Decimal
        let color: Color
    }

    var body: some View {
        let net = snapshot.net ?? 0
        let assets = snapshot.assets ?? 0
        let negative = net < 0
        let debt = Band(title: "\(debtCount)项负债", amount: snapshot.liabilities, color: InvestmentBalanceStyle.debt)
        let equity = Band(title: "净资产", amount: max(0, net), color: InvestmentBalanceStyle.equity)
        let assetsBands = InvestmentBalanceCategory.assets.map {
            Band(title: $0.rawValue, amount: snapshot.assetContribution($0) ?? 0, color: $0.color)
        }
        let deficit = Band(title: "净资产缺口", amount: -net, color: InvestmentBalanceStyle.equity)
        let left = (assetsBands + [deficit]).filter { $0.amount > 0 }
        let right = [debt, equity].filter { $0.amount > 0 }
        Canvas { context, size in
            let leftX = min(62, size.width * 0.23)
            let rightX = size.width - min(65, size.width * 0.23)
            let center = size.width / 2
            let top: CGFloat = 24
            let total = NSDecimalNumber(decimal: max(assets, snapshot.liabilities)).doubleValue
            let scale = max(0, size.height - top - 44) / max(total, 1)
            let centerTop = (size.height + top - total * scale) / 2
            draw(left, in: context, from: leftX, to: center - 3,
                 leftSide: true, top: top, bottom: size.height, centerTop: centerTop, scale: scale)
            draw(right, in: context, from: center + 3, to: rightX,
                 leftSide: false, top: top, bottom: size.height, centerTop: centerTop, scale: scale)
            let node = Path(CGRect(x: center - 3, y: centerTop, width: 6, height: total * scale))
            context.fill(node, with: .color(negative ? InvestmentBalanceStyle.debt : InvestmentBalanceStyle.asset))
            if !negative {
                context.draw(Text("总资产").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: center, y: 11))
            }
        }
        .frame(height: height)
        .accessibilityLabel(negative
            ? "总资产和净资产缺口合计为总负债，\(debtCount)项负债"
            : "各类资产汇入总资产，右侧为" + right.map(\.title).joined(separator: "和"))
    }

    private func draw(_ bands: [Band], in context: GraphicsContext, from x0: CGFloat, to x1: CGFloat,
                      leftSide: Bool, top: CGFloat, bottom: CGFloat, centerTop: CGFloat, scale: CGFloat) {
        let widths = bands.map { NSDecimalNumber(decimal: $0.amount).doubleValue * scale }
        guard !bands.isEmpty else { return }
        let spacing = min(11, max(0, bottom - top - widths.reduce(0, +)) / CGFloat(max(1, bands.count - 1)))
        let midpoint = (x0 + x1) / 2
        var outerEnd = top
        var inner = centerTop
        for (index, band) in bands.enumerated() {
            let width = widths[index]
            let preferredCenter = top + (CGFloat(index) + 0.5) * (bottom - top) / CGFloat(bands.count)
            let remaining = widths.dropFirst(index + 1).reduce(0) { $0 + $1 + spacing }
            let outer = min(bottom - remaining - width, max(outerEnd, preferredCenter - width / 2))
            let y0 = leftSide ? outer : inner
            let y1 = leftSide ? inner : outer
            if width > 0 {
                var path = Path()
                path.move(to: CGPoint(x: x0, y: y0))
                path.addCurve(to: CGPoint(x: x1, y: y1), control1: CGPoint(x: midpoint, y: y0), control2: CGPoint(x: midpoint, y: y1))
                path.addLine(to: CGPoint(x: x1, y: y1 + width))
                path.addCurve(to: CGPoint(x: x0, y: y0 + width), control1: CGPoint(x: midpoint, y: y1 + width),
                              control2: CGPoint(x: midpoint, y: y0 + width))
                path.closeSubpath()
                context.fill(path, with: .color(band.color.opacity(0.48)))
                let node = CGRect(x: leftSide ? x0 - 3 : x1, y: outer, width: 3, height: width)
                context.fill(Path(node), with: .color(band.color))
            }
            let label = Text(band.title).font(.caption2).foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: leftSide ? x0 - 6 : x1 + 6, y: outer + width / 2),
                         anchor: leftSide ? .trailing : .leading)
            inner += width
            outerEnd = outer + width + spacing
        }
    }
}

struct InvestmentBalanceTrend: View {
    let book: InvestmentBook
    let today: Date
    let hidesAmounts: Bool
    @State private var range = Range.all
    @State private var mode = Mode.balance
    @State private var selectedDate: Date?

    private enum Range: String, CaseIterable, Identifiable {
        case all = "记账以来", year = "今年", rolling = "近一年"
        var id: Self { self }

        func start(today: Date, earliest: Date) -> Date {
            let calendar = InvestmentBook.calendar
            switch self {
            case .all: return earliest
            case .year: return max(earliest, calendar.dateInterval(of: .year, for: today)?.start ?? today)
            case .rolling: return max(earliest, calendar.date(byAdding: .year, value: -1, to: today) ?? today)
            }
        }
    }

    private enum Mode: String, CaseIterable, Identifiable {
        case balance = "资产与负债", net = "净资产趋势"
        var id: Self { self }
    }

    private struct Point: Identifiable {
        let snapshot: InvestmentBalanceSnapshot
        let segment: Int
        var id: Date { snapshot.day }
    }

    var body: some View {
        let points = history()
        let selected = selectedDate.flatMap { day in
            points.min { abs($0.id.timeIntervalSince(day)) < abs($1.id.timeIntervalSince(day)) }
        } ?? points.last
        let valid = points.filter { $0.snapshot.net != nil }
        InvestmentCard {
            HStack {
                Text("资产趋势").font(.headline)
                Spacer()
                Menu {
                    Picker("趋势范围", selection: $range) {
                        ForEach(Range.allCases) { item in Text(item.rawValue).tag(item) }
                    }
                } label: {
                    Label(range.rawValue, systemImage: "chevron.down").labelStyle(.titleAndIcon)
                        .font(.caption.weight(.medium)).frame(minHeight: 38)
                }
                .tint(InvestmentBalanceStyle.accent)
                .accessibilityLabel("趋势范围，" + range.rawValue)
            }
            tabs
            if let selected, !valid.isEmpty {
                chart(valid, selected: selected, from: points.first?.id ?? selected.id)
                legend
                selection(selected.snapshot)
            } else {
                Text(points.isEmpty ? "暂无资产趋势记录。" : "暂缺报价或汇率，无法绘制资产趋势。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: range) { selectedDate = nil }
        .onChange(of: mode) { selectedDate = nil }
    }

    private var tabs: some View {
        HStack(spacing: 16) {
            ForEach(Mode.allCases) { item in
                Button {
                    mode = item
                } label: {
                    Text(item.rawValue)
                        .font(.caption.weight(mode == item ? .semibold : .regular))
                        .foregroundStyle(mode == item ? InvestmentBalanceStyle.accent : Color.secondary)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 4)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            if mode == item { Capsule().fill(InvestmentBalanceStyle.accent).frame(height: 2) }
                        }
                }.buttonStyle(.plain).accessibilityAddTraits(mode == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }.background(alignment: .bottom) { Divider() }
    }

    private func history() -> [Point] {
        guard let earliest = book.balanceEarliest else { return [] }
        let start = range.start(today: today, earliest: earliest)
        var segment = 0
        return book.balanceDates(from: start, through: today).map { date in
            let snapshot = book.balanceSnapshot(on: date, today: today)
            if snapshot.net == nil { segment += 1 }
            return Point(snapshot: snapshot, segment: segment)
        }
    }

    private func number(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }

    private func chart(_ points: [Point], selected: Point, from first: Date) -> some View {
        let start = first < today ? first : InvestmentBook.addDays(-1, to: today)
        let singlePoints = Dictionary(grouping: points, by: \.segment).values.filter { $0.count == 1 }.flatMap { $0 }
        return Chart {
            RuleMark(y: .value("零轴", 0.0)).foregroundStyle(.secondary.opacity(0.6))
            if mode == .net {
                ForEach(points) { point in
                    LineMark(x: .value("日期", point.id), y: .value("净资产", number(point.snapshot.net ?? 0)),
                             series: .value("连续区间", point.segment))
                        .foregroundStyle(InvestmentBalanceStyle.equity)
                }
                ForEach(singlePoints) { point in
                    PointMark(x: .value("日期", point.id), y: .value("净资产", number(point.snapshot.net ?? 0)))
                        .foregroundStyle(InvestmentBalanceStyle.equity)
                }
            } else {
                ForEach(InvestmentBalanceCategory.assets) { category in
                    ForEach(points) { point in
                        let lower = InvestmentBalanceCategory.assets.prefix { $0 != category }
                            .reduce(Decimal.zero) { $0 + (point.snapshot.assetContribution($1) ?? 0) }
                        let upper = lower + (point.snapshot.assetContribution(category) ?? 0)
                        AreaMark(x: .value("日期", point.id), yStart: .value("资产下界", number(lower)),
                                 yEnd: .value(category.rawValue, number(upper)),
                                 series: .value("连续区间", category.rawValue + String(point.segment)))
                            .foregroundStyle(category.color.opacity(0.54))
                    }
                }
                ForEach(points) { point in
                    AreaMark(x: .value("日期", point.id), yStart: .value("负债", -number(point.snapshot.liabilities)),
                             yEnd: .value("零轴", 0.0), series: .value("连续区间", point.segment))
                        .foregroundStyle(InvestmentBalanceStyle.debt.opacity(0.13))
                }
                ForEach(singlePoints) { point in
                    PointMark(x: .value("日期", point.id), y: .value("总资产", number(point.snapshot.assets ?? 0)))
                        .foregroundStyle(InvestmentBalanceStyle.asset)
                    PointMark(x: .value("日期", point.id), y: .value("负债", -number(point.snapshot.liabilities)))
                        .foregroundStyle(InvestmentBalanceStyle.debt)
                }
            }
            RuleMark(x: .value("所选日期", selected.id))
                .foregroundStyle(.secondary.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            if mode == .net, let net = selected.snapshot.net {
                PointMark(x: .value("日期", selected.id), y: .value("净资产", number(net)))
                    .foregroundStyle(InvestmentBalanceStyle.equity)
            }
        }
        .chartXScale(domain: start...today)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { axis in
                if let date = axis.as(Date.self) {
                    AxisValueLabel { Text(InvestmentBalanceStyle.shortDay(date)).font(.caption2) }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { axis in
                AxisGridLine()
                if !hidesAmounts, let amount = axis.as(Double.self) {
                    AxisValueLabel {
                        Text(amount == 0 ? "0" : (amount / 10_000).formatted(.number.precision(.fractionLength(0...2))) + "万")
                            .font(.caption2)
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartOverlay { proxy in
            if mode == .balance { debtHatching(points, proxy: proxy) }
        }
        .environment(\.calendar, InvestmentBook.calendar)
        .environment(\.timeZone, InvestmentBook.calendar.timeZone)
        .frame(height: 163)
        .accessibilityHidden(hidesAmounts)
    }

    private func debtHatching(_ points: [Point], proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            if let anchor = proxy.plotFrame, let zero = proxy.position(forY: 0.0) {
                let frame = geometry[anchor]
                Canvas { context, size in
                    var region = Path()
                    for segment in Dictionary(grouping: points, by: \.segment).values where segment.count > 1 {
                        let edges = segment.compactMap { point -> CGPoint? in
                            guard let x = proxy.position(forX: point.id),
                                  let y = proxy.position(forY: -number(point.snapshot.liabilities)) else { return nil }
                            return CGPoint(x: x, y: y)
                        }
                        guard let first = edges.first, let last = edges.last else { continue }
                        region.move(to: CGPoint(x: first.x, y: zero))
                        for edge in edges { region.addLine(to: edge) }
                        region.addLine(to: CGPoint(x: last.x, y: zero))
                        region.closeSubpath()
                    }
                    var lines = Path()
                    for x in stride(from: -size.height, through: size.width, by: 6) {
                        lines.move(to: CGPoint(x: x, y: size.height))
                        lines.addLine(to: CGPoint(x: x + size.height, y: 0))
                    }
                    var clipped = context
                    clipped.clip(to: region)
                    clipped.stroke(lines, with: .color(InvestmentBalanceStyle.debt.opacity(0.5)), lineWidth: 1)
                }
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }

    @ViewBuilder private var legend: some View {
        if mode == .net {
            legendItem("净资产", color: InvestmentBalanceStyle.equity)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) { legendCategories }
                VStack(alignment: .leading, spacing: 4) { legendCategories }
            }
        }
    }

    private var legendCategories: some View {
        ForEach(InvestmentBalanceCategory.allCases) { category in
            legendItem(category.rawValue, color: category.color)
        }
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(title).font(.caption2).foregroundStyle(.secondary).fixedSize()
        }
    }

    private func selection(_ snapshot: InvestmentBalanceSnapshot) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(InvestmentText.date(snapshot.day))
            Spacer(minLength: 4)
            if snapshot.net == nil {
                Text("估值不完整")
            } else if mode == .net {
                Text("净资产 " + InvestmentBalanceStyle.amount(snapshot.net, hidden: hidesAmounts))
            } else {
                Text("资产 " + InvestmentBalanceStyle.amount(snapshot.assets, hidden: hidesAmounts) +
                     " · 负债 " + InvestmentBalanceStyle.amount(snapshot.liabilities, hidden: hidesAmounts))
            }
        }.font(.caption2).foregroundStyle(.secondary).monospacedDigit()
    }
}
