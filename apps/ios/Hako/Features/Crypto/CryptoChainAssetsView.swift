import SwiftUI
import UIKit

struct CryptoChainAssetsView: View {
    private enum Dimension: String, CaseIterable { case coin = "按币种", wallet = "按钱包" }
    @ObservedObject var store: CryptoStore
    @State private var dimension = Dimension.coin
    private var holdings: [CryptoChainHolding] { store.chainHoldings }

    var body: some View {
        dimensionTabs
        if dimension == .coin {
            VStack(alignment:.leading,spacing:14) {
                if store.wallets.isEmpty {
                    Text("暂无观察地址，可在右上角设置中添加。").foregroundStyle(.secondary)
                } else if holdings.isEmpty {
                    if store.busy { ProgressView("正在获取币种资产…") }
                    else if store.wallets.contains(where: { store.walletSnapshot($0) == nil }) {
                        Text("暂无币种明细，同步资产后可查看。").foregroundStyle(.secondary)
                    } else { Text("暂无币种资产").foregroundStyle(.secondary) }
                }
                ForEach(Array(holdings.enumerated()),id:\.element.id) { index,holding in
                    if index > 0 { Divider() }
                    NavigationLink {
                        CryptoCoinDetailView(symbol:holding.symbol,store:store)
                    } label: {
                        ViewThatFits(in:.horizontal) {
                            HStack(spacing:10) {
                                CryptoCoinIdentity(symbol:holding.symbol,name:holding.name)
                                    .fixedSize(horizontal:true,vertical:false)
                                Spacer(minLength:8)
                                amounts(holding)
                                chevron
                            }
                            HStack(spacing:10) {
                                VStack(alignment:.leading,spacing:10) {
                                    CryptoCoinIdentity(symbol:holding.symbol,name:holding.name)
                                        .fixedSize(horizontal:true,vertical:false)
                                    amounts(holding)
                                }
                                Spacer(minLength:0)
                                chevron
                            }
                        }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityHint("查看各条链、各个地址的余额和折算 USDT")
                }
            }.frame(maxWidth:.infinity,alignment:.leading).cryptoPanel()
            ForEach(store.wallets) { wallet in
                if let error = store.walletErrors[wallet.id] {
                    Text(wallet.name+"："+(store.walletSnapshot(wallet) == nil ? "更新失败，未计入币种汇总：" : "更新失败，当前汇总包含上次数据：")+error)
                        .font(.caption).foregroundStyle(.red)
                } else if store.walletSnapshot(wallet) == nil {
                    Text(wallet.name+"：尚无余额明细，未计入币种汇总").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment:.leading,spacing:12) {
                if store.wallets.isEmpty {
                    Text("暂无观察地址，可在右上角设置中添加。").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(Array(store.wallets.enumerated()),id:\.element.id) { index,wallet in
                    if index > 0 { Divider() }
                    NavigationLink { CryptoWalletDetailView(wallet:wallet,store:store) } label: {
                        HStack(spacing:12) {
                            VStack(alignment:.leading,spacing:6) {
                                Text(wallet.name).font(.subheadline.weight(.semibold))
                                Text(wallet.network+" · "+wallet.address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                Text(store.walletValues[wallet.id].map { cryptoUSDT($0) } ?? "暂无估值").font(.headline).monospacedDigit()
                                if let error = store.walletErrors[wallet.id] {
                                    Text("更新失败："+error).font(.caption).foregroundStyle(.red)
                                }
                            }
                            Spacer(minLength:0)
                            chevron
                        }.frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityHint("查看该地址的总资产及各币种资产")
                }
            }.frame(maxWidth:.infinity,alignment:.leading).cryptoPanel()
        }
    }

    private var dimensionTabs: some View {
        HStack(spacing:25) {
            ForEach(Dimension.allCases,id:\.self) { option in
                Button { dimension = option } label: {
                    Text(option.rawValue)
                        .font(.system(size:14,weight:dimension == option ? .semibold : .regular))
                        .foregroundStyle(dimension == option ? HakoStyle.text : HakoStyle.muted)
                        .padding(.horizontal,1).frame(minHeight:44)
                        .overlay(alignment:.bottom) {
                            Rectangle().fill(dimension == option ? HakoStyle.text : .clear).frame(height:2)
                        }
                }.buttonStyle(.plain).accessibilityAddTraits(dimension == option ? .isSelected : [])
            }
            Spacer(minLength:0)
        }.background(alignment:.bottom) { Rectangle().fill(HakoStyle.line).frame(height:1) }
        .accessibilityElement(children:.contain).accessibilityLabel("资产列表维度")
    }
    private var chevron: some View { Image(systemName:"chevron.right").font(.caption).foregroundStyle(.secondary) }
    private func amounts(_ holding:CryptoChainHolding) -> some View {
        VStack(alignment:.trailing,spacing:6) {
            Text(cryptoQuantity(holding.quantity)+" "+holding.symbol).font(.subheadline.weight(.semibold))
            Text(holding.value.map { (holding.partiallyPriced ? "部分折合 " : "")+cryptoUSDT($0) } ?? "暂无报价")
                .font(.caption).foregroundStyle(.secondary)
        }.monospacedDigit().fixedSize(horizontal:true,vertical:false)
    }
}

struct CryptoCoinIdentity: View {
    let symbol: String
    let name: String
    var compact = false
    var body: some View {
        HStack(spacing:10) {
            logo
                .frame(width:32,height:32)
                .clipShape(RoundedRectangle(cornerRadius:symbol.uppercased() == "USDT" ? 16 : 0))
                .accessibilityHidden(true)
            if compact {
                HStack(alignment:.firstTextBaseline,spacing:7) {
                    Text(symbol).font(.subheadline.weight(.semibold))
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment:.leading,spacing:4) {
                    Text(symbol).font(.subheadline.weight(.semibold))
                    Text(name).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var logo: some View {
        if let url = Bundle.main.url(forResource:"Crypto"+symbol.uppercased(),withExtension:"png"),
           let image = UIImage(contentsOfFile:url.path) {
            Image(uiImage:image).renderingMode(.original).resizable().scaledToFit()
        } else {
            Image(systemName:"bitcoinsign.circle").font(.system(size:26)).foregroundStyle(.secondary)
        }
    }
}

private struct CryptoCoinDetailView: View {
    let symbol: String
    @ObservedObject var store: CryptoStore
    @ScaledMetric(relativeTo:.largeTitle) private var totalFontSize = 32
    @State private var expandedAddresses = Set<String>()
    private var holding: CryptoChainHolding? { store.chainHoldings.first { $0.symbol == symbol } }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:28) {
                if let holding {
                    summary(holding)
                    VStack(alignment:.leading,spacing:13) {
                        HStack(alignment:.firstTextBaseline,spacing:10) {
                            Text("余额分布").font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            Spacer(minLength:0)
                            Text("\(holding.networks.count) 个网络 · \(holding.positions.count) 个地址")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                        }
                        VStack(alignment:.leading,spacing:22) {
                            ForEach(holding.networks,id:\.self) { network in
                                chainPanel(network,holding:holding)
                            }
                        }
                    }
                } else {
                    Text("暂无该币种资产").foregroundStyle(.secondary)
                }
                ForEach(store.wallets) { wallet in
                    if store.walletSnapshot(wallet) == nil {
                        Text(wallet.name+"：尚无余额明细，未计入汇总").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(.horizontal,20).padding(.top,4).padding(.bottom,28)
        }.background(HakoStyle.background).foregroundStyle(HakoStyle.text)
        .navigationTitle(symbol+" 资产").navigationBarTitleDisplayMode(.inline)
    }

    private func summary(_ holding:CryptoChainHolding) -> some View {
        VStack(alignment:.leading,spacing:0) {
            CryptoCoinIdentity(symbol:symbol,name:holding.name,compact:true)
            Text("总余额").font(.caption).foregroundStyle(.secondary)
                .padding(.top,24).padding(.bottom,6)
            (Text(cryptoQuantity(holding.quantity)).font(.system(size:totalFontSize,weight:.semibold))
             + Text(" "+symbol).font(.body.weight(.medium)))
                .monospacedDigit().fixedSize(horizontal:false,vertical:true)
            Text(holding.value.map { (holding.partiallyPriced ? "部分折合 " : "折合 ")+cryptoUSDT($0) } ?? "暂无报价，未计入折算总额")
                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit().padding(.top,8)
        }
        .frame(maxWidth:.infinity,alignment:.leading).padding(20)
        .background(HakoStyle.card,in:RoundedRectangle(cornerRadius:20))
    }

    private func chainPanel(_ network:String,holding:CryptoChainHolding) -> some View {
        let positions = holding.positions.filter { $0.wallet.network == network }
        return VStack(alignment:.leading,spacing:0) {
            ViewThatFits(in:.horizontal) {
                HStack(alignment:.center,spacing:12) {
                    networkIdentity(network,count:positions.count).fixedSize(horizontal:true,vertical:false)
                    Spacer(minLength:8)
                    networkAmount(positions).fixedSize(horizontal:true,vertical:false)
                }
                VStack(alignment:.leading,spacing:10) {
                    networkIdentity(network,count:positions.count)
                    networkAmount(positions)
                }
            }
            .padding(.horizontal,4).padding(.top,10).padding(.bottom,12)
            .accessibilityElement(children:.combine)

            VStack(alignment:.leading,spacing:0) {
                ForEach(Array(positions.enumerated()),id:\.element.id) { index,position in
                    if index > 0 { Divider().overlay(HakoStyle.line) }
                    addressRow(position)
                }
            }
            .frame(maxWidth:.infinity,alignment:.leading)
            .background(HakoStyle.card,in:RoundedRectangle(cornerRadius:20))
        }.frame(maxWidth:.infinity,alignment:.leading)
    }

    private func networkIdentity(_ network:String,count:Int) -> some View {
        VStack(alignment:.leading,spacing:5) {
            Text(network).font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text("\(count) 个地址").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func networkAmount(_ positions:[CryptoChainPosition]) -> some View {
        VStack(alignment:.trailing,spacing:5) {
            Text(cryptoQuantity(positions.reduce(0) { $0 + $1.quantity }))
                .font(.subheadline.weight(.medium)).monospacedDigit()
            Text(symbol).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func addressRow(_ position:CryptoChainPosition) -> some View {
        VStack(alignment:.leading,spacing:7) {
            ViewThatFits(in:.horizontal) {
                HStack(alignment:.firstTextBaseline,spacing:10) {
                    Text(position.wallet.name).font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal:true,vertical:false)
                    Spacer(minLength:0)
                    addressAmount(position).fixedSize(horizontal:true,vertical:false)
                }
                VStack(alignment:.leading,spacing:7) {
                    Text(position.wallet.name).font(.subheadline.weight(.semibold))
                    addressAmount(position)
                }
            }
            ViewThatFits(in:.horizontal) {
                HStack(spacing:10) {
                    addressToggle(position).fixedSize(horizontal:true,vertical:false)
                    Spacer(minLength:0)
                    addressValuation(position).fixedSize(horizontal:true,vertical:false)
                }
                VStack(alignment:.leading,spacing:7) {
                    addressToggle(position)
                    addressValuation(position).frame(maxWidth:.infinity,alignment:.trailing)
                }
            }
            if expandedAddresses.contains(position.id) {
                Text(position.wallet.address).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(10)
                    .background(HakoStyle.background,in:RoundedRectangle(cornerRadius:9))
                    .accessibilityLabel("钱包地址，"+position.wallet.address)
            }
            if let error = store.walletErrors[position.wallet.id] {
                Text("更新失败，当前显示上次数据："+error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal,16).padding(.vertical,18)
        .frame(maxWidth:.infinity,alignment:.leading)
        .accessibilityElement(children:.contain)
    }

    private func addressToggle(_ position:CryptoChainPosition) -> some View {
        let expanded = expandedAddresses.contains(position.id)
        let address = position.wallet.address
        let abbreviated = address.count > 14
            ? String(address.prefix(6))+"…"+String(address.suffix(address.hasPrefix("0x") ? 4 : 5)) : address
        return Button {
            if expanded { expandedAddresses.remove(position.id) }
            else { expandedAddresses.insert(position.id) }
        } label: {
            HStack(spacing:7) {
                Text(abbreviated).font(.caption2.monospaced()).lineLimit(1)
                Image(systemName:expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size:9,weight:.semibold)).accessibilityHidden(true)
            }
            .foregroundStyle(.secondary).frame(minHeight:44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel((expanded ? "收起 " : "展开 ")+position.wallet.name+" 完整地址")
        .accessibilityValue(expanded ? "已展开" : "已收起")
    }

    private func addressValuation(_ position:CryptoChainPosition) -> some View {
        Text(position.value.map { "折合 "+cryptoUSDT($0) } ?? "暂无报价，未计入折算总额")
            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
    }

    private func addressAmount(_ position:CryptoChainPosition) -> some View {
        HStack(alignment:.firstTextBaseline,spacing:3) {
            Text(cryptoQuantity(position.quantity)).font(.body.weight(.semibold)).monospacedDigit()
            Text(symbol).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private func cryptoQuantity(_ value:Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
private func cryptoUSDT(_ value:Double) -> String { value.formatted(.number.precision(.fractionLength(2)))+" USDT" }
