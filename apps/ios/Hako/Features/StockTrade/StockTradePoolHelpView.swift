import SwiftUI

struct StockTradePoolHelpView: View {
    let selected: StockTradePool
    var body: some View {
        SettingsSheet(title: "选股范围说明") {
            StockTradeScreen {
                Text("这些范围来自同一份已发布结果，具体门槛以「本轮门槛与规则」为准。")
                    .font(.subheadline).foregroundStyle(.secondary)
                StockTradeCard {
                    ForEach(Array(StockTradePool.allCases.enumerated()), id: \.element.id) { index, pool in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(pool.title).font(.headline).accessibilityAddTraits(.isHeader)
                                if pool == selected {
                                    Text("当前范围").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(pool.explanation).font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
                        if index < StockTradePool.allCases.count - 1 { Divider() }
                    }
                }
                StockTradeFootnote(text: "观察范围可能有重叠，数量不能直接相加。切换范围只改变展示内容，不会重新选股，也不会自动加入后台规则监控。")
            }
        }
    }
}
