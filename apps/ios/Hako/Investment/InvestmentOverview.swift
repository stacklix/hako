import Charts
import SwiftUI

enum InvestmentRange: String, CaseIterable, Identifiable {
    case week = "近1周", month = "近1月", quarter = "近3月", half = "近半年", year = "近1年", all = "全部"

    var id: Self { self }
    static let chart: [Self] = [.month, .quarter, .year, .all]
    static let watch: [Self] = [.week, .month, .quarter, .half, .year]

    func start(from date: Date, earliest: Date?) -> Date {
        let calendar = InvestmentBook.calendar
        switch self {
        case .week: return InvestmentBook.addDays(-7, to: date)
        case .month: return calendar.date(byAdding: .month, value: -1, to: date) ?? date
        case .quarter: return calendar.date(byAdding: .month, value: -3, to: date) ?? date
        case .half: return calendar.date(byAdding: .month, value: -6, to: date) ?? date
        case .year: return calendar.date(byAdding: .year, value: -1, to: date) ?? date
        case .all: return earliest ?? date
        }
    }
}

struct InvestmentOverview: View {
    let book: InvestmentBook
    let openAccount: (UUID) -> Void
    @State private var range = InvestmentRange.month
    @State private var month = InvestmentBook.day()
    @State private var selectedDay = InvestmentBook.day()
    @State private var chartDay: Date?

    private var today: Date { InvestmentBook.day() }

    var body: some View {
        InvestmentScroll {
            summary
            history
            calendar
            accounts
        }
    }

    private var summary: some View {
        let current = book.portfolio(on: today)
        let dayGain = change(on: today)
        let dollars = book.portfolio(on: today, currency: .usd)?.value
        return InvestmentCard {
            VStack(alignment: .leading, spacing: 4) {
                InvestmentMetric(title: "总资产 · CNY", value: InvestmentText.money(current?.value, .cny), prominent: true)
                Text("折合美元 · " + InvestmentText.money(dollars, .usd))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                InvestmentMetric(title: "当日盈亏", value: InvestmentText.money(dayGain, .cny, signed: true),
                                 color: InvestmentText.tint(dayGain))
                Spacer(minLength: 10)
                InvestmentMetric(title: "历史总盈亏", value: InvestmentText.money(current?.gain, .cny, signed: true),
                                 color: InvestmentText.tint(current?.gain))
            }
            if book.accounts.isEmpty {
                Text("在投资记账设置中添加账户，开始记录资产。").font(.caption).foregroundStyle(.secondary)
            } else if current == nil {
                Text("部分持仓缺少报价或外币汇率，暂无法汇总。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private struct Point: Identifiable {
        var day: Date
        var value: Decimal
        var segment: Int
        var id: Date { day }
    }

    private var history: some View {
        let points = historyPoints()
        let selected = chartDay.flatMap { day in points.min(by: { abs($0.day.timeIntervalSince(day)) < abs($1.day.timeIntervalSince(day)) }) } ?? points.last
        return InvestmentCard {
            Text("资产变化").font(.headline)
            Picker("资产变化范围", selection: $range) {
                ForEach(InvestmentRange.chart) { item in Text(item.rawValue).tag(item) }
            }
            .pickerStyle(.segmented)
            .onChange(of: range) { chartDay = nil }
            if let selected {
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("日期", point.day),
                                 y: .value("总资产", NSDecimalNumber(decimal: point.value).doubleValue),
                                 series: .value("连续区间", point.segment))
                        .foregroundStyle(Color.teal)
                    }
                    PointMark(x: .value("日期", selected.day),
                              y: .value("总资产", NSDecimalNumber(decimal: selected.value).doubleValue))
                    .foregroundStyle(Color.teal)
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXSelection(value: $chartDay)
                .frame(height: 175)
                HStack {
                    Text(InvestmentText.date(selected.day)).foregroundStyle(.secondary)
                    Spacer()
                    Text(InvestmentText.money(selected.value, .cny)).monospacedDigit()
                }.font(.caption)
            } else {
                Text("暂无可用估值记录。").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func historyPoints() -> [Point] {
        guard let earliest = book.earliest else { return [] }
        let start = max(earliest, range.start(from: today, earliest: earliest))
        let days = InvestmentBook.calendar.dateComponents([.day], from: start, to: today).day ?? 0
        guard days >= 0 else { return [] }
        let step = max(1, days / 180)
        var dates = Set(stride(from: 0, through: days, by: step).map { InvestmentBook.addDays($0, to: start) })
        dates.insert(today)
        dates.formUnion(book.accounts.flatMap(\.events).map(\.day).filter { $0 >= start && $0 <= today })
        var segment = 0
        return dates.sorted().compactMap { day in
            guard let value = book.portfolio(on: day) else { segment += 1; return nil }
            return Point(day: day, value: value.value, segment: segment)
        }
    }

    private var calendar: some View {
        let cal = InvestmentBook.calendar
        let first = cal.dateInterval(of: .month, for: month)?.start ?? month
        let offset = (cal.component(.weekday, from: first) + 5) % 7
        let days = cal.range(of: .day, in: .month, for: first)?.count ?? 0
        return InvestmentCard {
            HStack {
                Text("盈亏日历").font(.headline)
                Spacer()
                Button { moveMonth(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 34, height: 36)
                }.accessibilityLabel("上个月")
                Text("\(cal.component(.year, from: first))年\(cal.component(.month, from: first))月")
                    .font(.caption).monospacedDigit()
                Button { moveMonth(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 34, height: 36)
                }.accessibilityLabel("下个月").disabled(cal.isDate(month, equalTo: today, toGranularity: .month))
            }.buttonStyle(.plain)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                ForEach(Array("一二三四五六日"), id: \.self) {
                    Text(String($0)).font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(0..<offset, id: \.self) { _ in Color.clear.frame(height: 36) }
                ForEach(0..<days, id: \.self) { index in
                    calendarDay(InvestmentBook.addDays(index, to: first), index + 1)
                }
            }
            Text(InvestmentText.date(selectedDay) + " · 盈亏 " + InvestmentText.money(change(on: selectedDay), .cny, signed: true))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func calendarDay(_ date: Date, _ label: Int) -> some View {
        let gain = date <= today ? change(on: date) : nil
        let color = InvestmentText.tint(gain)
        let active = date == selectedDay
        return Button { selectedDay = date } label: {
            VStack(spacing: 2) {
                Text(String(label))
                if let gain, gain != 0 {
                    Text((gain > 0 ? "+" : "") + gain.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))))
                        .lineLimit(1).minimumScaleFactor(0.65)
                }
            }.font(.caption2).monospacedDigit()
                .foregroundStyle(date > today ? Color.secondary : color)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(color.opacity(gain == nil || gain == 0 ? 0 : 0.1), in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Color.primary : .clear) }
        }.buttonStyle(.plain).disabled(date > today)
            .accessibilityLabel(InvestmentText.date(date) + "，盈亏 " + InvestmentText.money(gain, .cny, signed: true))
            .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func moveMonth(_ offset: Int) {
        guard let next = InvestmentBook.calendar.date(byAdding: .month, value: offset, to: month) else { return }
        month = next
        selectedDay = min(next, today)
    }

    private func change(on date: Date) -> Decimal? {
        guard let earliest = book.earliest, date >= earliest,
              let current = book.portfolio(on: date),
              let previous = book.portfolio(on: InvestmentBook.addDays(-1, to: date)) else { return nil }
        return current.gain - previous.gain
    }

    private var accounts: some View {
        InvestmentCard {
            Text("账户盈亏").font(.headline)
            ForEach(book.accounts) { account in
                let current = book.value(account)
                let previous = book.value(account, on: InvestmentBook.addDays(-1, to: today))
                let change = current.flatMap { now in previous.map { now.gain - $0.gain } }
                Button { openAccount(account.id) } label: {
                    HStack {
                        InvestmentTitle(account.name, subtitle: "总资产 " + InvestmentText.money(current?.value, account.currency))
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(InvestmentText.money(current?.gain, account.currency, signed: true))
                                .foregroundStyle(InvestmentText.tint(current?.gain))
                            Text("当日 " + InvestmentText.money(change, account.currency, signed: true))
                                .font(.caption).foregroundStyle(InvestmentText.tint(change))
                        }.font(.subheadline).monospacedDigit()
                        InvestmentChevron()
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if account.id != book.accounts.last?.id { Divider() }
            }
            if book.accounts.isEmpty { Text("暂无账户").foregroundStyle(.secondary).font(.subheadline) }
        }
    }
}
