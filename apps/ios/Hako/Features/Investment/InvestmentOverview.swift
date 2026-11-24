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
    @State private var accountsExpanded = false

    private var today: Date { InvestmentBook.day() }

    var body: some View {
        InvestmentScroll {
            summary
            InvestmentPerformanceChart(book: book, bookVersion: bookVersion)
            InvestmentProfitCalendar(book: book, bookVersion: bookVersion)
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
