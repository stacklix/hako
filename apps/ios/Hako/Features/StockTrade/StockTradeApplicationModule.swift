import SwiftUI

enum StockTradeApplicationModule {
    static let module = HakoApplicationModule(
        application: .stockTrade, category: .finance, subtitle: "Cerno · 每日推荐 · 日周 K 线与规则监控", icon: .asset("StockTradeIcon"),
        destination: { AnyView(StockTradeView()) })
}
