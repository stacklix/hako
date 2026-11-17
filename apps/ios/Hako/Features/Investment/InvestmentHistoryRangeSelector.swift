import SwiftUI

struct InvestmentHistoryRangeSelector: View {
    @Binding var selection: InvestmentHistoryRange
    @Binding var isExpanded: Bool

    var body: some View {
        Button { isExpanded.toggle() } label: {
            HStack(spacing: 5) {
                Text(selection.rawValue)
                Image(systemName: "chevron.down").font(.caption2)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(InvestmentBalanceStyle.accent)
            .frame(minHeight: 38)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("选择时间范围")
        .accessibilityValue(selection.rawValue + (isExpanded ? "，已展开" : "，已收起"))
        .overlay(alignment: .topTrailing) {
            if isExpanded {
                VStack(spacing: 2) {
                    ForEach(InvestmentHistoryRange.allCases) { option in
                        Button {
                            selection = option
                            isExpanded = false
                        } label: {
                            HStack(spacing: 12) {
                                Text(option.rawValue)
                                Spacer(minLength: 4)
                                if selection == option { Image(systemName: "checkmark").font(.caption) }
                            }
                            .font(.subheadline)
                            .foregroundStyle(selection == option ? InvestmentBalanceStyle.accent : Color.primary)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .background(selection == option ? Color.secondary.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == option ? .isSelected : [])
                    }
                }
                .padding(5)
                .frame(width: 168)
                .background(HakoStyle.adaptive(0xffffff, 0x323237), in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(HakoStyle.line, lineWidth: 1).allowsHitTesting(false) }
                .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
                .offset(y: 43)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("时间范围选项")
                .accessibilityAction(.escape) { isExpanded = false }
                .zIndex(20)
            }
        }
        .zIndex(isExpanded ? 20 : 0)
    }
}
