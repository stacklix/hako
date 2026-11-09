import Charts
import SwiftUI

struct InvestmentBalanceCalendar: View {
    @ObservedObject var store: InvestmentStore
    let hidesAmounts: Bool
    @State private var year = InvestmentBook.calendar.component(.year, from: .now)

    private enum Series: Identifiable {
        case assets, category(InvestmentBalanceCategory), net
        var id: String { title }
        var title: String {
            switch self {
            case .assets: "总资产"
            case .category(.liabilities): "总负债"
            case .category(let category): category.rawValue
            case .net: "净资产"
            }
        }
        var color: Color {
            switch self {
            case .assets: InvestmentBalanceStyle.asset
            case .category(let category): category.color
            case .net: InvestmentBalanceStyle.equity
            }
        }
        func amount(_ snapshot: InvestmentBalanceSnapshot) -> Decimal? {
            switch self {
            case .assets: snapshot.assets
            case .category(let category): snapshot.amount(category)
            case .net: snapshot.net
            }
        }
        func lastUpdate(in dates: [InvestmentBalanceCategory: Date], includesDeficit: Bool) -> Date? {
            switch self {
            case .assets: InvestmentBalanceCategory.assets.compactMap { dates[$0] }.max()
            case .category(.liabilities) where includesDeficit:
                [dates[.liabilities], dates[.investments]].compactMap { $0 }.max()
            case .category(let category): dates[category]
            case .net: dates.values.max()
            }
        }
    }

    private struct Month: Identifiable {
        let index: Int
        let snapshot: InvestmentBalanceSnapshot
        var id: Int { index }
    }

    var body: some View {
        let book = store.book
        let today = InvestmentBook.day()
        let currentYear = InvestmentBook.calendar.component(.year, from: today)
        let years = availableYears(book, today: today, currentYear: currentYear)
        let selectedYear = years.contains(year) ? year : currentYear
        let months = months(book, year: selectedYear, today: today)
        let baseline = baseline(book, year: selectedYear, months: months, today: today)
        let updates = months.last.map { book.balanceUpdateDates(through: $0.snapshot.day, today: today) } ?? [:]
        let series: [Series] = [.assets] + InvestmentBalanceCategory.allCases.map(Series.category) + [.net]
        InvestmentScroll {
            HStack {
                Text("年份").font(.caption).foregroundStyle(.secondary)
                Menu {
                    Picker("年份", selection: $year) {
                        ForEach(years, id: \.self) { item in Text("\(item) 年").tag(item) }
                    }
                } label: {
                    Label("\(selectedYear) 年", systemImage: "chevron.down").font(.subheadline.weight(.medium))
                        .frame(minHeight: 44)
                }
                .tint(InvestmentBalanceStyle.accent)
            }
            if months.isEmpty {
                ContentUnavailableView("暂无月度记录", systemImage: "calendar")
            } else {
                ForEach(series) { item in
                    card(item, months: months, baseline: baseline, updates: updates)
                }
            }
        }
        .navigationTitle("资产月历")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func availableYears(_ book: InvestmentBook, today: Date, currentYear: Int) -> [Int] {
        let first = InvestmentBook.calendar.component(.year, from: min(book.balanceEarliest ?? today, today))
        return Array((first...currentYear).reversed())
    }

    private func months(_ book: InvestmentBook, year: Int, today: Date) -> [Month] {
        guard let earliest = book.balanceEarliest else { return [] }
        let calendar = InvestmentBook.calendar
        return (1...12).compactMap { index in
            guard let start = calendar.date(from: DateComponents(year: year, month: index, day: 1)), start <= today,
                  let interval = calendar.dateInterval(of: .month, for: start) else { return nil }
            let last = min(InvestmentBook.addDays(-1, to: interval.end), today)
            guard last >= earliest else { return nil }
            return Month(index: index, snapshot: book.balanceSnapshot(on: last, today: today))
        }
    }

    private func baseline(_ book: InvestmentBook, year: Int, months: [Month],
                          today: Date) -> (snapshot: InvestmentBalanceSnapshot?, title: String) {
        guard let first = book.balanceEarliest,
              let start = InvestmentBook.calendar.date(from: DateComponents(year: year, month: 1, day: 1)) else {
            return (nil, "年度变动")
        }
        let priorEnd = InvestmentBook.addDays(-1, to: start)
        if first <= priorEnd { return (book.balanceSnapshot(on: priorEnd, today: today), "年度变动") }
        return (months.first?.snapshot, "较首月变动")
    }

    private func card(_ series: Series, months: [Month],
                      baseline: (snapshot: InvestmentBalanceSnapshot?, title: String),
                      updates: [InvestmentBalanceCategory: Date]) -> some View {
        let latest = months.last
        let current = latest.flatMap { series.amount($0.snapshot) }
        let updatedAt = series.lastUpdate(in: updates, includesDeficit: (latest?.snapshot.investmentDeficit ?? 0) > 0)
        let previous = baseline.snapshot.flatMap(series.amount)
        let change = current.flatMap { value in previous.map { value - $0 } }
        return InvestmentCard {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(series.title).font(.subheadline.weight(.semibold)).foregroundStyle(series.color)
                Text(InvestmentBalanceStyle.amount(current, hidden: hidesAmounts))
                    .font(.subheadline.weight(.semibold)).monospacedDigit()
                Spacer(minLength: 0)
                if let updatedAt {
                    Text("更新于 " + InvestmentText.date(updatedAt))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 5) {
                Text(baseline.title).foregroundStyle(.secondary)
                Text(InvestmentBalanceStyle.amount(change, hidden: hidesAmounts, signed: true))
                    .fontWeight(.semibold).monospacedDigit()
                    .foregroundStyle(InvestmentBalanceStyle.changeColor(change, liability: series.id == "总负债", hidden: hidesAmounts))
            }.font(.caption)
            chart(series, months: months)
        }
    }

    private func chart(_ series: Series, months: [Month]) -> some View {
        let labels = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二"]
        return Chart {
            RuleMark(y: .value("零轴", 0.0)).foregroundStyle(.secondary.opacity(0.5))
            ForEach(months) { month in
                if let balance = series.amount(month.snapshot) {
                    BarMark(x: .value("月份", Double(month.index)),
                            y: .value(series.title, NSDecimalNumber(decimal: balance).doubleValue))
                        .foregroundStyle(series.color.opacity(0.5))
                        .cornerRadius(2)
                        .accessibilityLabel("\(month.index)月")
                        .accessibilityValue(InvestmentBalanceStyle.amount(balance, hidden: hidesAmounts))
                }
            }
        }
        .chartXScale(domain: 0.5...12.5)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartXAxis {
            AxisMarks(values: (1...12).map(Double.init)) { axis in
                if let month = axis.as(Double.self), (1...12).contains(Int(month)) {
                    AxisValueLabel { Text(labels[Int(month) - 1]).font(.caption2) }
                }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 96)
        .accessibilityHidden(hidesAmounts)
    }
}
