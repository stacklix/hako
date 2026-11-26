import SwiftUI

struct InvestmentQuoteChannels: View {
    @State private var expanded = false

    private struct Channel: Identifiable {
        let title: String
        let coverage: String
        let credential: String
        var id: String { title }
    }

    private static let channels: [Channel] = [
        .init(title: "东方财富",
              coverage: "境内标的搜索、港股通及国内期货、期权行情。",
              credential: "公开接口，无需密钥"),
        .init(title: "天天基金",
              coverage: "场外基金公布的历史单位净值；货币基金的每万份收益不作为净值。",
              credential: "通过东方财富基金接口，无需密钥"),
        .init(title: "Twelve Data",
              coverage: "美股、美股 ETF 的搜索与历史行情，以及 Binance Stock 持仓报价。",
              credential: "需配置 API Key"),
        .init(title: "Tushare Pro",
              coverage: "A 股与境内 ETF 的历史行情、盘中报价；国内期货、期权历史补查；美元、港币兑人民币的每日官方中间价。盘中股票和 ETF 接口需分别开通权限。",
              credential: "需配置 API Token，并具备相应接口权限"),
        .init(title: "Binance",
              coverage: "加密现货的币种目录、公开报价和支持交易对的历史 K 线；按 1 USDT≈1 USD 估值。",
              credential: "公开行情，无需交易所密钥")
    ]

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(Self.channels) { channel in
                    HStack(alignment: .top, spacing: 9) {
                        Text("•").font(.footnote).foregroundStyle(.secondary).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(channel.title).font(.subheadline.weight(.medium))
                            Text(channel.coverage).font(.footnote).foregroundStyle(.secondary)
                            Text(channel.credential).font(.caption).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(.vertical, 10)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text("渠道说明").font(.body)
                Text("\(Self.channels.count) 个渠道 · 数据范围与密钥要求")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
        .tint(.primary)
        .investmentListRow()
    }
}
