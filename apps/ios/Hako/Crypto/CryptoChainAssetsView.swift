import SwiftUI

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
                                Spacer(minLength:8)
                                amounts(holding)
                                chevron
                            }
                            HStack(spacing:10) {
                                VStack(alignment:.leading,spacing:10) {
                                    CryptoCoinIdentity(symbol:holding.symbol,name:holding.name)
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

private struct CryptoCoinIdentity: View {
    let symbol: String
    let name: String
    var body: some View {
        HStack(spacing:10) {
            Image("Crypto"+symbol).resizable().scaledToFit().frame(width:32,height:32).accessibilityHidden(true)
            VStack(alignment:.leading,spacing:4) {
                Text(symbol).font(.subheadline.weight(.semibold))
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
        }.fixedSize(horizontal:true,vertical:false)
    }
}

private struct CryptoCoinDetailView: View {
    let symbol: String
    @ObservedObject var store: CryptoStore
    private var holding: CryptoChainHolding? { store.chainHoldings.first { $0.symbol == symbol } }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                if let holding {
                    VStack(alignment:.leading,spacing:10) {
                        CryptoCoinIdentity(symbol:symbol,name:holding.name)
                        Text("总余额").font(.caption).foregroundStyle(.secondary).padding(.top,8)
                        Text(cryptoQuantity(holding.quantity)+" "+symbol).font(.title.weight(.semibold)).monospacedDigit()
                        Text(holding.value.map { (holding.partiallyPriced ? "部分折合 " : "折合 ")+cryptoUSDT($0) } ?? "暂无报价，未计入折算总额")
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }.frame(maxWidth:.infinity,alignment:.leading).cryptoPanel()
                    HStack {
                        Text("余额分布").font(.headline)
                        Spacer()
                        Text("\(holding.networks.count) 条链 · \(holding.positions.count) 个地址").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(holding.networks,id:\.self) { network in
                        chainPanel(network,holding:holding)
                    }
                } else {
                    Text("暂无该币种资产").foregroundStyle(.secondary)
                }
                ForEach(store.wallets) { wallet in
                    if store.walletSnapshot(wallet) == nil {
                        Text(wallet.name+"：尚无余额明细，未计入汇总").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(20)
        }.background(HakoStyle.background).foregroundStyle(HakoStyle.text)
        .navigationTitle(symbol+" 资产").navigationBarTitleDisplayMode(.inline)
    }
    private func chainPanel(_ network:String,holding:CryptoChainHolding) -> some View {
        let positions = holding.positions.filter { $0.wallet.network == network }
        let value = positions.compactMap(\.value)
        return VStack(alignment:.leading,spacing:14) {
            HStack {
                Text(network).font(.headline)
                Spacer()
                Text("\(positions.count) 个地址").font(.caption).foregroundStyle(.secondary)
            }
            Text(cryptoQuantity(positions.reduce(0) { $0 + $1.quantity })+" "+symbol).font(.subheadline).monospacedDigit()
            Text(value.isEmpty ? "暂无报价" : (value.count < positions.count ? "部分折合 " : "折合 ")+cryptoUSDT(value.reduce(0,+)))
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            ForEach(positions) { position in
                Divider()
                VStack(alignment:.leading,spacing:8) {
                    Text(position.wallet.name).font(.subheadline.weight(.semibold))
                    Text(position.wallet.address).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(cryptoQuantity(position.quantity)+" "+symbol).font(.subheadline).monospacedDigit()
                    Text(position.value.map { "折合 "+cryptoUSDT($0) } ?? "暂无报价，未计入折算总额")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if let snapshot = store.walletSnapshot(position.wallet) {
                        Text("更新于："+snapshot.sampledAt.formatted(date:.numeric,time:.standard)).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = store.walletErrors[position.wallet.id] {
                        Text("更新失败，当前显示上次数据："+error).font(.caption).foregroundStyle(.red)
                    }
                }.accessibilityElement(children:.combine)
            }
        }.frame(maxWidth:.infinity,alignment:.leading).cryptoPanel()
    }
}

private func cryptoQuantity(_ value:Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
private func cryptoUSDT(_ value:Double) -> String { value.formatted(.number.precision(.fractionLength(2)))+" USDT" }
