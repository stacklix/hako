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
    let presentation: InvestmentPresentation
    var showsArchived = false
    var insuranceGainBasis: InvestmentInsuranceGainBasis = .cashValue
    var snapshotWriteRunning = false
    let openAccount: (UUID) -> Void
    @State private var accountsExpanded = false

    private var today: Date { InvestmentBook.day() }

    var body: some View {
        InvestmentScroll {
            summary
            InvestmentPerformanceChart(book: book, bookVersion: bookVersion)
            InvestmentCard {
                InvestmentAccountAnalysis(rows: presentation.accountAnalysis.filter { showsArchived || !$0.isArchived },
                                          day: presentation.day)
            }
            InvestmentProfitCalendar(book: book, bookVersion: bookVersion)
        }
    }

    private var accounts: some View {
        let rows = presentation.dailyAccountGains.filter { showsArchived || !$0.isArchived }
        return VStack(alignment: .leading, spacing: 9) {
            if rows.isEmpty {
                Text("暂无账户").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                Button { openAccount(row.id) } label: {
                    HStack(spacing: 10) {
                        Text(row.name + (row.isArchived ? " · 已归档" : ""))
                            .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(InvestmentText.money(row.gain, row.currency, signed: true))
                                .font(.subheadline.weight(.medium))
                            Text(InvestmentText.percent(row.rate)).font(.caption)
                        }.monospacedDigit().foregroundStyle(InvestmentTrendStyle.tint(row.gain))
                        InvestmentChevron()
                    }.frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if row.id != rows.last?.id { Divider() }
            }
            Text("按账户币种显示，按折合人民币盈亏从高到低排序。盈亏比例以昨日资产加当日净流入为基数。")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var summary: some View {
        let current = presentation.total
        let dayGain = presentation.dailyGain
        let dollars = presentation.dollars
        let historicalGain = presentation.historicalGain(insuranceBasis: insuranceGainBasis)
        let showsSnapshotProgress = snapshotWriteRunning && !book.accounts.isEmpty &&
            (current == nil || dayGain == nil || historicalGain == nil)
        return InvestmentCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("总资产 · CNY").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    if showsSnapshotProgress {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini).accessibilityHidden(true)
                            Text("快照计算中…").font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                    }
                }
                Text(InvestmentText.money(current?.value, .cny))
                    .font(.title2.weight(.semibold)).monospacedDigit()
                Text("折合美元 · " + InvestmentText.money(dollars, .usd))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                InvestmentMetric(title: "当日盈亏（暂估）", value: InvestmentText.money(dayGain, .cny, signed: true),
                                 color: InvestmentTrendStyle.tint(dayGain))
                Spacer(minLength: 10)
                InvestmentMetric(title: "历史总盈亏", value: InvestmentText.money(historicalGain, .cny, signed: true),
                                 color: InvestmentTrendStyle.tint(historicalGain))
            }
            if !book.accounts.isEmpty {
                Divider()
                DisclosureGroup(isExpanded: $accountsExpanded) { accounts } label: {
                    HStack {
                        Text("账户当日盈亏").font(.subheadline.weight(.medium))
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

}
