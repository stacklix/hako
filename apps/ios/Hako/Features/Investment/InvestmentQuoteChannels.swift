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
              coverage: "A 股、境内 ETF、港股通及国内期货、期权的搜索与历史行情。",
              credential: "公开接口，无需密钥"),
        .init(title: "天天基金",
              coverage: "场外基金公布的历史单位净值；货币基金的每万份收益不作为净值。",
              credential: "通过东方财富基金接口，无需密钥"),
        .init(title: "Twelve Data",
              coverage: "美股、美股 ETF 的搜索与历史行情，以及 Binance Stock 持仓报价；也可补充外币兑人民币汇率。",
              credential: "需配置 API Key"),
        .init(title: "Tushare Pro",
              coverage: "东方财富缺少国内期货、期权历史时补查；连接测试使用交易日历。到期合约仍可能缺少历史数据。",
              credential: "需配置 API Token，并具备相应接口权限"),
        .init(title: "Binance",
              coverage: "加密现货的币种目录、公开报价和支持交易对的历史 K 线。",
              credential: "公开行情，无需交易所密钥"),
        .init(title: "Coinbase",
              coverage: "补充加密现货的美元报价、历史 K 线，以及 USDT/USD 换算价格。",
              credential: "公开行情，无需密钥"),
        .init(title: "欧洲央行（ECB）",
              coverage: "补充外币兑人民币的历史汇率。",
              credential: "公开数据，无需密钥")
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
