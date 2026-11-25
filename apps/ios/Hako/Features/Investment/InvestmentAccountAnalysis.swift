import Charts
import SwiftUI

struct InvestmentAccountAnalysis: View {
    let rows: [InvestmentPresentation.AccountAnalysis]
    let day: Date
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsLosses = false
    @State private var selectedID: UUID?

    private var assets: [InvestmentPresentation.AccountAnalysis] { rows.filter { ($0.valueCNY ?? 0) > 0 } }
    private var gains: [InvestmentPresentation.AccountAnalysis] { rows.filter { ($0.gainWeight(losses: showsLosses) ?? 0) > 0 } }
    private var assetTotal: Decimal { assets.reduce(0) { $0 + ($1.valueCNY ?? 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("账户资产与盈亏").font(.headline)
                Spacer(minLength: 6)
                Text(InvestmentText.date(day)).font(.caption2).foregroundStyle(.secondary)
            }
            if rows.isEmpty {
                Text("暂无账户").font(.subheadline).foregroundStyle(.secondary)
            } else {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 16) { charts; legend }
                } else {
                    HStack(spacing: 14) { charts.frame(width: 112); legend }
                }
                Text("统一折合人民币，饼图按所选金额计算占比。")
                    .font(.caption2).foregroundStyle(.secondary)
                if rows.contains(where: { ($0.valueCNY ?? 0) < 0 }) {
                    Text("负值资产未计入资产占比。").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: rows.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
        }
    }

    private var charts: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text("资产占比").font(.caption.weight(.medium))
                Text("当前资产 · CNY").font(.caption2).foregroundStyle(.secondary).frame(minHeight: 30)
                pie(assets, incomplete: rows.contains { $0.valueCNY == nil }, losses: nil)
            }
            VStack(spacing: 8) {
                Text("盈亏占比").font(.caption.weight(.medium))
                gainSwitch
                pie(gains, incomplete: rows.contains { $0.gainCNY == nil }, losses: showsLosses)
            }
        }
    }

    private var gainSwitch: some View {
        HStack(spacing: 2) {
            mode("盈利", losses: false)
            mode("亏损", losses: true)
        }
        .padding(2).background(HakoStyle.adaptive(0xeeedf2, 0x2d2c32), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain).accessibilityLabel("盈亏饼图显示方式")
    }

    private func mode(_ title: String, losses: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { showsLosses = losses }
        } label: {
            Text(title).font(.caption.weight(showsLosses == losses ? .semibold : .regular))
                .foregroundStyle(showsLosses == losses ? InvestmentBalanceStyle.accent : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(showsLosses == losses ? InvestmentBalanceStyle.summary : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(showsLosses == losses ? .isSelected : [])
            .accessibilityHint("仅切换盈亏饼图，账户明细保持不变")
    }

    @ViewBuilder private func pie(_ items: [InvestmentPresentation.AccountAnalysis], incomplete: Bool,
                                  losses: Bool?) -> some View {
        if incomplete {
            Text("估值不完整").font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 112)
        } else if items.isEmpty {
            Text(losses == nil ? "暂无正值资产" : losses == true ? "暂无亏损" : "暂无盈利")
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 112)
        } else {
            let hasSelection = items.contains { $0.id == selectedID }
            Chart(items) { row in
                let amount = losses == nil ? row.valueCNY : row.gainWeight(losses: losses == true)
                let highlighted = !hasSelection || selectedID == row.id
                SectorMark(angle: .value("金额", NSDecimalNumber(decimal: amount ?? 0).doubleValue),
                           innerRadius: .ratio(0.65), outerRadius: .ratio(highlighted ? 1 : 0.92))
                    .foregroundStyle(color(row)).opacity(highlighted ? 1 : 0.25)
                    .accessibilityLabel(row.name)
                    .accessibilityValue(InvestmentText.money(amount, .cny))
            }
            .chartLegend(.hidden).frame(height: 112)
            .accessibilityLabel(losses == nil ? "账户资产占比" : losses == true ? "账户历史亏损占比" : "账户历史盈利占比")
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedID = selectedID == row.id ? nil : row.id }
                } label: {
                    HStack(alignment: .top, spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(color(row)).frame(width: 7, height: 7).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.name + (row.isArchived ? " · 已归档" : ""))
                                .font(.caption.weight(selectedID == row.id ? .semibold : .regular))
                                .foregroundStyle(selectedID == row.id ? InvestmentBalanceStyle.accent : Color.primary)
                            Text("资产 " + InvestmentText.money(row.valueCNY, .cny) + " · " + assetShare(row))
                                .foregroundStyle(.secondary)
                            Text("盈亏 " + InvestmentText.money(row.gainCNY, .cny, signed: true) + " · " + InvestmentText.percent(row.gainRate))
                                .foregroundStyle(InvestmentTrendStyle.tint(row.gainCNY))
                        }.font(.caption2).monospacedDigit().fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.vertical, 9).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selectedID == row.id ? .isSelected : [])
                    .accessibilityHint(selectedID == row.id ? "再次点击取消高亮" : "高亮饼图中的对应账户")
                if row.id != rows.last?.id { Divider() }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func assetShare(_ row: InvestmentPresentation.AccountAnalysis) -> String {
        guard !rows.contains(where: { $0.valueCNY == nil }), let value = row.valueCNY, value >= 0, assetTotal > 0 else { return "—" }
        return (value / assetTotal).formatted(.percent.precision(.fractionLength(1)))
    }

    private func color(_ row: InvestmentPresentation.AccountAnalysis) -> Color {
        let extra = [HakoStyle.adaptive(0x637cb5, 0x849bdf), HakoStyle.adaptive(0x8b72ad, 0xa28dc9),
                     HakoStyle.adaptive(0x9c824b, 0xcfb181)]
        let index = row.colorIndex % 8
        return index < 5 ? InvestmentTrendStyle.category(index) : extra[index - 5]
    }
}
