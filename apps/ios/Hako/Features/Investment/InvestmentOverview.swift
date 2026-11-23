import Charts
import SwiftUI

enum InvestmentRange: String, CaseIterable, Identifiable, Sendable {
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
    let bookVersion: UUID
    var showsArchived = false
    let openAccount: (UUID) -> Void
    @State private var month = InvestmentBook.day()
    @State private var selectedDay = InvestmentBook.day()
    @State private var accountsExpanded = false

    private var today: Date { InvestmentBook.day() }

    var body: some View {
        InvestmentScroll {
            summary
            InvestmentPerformanceChart(book: book, bookVersion: bookVersion)
            calendar
        }
    }

    private var summary: some View {
        let current = book.portfolio(on: today)
        let dayGain = book.dailyGains(from: today, through: today)[today]
        let dollars = book.portfolio(on: today, currency: .usd)?.value
        return InvestmentCard {
            VStack(alignment: .leading, spacing: 4) {
                InvestmentMetric(title: "总资产 · CNY", value: InvestmentText.money(current?.value, .cny), prominent: true)
                Text("折合美元 · " + InvestmentText.money(dollars, .usd))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                InvestmentMetric(title: "当日盈亏（暂估）", value: InvestmentText.money(dayGain, .cny, signed: true),
                                 color: InvestmentTrendStyle.tint(dayGain))
                Spacer(minLength: 10)
                InvestmentMetric(title: "历史总盈亏", value: InvestmentText.money(current?.gain, .cny, signed: true),
                                 color: InvestmentTrendStyle.tint(current?.gain))
            }
            if !book.accounts.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $accountsExpanded) { accounts } label: {
                    HStack {
                        Text("账户盈亏").font(.subheadline.weight(.medium))
                        Spacer(minLength: 8)
                        Text("\(book.visibleAccounts(showArchived: showsArchived).count)个账户").font(.caption).foregroundStyle(.secondary)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.tint(.primary)
            }
            if book.accounts.isEmpty {
                Text("在投资记账设置中添加账户，开始记录资产。").font(.caption).foregroundStyle(.secondary)
            } else if current == nil {
                Text("部分持仓缺少报价或外币汇率，暂无法汇总。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var calendar: some View {
        let cal = InvestmentBook.calendar
        let first = cal.dateInterval(of: .month, for: month)?.start ?? month
        let offset = (cal.component(.weekday, from: first) + 5) % 7
        let days = cal.range(of: .day, in: .month, for: first)?.count ?? 0
        let gains = book.dailyGains(from: first, through: min(today, InvestmentBook.addDays(days - 1, to: first)))
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
                    let date = InvestmentBook.addDays(index, to: first)
                    calendarDay(date, index + 1, gain: gains[date])
                }
            }
            let selectedGain = gains[selectedDay]
            let amount = selectedGain.map { InvestmentText.money($0, .cny, signed: true) }
            let detail = amount.map { (selectedDay == today ? "暂估盈亏 " : "盈亏 ") + $0 }
                ?? "缺少日行情、汇率或账本记录"
            Text(InvestmentText.date(selectedDay) + " · " + detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func calendarDay(_ date: Date, _ label: Int, gain: Decimal?) -> some View {
        let color = InvestmentText.tint(gain)
        let active = date == selectedDay
        return Button { selectedDay = date } label: {
            VStack(spacing: 2) {
                Text(String(label))
                if let gain, gain != 0 {
                    Text(calendarGain(gain))
                        .lineLimit(1).minimumScaleFactor(0.65)
                } else if gain == nil, date <= today, let earliest = book.earliest, date >= earliest {
                    Text("—").foregroundStyle(.secondary)
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

    private func calendarGain(_ gain: Decimal) -> String {
        let sign = gain > 0 ? "+" : ""
        if abs(gain) >= 1_000 {
            return sign + (gain / 1_000).formatted(
                .number.locale(Locale(identifier: "en_US_POSIX"))
                    .grouping(.never).precision(.fractionLength(1))
            ) + "k"
        }
        return sign + gain.formatted(.number.precision(.fractionLength(0...1)))
    }

    private func moveMonth(_ offset: Int) {
        guard let next = InvestmentBook.calendar.date(byAdding: .month, value: offset, to: month) else { return }
        month = next
        selectedDay = min(next, today)
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(book.visibleAccounts(showArchived: showsArchived)) { account in
                let current = book.value(account)
                let previous = book.value(account, on: InvestmentBook.addDays(-1, to: today), requiresDailyPrices: true)
                let change = book.value(account, on: today, requiresDailyPrices: true).flatMap { now in
                    previous.map { now.gain - $0.gain }
                }
                Button { openAccount(account.id) } label: {
                    HStack {
                        InvestmentTitle(account.name + (account.isArchived ? " · 已归档" : ""), subtitle: "总资产 " + InvestmentText.money(current?.value, account.currency))
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(InvestmentText.money(current?.gain, account.currency, signed: true))
                                .foregroundStyle(InvestmentTrendStyle.tint(current?.gain))
                            Text("当日 " + InvestmentText.money(change, account.currency, signed: true))
                                .font(.caption).foregroundStyle(InvestmentTrendStyle.tint(change))
                        }.font(.subheadline).monospacedDigit()
                        InvestmentChevron()
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if account.id != book.visibleAccounts(showArchived: showsArchived).last?.id { Divider() }
            }
            if book.visibleAccounts(showArchived: showsArchived).isEmpty { Text("暂无账户").foregroundStyle(.secondary).font(.subheadline) }
        }
    }
}
