import Charts
import SwiftUI

enum InvestmentTrendStyle {
    static let curve = InvestmentBalanceStyle.equity
    static let benchmark = HakoStyle.adaptive(0xad7725, 0xe6b968)
    static func tint(_ value: Decimal?) -> Color {
        guard let value, value != 0 else { return .secondary }
        return value > 0 ? HakoStyle.adaptive(0x147557, 0x76cbae) : HakoStyle.adaptive(0xaa3846, 0xf78891)
    }
    static func tile(_ value: Decimal) -> Color {
        value > 0 ? HakoStyle.adaptive(0x207555, 0x265440) : HakoStyle.adaptive(0xb74855, 0x68333e)
    }
    static func category(_ index: Int) -> Color {
        let colors: [Color] = [curve, HakoStyle.adaptive(0x7861c4, 0xb5a0ff), HakoStyle.adaptive(0x9b681e, 0xd7a65e),
                               InvestmentBalanceStyle.asset, HakoStyle.adaptive(0x3978a2, 0x86bce0)]
        return colors[index % colors.count]
    }
}

struct InvestmentChartTabs<Option: Hashable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String

    var body: some View {
        HStack(spacing: 14) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(label(option)).font(.caption.weight(selection == option ? .semibold : .regular))
                        .foregroundStyle(selection == option ? InvestmentBalanceStyle.accent : Color.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .background(selection == option ? InvestmentBalanceStyle.summary : .clear,
                                    in: RoundedRectangle(cornerRadius: 7))
                        .frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(selection == option ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }.accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

struct InvestmentTrendMenu<Option: Hashable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    @Binding var isExpanded: Bool
    var menuAlignment: Alignment = .topTrailing
    let label: (Option) -> String

    var body: some View {
        Button { isExpanded.toggle() } label: {
            HStack(spacing: 5) { Text(label(selection)); Image(systemName: "chevron.down").font(.caption2) }
                .font(.caption.weight(.medium)).foregroundStyle(InvestmentBalanceStyle.accent).frame(minHeight: 38)
        }
        .buttonStyle(.plain).accessibilityLabel(title)
        .accessibilityValue(label(selection) + (isExpanded ? "，已展开" : "，已收起"))
        .overlay(alignment: menuAlignment) {
            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(options, id: \.self) { option in
                        Button { selection = option; isExpanded = false } label: {
                            HStack(spacing: 12) {
                                Text(label(option)); Spacer(minLength: 4)
                                if selection == option { Image(systemName: "checkmark").font(.caption) }
                            }
                            .font(.subheadline)
                            .foregroundStyle(selection == option ? InvestmentBalanceStyle.accent : Color.primary)
                            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .background(selection == option ? InvestmentBalanceStyle.summary : .clear,
                                        in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityAddTraits(selection == option ? .isSelected : [])
                    }
                }
                .padding(5).frame(width: 174)
                .background(HakoStyle.adaptive(0xffffff, 0x323237), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(HakoStyle.line, lineWidth: 1).allowsHitTesting(false) }
                .shadow(color: .black.opacity(0.16), radius: 12, y: 6).offset(y: 43)
                .accessibilityElement(children: .contain).accessibilityLabel(title + "选项")
                .accessibilityAction(.escape) { isExpanded = false }.zIndex(20)
            }
        }.zIndex(isExpanded ? 20 : 0)
    }
}

struct InvestmentCurrentAllocation: View {
    let details: [InvestmentAllocationItem]
    let currency: InvestmentCurrency
    let day: Date
    let overview: Bool
    @State private var selectedID: String?
    private var positive: [InvestmentAllocationItem] { details.filter { ($0.value ?? 0) > 0 } }
    private var total: Decimal { positive.reduce(0) { $0 + ($1.value ?? 0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(overview ? "账户资产占比" : "投资总额占比").font(.headline)
                Spacer(minLength: 6)
                Text(InvestmentText.date(day)).font(.caption2).foregroundStyle(.secondary)
            }
            if details.contains(where: { $0.value == nil }) {
                Text("部分估值不完整，暂无法展示完整占比。").font(.caption).foregroundStyle(.secondary)
            } else if total > 0 {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { pie; legend }
                    VStack(alignment: .leading, spacing: 12) { HStack { Spacer(); pie; Spacer() }; legend }
                }
                if details.contains(where: { ($0.value ?? 0) < 0 }) {
                    Text("负值未计入资产占比。").font(.caption2).foregroundStyle(.secondary)
                }
            } else { Text("暂无正值资产可展示占比。").font(.caption).foregroundStyle(.secondary) }
        }
        .onChange(of: positive.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
        }
    }

    private var pie: some View {
        Chart {
            ForEach(Array(positive.enumerated()), id: \.element.id) { index, detail in
                SectorMark(angle: .value("资产", NSDecimalNumber(decimal: detail.value ?? 0).doubleValue),
                           innerRadius: .ratio(0.65),
                           outerRadius: .ratio(selectedID == nil || selectedID == detail.id ? 1 : 0.92))
                    .foregroundStyle(InvestmentTrendStyle.category(index))
                    .opacity(selectedID == nil || selectedID == detail.id ? 1 : 0.3)
                    .accessibilityLabel(detail.name)
                    .accessibilityValue(InvestmentText.money(detail.value, currency))
            }
        }.chartLegend(.hidden).frame(width: 136, height: 136)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(positive.enumerated()), id: \.element.id) { index, detail in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedID = selectedID == detail.id ? nil : detail.id
                    }
                } label: {
                    HStack(alignment: .top, spacing: 7) {
                        RoundedRectangle(cornerRadius: 2).fill(InvestmentTrendStyle.category(index))
                            .frame(width: 7, height: 7).padding(.top, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(detail.name).font(.caption.weight(selectedID == detail.id ? .semibold : .regular))
                            Text(InvestmentText.money(detail.value, currency) + " · " +
                                 ((detail.value ?? 0) / total).formatted(.percent.precision(.fractionLength(1))))
                                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selectedID == detail.id ? .isSelected : [])
                .accessibilityHint(selectedID == detail.id ? "再次点击取消高亮" : "高亮饼图中的对应扇区")
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct InvestmentPerformanceTreemap: View {
    let details: [InvestmentPerformanceDetail]
    let currency: InvestmentCurrency
    let start: Date
    let end: Date
    let overview: Bool
    @State private var selectedID: String?
    private var values: [(String, Decimal)] { details.compactMap { detail in detail.periodGain.map { (detail.id, $0) } } }
    private var selected: InvestmentPerformanceDetail? {
        selectedID.flatMap { id in details.first { $0.id == id } }
            ?? details.filter { $0.periodGain != nil }.max { abs($0.periodGain ?? 0) < abs($1.periodGain ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(overview ? "区间账户盈亏" : "区间标的盈亏").font(.headline)
            Text(InvestmentText.date(start) + " — " + InvestmentText.date(end)).font(.caption2).foregroundStyle(.secondary)
            if values.contains(where: { $0.1 != 0 }) {
                GeometryReader { geometry in
                    let rectangles = InvestmentProfitRectangle.layout(values, width: Double(geometry.size.width), height: Double(geometry.size.height))
                    ZStack(alignment: .topLeading) {
                        ForEach(rectangles, id: \.id) { rectangle in
                            tile(rectangle).frame(width: CGFloat(max(0, rectangle.width - 2)), height: CGFloat(max(0, rectangle.height - 2)))
                                .offset(x: CGFloat(rectangle.x + 1), y: CGFloat(rectangle.y + 1))
                        }
                    }
                }.frame(height: 224)
            } else { Text("所选区间暂无可用盈亏。").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 100) }
            HStack(spacing: 12) {
                key("盈利", color: InvestmentTrendStyle.tint(1)); key("亏损", color: InvestmentTrendStyle.tint(-1))
                Spacer(minLength: 0)
                Text("面积按盈亏金额绝对值").font(.caption2).foregroundStyle(.secondary)
            }
            if let selected {
                Text(selected.name + " · 区间盈亏 " + InvestmentText.money(selected.periodGain, currency, signed: true))
                    .font(.caption).foregroundStyle(InvestmentTrendStyle.tint(selected.periodGain)).monospacedDigit()
            }
            let zero = details.filter { $0.periodGain == 0 }.map(\.name)
            if !zero.isEmpty { Text("本区间无盈亏：" + zero.joined(separator: "、")).font(.caption2).foregroundStyle(.secondary) }
            if details.contains(where: { $0.periodGain == nil }) {
                Text("部分项目缺少区间起点或期末估值，未计入面积。").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.top, 5)
    }

    private func tile(_ rectangle: InvestmentProfitRectangle) -> some View {
        let name = details.first { $0.id == rectangle.id }?.name ?? ""
        let small = rectangle.width < 66 || rectangle.height < 38
        return Button { selectedID = rectangle.id } label: {
            VStack(spacing: 3) {
                Text(name).font(small ? .caption2 : .caption).lineLimit(1).truncationMode(.tail)
                if !small {
                    Text(InvestmentText.money(rectangle.amount, currency, signed: true)).font(.caption).monospacedDigit().lineLimit(1)
                }
            }.padding(5).frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(HakoStyle.adaptive(0xffffff, 0xf2f2f4)).background(InvestmentTrendStyle.tile(rectangle.amount))
                .overlay { if selectedID == rectangle.id { Rectangle().strokeBorder(Color.primary, lineWidth: 2).padding(2) } }
                .clipped().contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityElement(children: .ignore)
            .accessibilityLabel(name + "，区间盈亏 " + InvestmentText.money(rectangle.amount, currency, signed: true))
            .accessibilityAddTraits(selectedID == rectangle.id ? .isSelected : [])
    }

    private func key(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7); Text(title).font(.caption2).foregroundStyle(.secondary) }
    }
}
