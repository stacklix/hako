import SwiftUI

struct InvestmentHistoryRangeSelector: View {
    @Binding var selection: InvestmentHistoryRange
    @Binding var isExpanded: Bool

    var body: some View {
        InvestmentTrendMenu(title: "选择时间范围", options: InvestmentHistoryRange.allCases,
            selection: $selection, isExpanded: $isExpanded) { $0.rawValue }
    }
}
