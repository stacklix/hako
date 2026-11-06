import SwiftUI
import Charts
import UIKit

private struct CryptoWatchlist: View {
    private static let builtIn = ["BTC", "ETH", "SOL", "BNB", "TRX"]
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("crypto.watchlist.customSymbols") private var savedSymbols = ""
    @State private var prices: [String: Double] = [:]
    @State private var updatedAt: Date?
    @State private var refreshFailed = false
    @State private var adding = false
    @State private var symbolInput = ""
    @State private var addError: String?
    @State private var saving = false
    @State private var revealedSymbol: String?
    @State private var pendingDeletion: String?
    @State private var confirmingDeletion = false

    private var customSymbols: [String] { savedSymbols.split(separator: ",").map(String.init) }
    private var symbols: [String] { Self.builtIn + customSymbols }
    private var inputSymbol: String { symbolInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("关注币种").font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                Button {
                    revealedSymbol = nil
                    symbolInput = ""
                    addError = nil
                    adding = true
                } label: {
                    Image(systemName: "plus").frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("添加关注币种")
            }
            ForEach(symbols, id: \.self) { symbol in
                Divider()
                if Self.builtIn.contains(symbol) {
                    priceRow(symbol)
                } else {
                    customRow(symbol)
                }
            }
            if refreshFailed {
                Text(updatedAt == nil ? "行情暂不可用" : "行情更新失败，显示上次报价")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let updatedAt {
                Text("Binance 现货 · 更新于 " + updatedAt.formatted(date: .numeric, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
            } else if !refreshFailed {
                ProgressView("正在获取行情…").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).cryptoPanel()
        .task(id: scenePhase == .active ? savedSymbols : nil) {
            guard scenePhase == .active else { return }
            await refreshPrices()
        }
        .sheet(isPresented: $adding) { addSheet }
        .alert("删除关注币种？", isPresented: $confirmingDeletion, presenting: pendingDeletion) { symbol in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                savedSymbols = customSymbols.filter { $0 != symbol }.joined(separator: ",")
                prices.removeValue(forKey: symbol + "USDT")
                revealedSymbol = nil
            }
        } message: { symbol in
            Text("将 \(symbol) 从关注列表移除。")
        }
    }

    private func priceRow(_ symbol: String) -> some View {
        HStack {
            Text(symbol).font(.subheadline.weight(.semibold))
            Spacer(minLength: 8)
            Text(prices[symbol + "USDT"].map { value in
                let cents = (value * 100).rounded(.toNearestOrEven)
                let digits = cents == 0 ? 4 : 2
                return value.formatted(.number.precision(.fractionLength(digits))) + " USDT"
            } ?? "暂无报价")
            .font(.subheadline).monospacedDigit()
        }
        .frame(minHeight: 32)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func customRow(_ symbol: String) -> some View {
        HStack(spacing: 12) {
            priceRow(symbol)
                .simultaneousGesture(DragGesture(minimumDistance: 20).onEnded { drag in
                    let offset = drag.translation
                    guard abs(offset.width) > abs(offset.height), abs(offset.width) >= 30 else { return }
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if offset.width < 0 { revealedSymbol = symbol }
                        else if revealedSymbol == symbol { revealedSymbol = nil }
                    }
                })
                .accessibilityAction(named: Text("删除")) { confirmDeletion(symbol) }
            if revealedSymbol == symbol {
                Button(role: .destructive) { confirmDeletion(symbol) } label: {
                    Text("删除").font(.subheadline.weight(.medium))
                        .padding(.horizontal, 14).frame(minHeight: 44)
                        .foregroundStyle(.white)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
        }
    }

    private func confirmDeletion(_ symbol: String) {
        pendingDeletion = symbol
        confirmingDeletion = true
    }

    private var addSheet: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("币种代码").font(.subheadline).foregroundStyle(.secondary)
                        TextField("例如 DOGE", text: $symbolInput)
                            .keyboardType(.asciiCapable)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .accessibilityLabel("币种代码")
                            .disabled(saving)
                    }
                } footer: {
                    if let addError { Text(addError).foregroundStyle(.red) }
                }
                Section {
                    HStack(spacing: 12) {
                        Button("取消") { adding = false }
                            .buttonStyle(HakoActionButtonStyle(primary: false))
                        Button {
                            Task { await addSymbol() }
                        } label: {
                            if saving { ProgressView() }
                            else { Text("确定") }
                        }
                        .buttonStyle(HakoActionButtonStyle())
                        .disabled(inputSymbol.isEmpty)
                    }
                    .disabled(saving)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("添加关注币种")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(saving)
    }

    @MainActor private func addSymbol() async {
        guard !saving else { return }
        let symbol = inputSymbol
        guard symbol.range(of: "^[A-Z0-9]{1,20}$", options: .regularExpression) != nil else {
            addError = "请输入 1 至 20 位字母或数字组成的币种代码。"
            return
        }
        guard !symbols.contains(symbol) else {
            addError = "该币种已在关注列表中。"
            return
        }
        saving = true
        addError = nil
        defer { saving = false }
        let pair = symbol + "USDT"
        do {
            let quote = try await CryptoClient().binanceSpotPrices(pairs: [pair])
            guard let price = quote[pair] else { throw HakoError(message: "暂无报价") }
            prices[pair] = price
            savedSymbols = (customSymbols + [symbol]).joined(separator: ",")
            adding = false
        } catch {
            addError = "未能获取 \(symbol) 的 Binance USDT 报价，请检查币种代码或网络后重试。"
        }
    }

    @MainActor private func refreshPrices() async {
        let requestedSymbols = savedSymbols
        let pairs = Set(symbols.map { $0 + "USDT" })
        let hasCustomSymbols = !customSymbols.isEmpty
        let client = CryptoClient()
        while !Task.isCancelled {
            do {
                let quotes: [String: Double]
                do {
                    quotes = try await client.binanceSpotPrices(pairs: pairs.sorted())
                } catch {
                    try Task.checkCancellation()
                    guard hasCustomSymbols else { throw error }
                    // A delisted custom pair can cause the exchange to reject the entire batch.
                    quotes = try await client.binanceSpotPrices()
                }
                try Task.checkCancellation()
                guard savedSymbols == requestedSymbols else { return }
                let watched = quotes.filter { pairs.contains($0.key) }
                guard !watched.isEmpty else { throw HakoError(message: "暂无关注币种报价。") }
                prices = watched
                updatedAt = .now
                refreshFailed = false
            } catch {
                guard !Task.isCancelled else { return }
                refreshFailed = true
            }
            do { try await Task.sleep(for: .seconds(60)) }
            catch { return }
        }
    }
}

struct CryptoView: View {
    private enum Tab: String, CaseIterable { case overview="概览",htx="HTX",binance="Binance",chain="链上资产" }
    private enum SyncPhase { case idle, syncing, succeeded, failed }
    @StateObject private var store = CryptoStore.shared
    @State private var tab = Tab.overview
    @State private var trends=false
    @State private var days=30
    @State private var syncMessage:String?
    @State private var syncPhase = SyncPhase.idle
    @State private var syncRequested = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var collecting = true
    @State private var contractTableWidth: CGFloat = 0
    @State private var expandedBinanceAccount: CryptoBinanceAccount.ID?
    @State private var expandedHTXGroup: CryptoHTXSnapshot.Group?
    private var latest: CryptoRecord? { store.portfolio.last }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                header
                HakoUnderlineTabs(title:"资产来源",options:Tab.allCases,selection:$tab,label:{$0.rawValue})
                if syncPhase == .failed, let message=syncMessage {
                    Label(message,systemImage:"exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled).accessibilityAddTraits(.updatesFrequently)
                }
                if !collecting && !store.busy && syncPhase != .failed, let message=store.message {
                    Label("更新失败："+message,systemImage:"exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if tab == .overview {
                    amountPanel("总资产",value:latest?.values["total"])
                    if let latest {
                        VStack(spacing:16) {
                            source("HTX",value:latest.values["htx"],tab:.htx)
                            source("Binance",value:latest.values["binance"],tab:.binance)
                            source("链上资产",value:store.chainTotal,tab:.chain)
                        }.cryptoPanel()
                        Text("数据日期：\(latest.day) · 仅汇总已配置来源")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let updatedAt=store.cache.pricesUpdatedAt {
                        Text("报价更新于："+updatedAt.formatted(date:.numeric,time:.standard))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    CryptoTrend(title:"每日总资产",records:store.portfolio,keys:["total"],names:["总资产"],units:["USDT"])
                } else if tab == .htx {
                    Picker("HTX 页面",selection:$trends) { Text("资产概览").tag(false);Text("合约收益").tag(true) }.pickerStyle(.segmented)
                    if trends {
                        Picker("统计范围",selection:$days) {
                            Text("最近7天").tag(7)
                            Text("最近30天").tag(30)
                            Text("最近半年").tag(180)
                            Text("最近一年").tag(365)
                            Text("全部").tag(0)
                        }.pickerStyle(.menu)
                        LazyVGrid(columns:[GridItem(.adaptive(minimum:290),spacing:12)],spacing:12) {
                            ForEach(0..<6) { index in contractChart(index) }
                        }
                    } else {
                        amountPanel("HTX 总资产",value:latest?.values["htx"])
                        htxDetails
                        currentContractPanel
                        recentContractTable
                    }
                } else if tab == .binance {
                    amountPanel("Binance 总资产",value:store.binanceSnapshot?.total ?? latest?.values["binance"])
                    binanceDetails
                } else {
                    amountPanel("链上资产",value:store.chainTotal)
                    CryptoChainAssetsView(store:store)
                }
                if store.portfolio.isEmpty && store.contracts.isEmpty && store.currentContract == nil {
                    Text("还没有采集数据。请先配置交易所只读 API、观察地址及主应用私有仓库。")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.vertical,18)
                }
                CryptoWatchlist()
            }.padding(20)
        }
        .background(HakoStyle.background).foregroundStyle(HakoStyle.text)
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement:.topBarTrailing) {
            NavigationLink { CryptoSettingsView() } label: { Image(systemName:"slider.horizontal.3") }
                .accessibilityLabel("加密资产连接与地址设置")
        } }
        .onAppear { collecting=true;store.loadCachedData() }
        .onChange(of:scenePhase) { _,phase in
            if phase == .active && !collecting && (store.assetsExpired || store.pricesExpired) {
                Task { await collect() }
            }
        }
        .sensoryFeedback(trigger:syncPhase) { _,phase in
            switch phase {
            case .succeeded: .success
            case .failed: .error
            default: nil
            }
        }
        .task(id:syncPhase) {
            guard syncPhase == .succeeded else { return }
            do { try await Task.sleep(for:.seconds(5)) }
            catch { return }
            guard !Task.isCancelled else { return }
            syncPhase = .idle
        }
        .task(id:store.cacheGeneration) {
            await collect()
            // Check the separate balance and quote lifetimes, including at midnight.
            while !Task.isCancelled {
                do { try await Task.sleep(for:.seconds(60)) }
                catch { return }
                if scenePhase == .active && !collecting && (store.assetsExpired || store.pricesExpired) {
                    await collect()
                }
            }
        }
    }
    @MainActor private func collect() async {
        collecting=true;syncMessage=nil
        await store.collect()
        collecting=false
        if syncRequested {
            syncRequested=false
            await synchronize()
        }
    }
    @MainActor private func synchronize() async {
        let result=await store.trigger()
        let succeeded=store.message == nil
        syncPhase = succeeded ? .succeeded : .failed
        syncMessage=succeeded ? nil : result
    }
    private var header: some View {
        HStack(alignment:.center,spacing:12) {
            VStack(alignment:.leading,spacing:7) {
                Text("加密资产").font(.system(size:28,weight:.semibold))
                if collecting || (store.busy && syncPhase != .syncing) {
                    HStack(spacing:6) {
                        ProgressView().controlSize(.small)
                        Text("更新中…")
                    }.font(.caption).foregroundStyle(.secondary)
                } else if store.pendingReminderCount > 0 {
                    Text("\(store.pendingReminderCount) 条待同步")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength:0)
            Button {
                guard syncPhase != .syncing && syncPhase != .succeeded else { return }
                syncPhase = .syncing
                syncMessage=nil
                if collecting {
                    syncRequested=true
                } else {
                    Task { await synchronize() }
                }
            } label: {
                HStack(spacing:6) {
                    if syncPhase == .syncing {
                        ProgressView().controlSize(.small).tint(HakoStyle.background)
                        Text("同步中")
                    } else {
                        Label(syncPhase == .succeeded ? "已同步" : syncPhase == .failed ? "重试同步" : "同步资产",
                              systemImage:syncPhase == .succeeded ? "checkmark" : "arrow.triangle.2.circlepath")
                    }
                }.frame(minWidth:88)
            }
            .buttonStyle(HakoActionButtonStyle()).fixedSize(horizontal:true,vertical:false)
            .allowsHitTesting(syncPhase != .syncing && syncPhase != .succeeded)
            .accessibilityLabel(syncPhase == .syncing ? "资产同步中" : syncPhase == .succeeded ? "资产已同步" : "同步资产")
            .accessibilityHint(syncRequested ? "等待数据加载完成后同步" : syncPhase == .syncing ? "请等待同步完成" : syncPhase == .succeeded ? "同步已完成，按钮即将恢复" : "将本机缓存同步到 GitHub，数据加载中点击会等待加载完成")
        }
    }
    private var binanceDetails: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("资产详情").font(.headline)
            if let error=store.binanceError {
                Label("更新失败："+error,systemImage:"exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
                if store.binanceSnapshot != nil {
                    Text("以下为上次成功获取的数据").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let snapshot=store.binanceSnapshot {
                Text("余额更新于："+snapshot.sampledAt.formatted(date:.numeric,time:.standard))
                    .font(.caption).foregroundStyle(.secondary)
                let accounts = snapshot.visibleAccounts
                let hasUnavailableDetails = snapshot.accounts.contains { $0.assets == nil && $0.balance != 0 }
                if accounts.isEmpty && !hasUnavailableDetails {
                    Text("暂无账户资产").font(.subheadline).foregroundStyle(.secondary)
                }
                if !accounts.isEmpty {
                    VStack(alignment:.leading,spacing:0) {
                        ForEach(accounts) { account in
                            if account.id != accounts.first?.id { Divider() }
                            binanceAccountRow(account)
                        }
                    }.cryptoPanel()
                }
                if hasUnavailableDetails {
                    Text("部分账户暂未返回币种明细，其估值仍计入总资产。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if accounts.contains(where: { $0.visibleAssets?.contains(where: { $0.equitySymbol != nil }) == true }) {
                    Text("股票单价采用买卖报价中间值；USD 与 USDT 按 1:1 计算折值。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(!store.binanceConfigured ? "请在右上角设置中配置 Binance 只读 API。" : store.busy ? "正在获取资产详情…" : "暂无资产详情，重新进入页面后将自动采集。")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }

    private var htxDetails: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("资产详情").font(.headline)
            if let snapshot = store.htxSnapshot {
                let groups = CryptoHTXSnapshot.Group.allCases.filter { !snapshot.visibleRows(in:$0).isEmpty }
                if !groups.isEmpty {
                    VStack(alignment:.leading,spacing:0) {
                        ForEach(groups) { group in
                            if group != groups.first { Divider() }
                            htxAccountRow(group,snapshot:snapshot)
                        }
                    }.cryptoPanel()
                } else if snapshot.errors.isEmpty {
                    Text("暂无账户资产").font(.subheadline).foregroundStyle(.secondary)
                }
                if !snapshot.errors.isEmpty {
                    Text("部分明细更新失败，已缓存的明细继续显示。")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(snapshot.errors,id:\.self) { error in
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                if let error = snapshot.quoteError {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(!store.htxConfigured ? "请在右上角设置中配置 HTX 只读 API。" : store.busy ? "正在获取资产详情…" : "暂无资产详情")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }.frame(maxWidth:.infinity,alignment:.leading)
    }

    private func htxAccountRow(_ group: CryptoHTXSnapshot.Group, snapshot: CryptoHTXSnapshot) -> some View {
        let assets = snapshot.visibleRows(in:group)
        let allAssets = snapshot.rows(in:group)
        let values = allAssets.compactMap { snapshot.value($0) }
        let subtotal = values.reduce(0,+)
        let value = values.isEmpty || !subtotal.isFinite ? nil : subtotal
        let unit = values.count == allAssets.count ? "USDT" : "部分折合 USDT"
        let expanded = expandedHTXGroup == group
        return assetAccountRow(title:group.rawValue,subtitle:"\(assets.count) 项",value:value,unit:unit,expanded:expanded) {
            expandedHTXGroup = expanded ? nil : group
        } details: {
            ForEach(assets) { asset in
                if asset.id != assets.first?.id { Divider() }
                htxAssetRow(asset,value:snapshot.value(asset),isContract:group == .swap)
            }
        }
    }

    private func htxAssetRow(_ asset: CryptoHTXSnapshot.Holding, value: Double?, isContract: Bool) -> some View {
        let balances = [
            (isContract ? "可用保证金" : "可用", asset.available),
            (isContract ? "冻结保证金" : "冻结", asset.frozen),
            ("借款", asset.loan), ("利息", asset.interest)
        ].compactMap { label, amount -> String? in
            amount.flatMap { $0 == 0 ? nil : label + " " + exchangeAmount($0) }
        }.joined(separator:" · ")
        return exchangeAssetRow(symbol:asset.symbol,quantity:asset.quantity,unit:asset.symbol,value:value) {
            if !asset.label.isEmpty { Text(asset.label).font(.caption).foregroundStyle(.secondary) }
            if !balances.isEmpty { Text(balances).font(.caption).foregroundStyle(.secondary) }
            if let unrealized = asset.unrealized, unrealized != 0 {
                Text("未实现盈亏 " + exchangeAmount(unrealized))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func binanceAccountRow(_ account: CryptoBinanceAccount) -> some View {
        let assets = account.visibleAssets ?? []
        let expanded = expandedBinanceAccount == account.id
        return assetAccountRow(title:account.name,subtitle:"\(assets.count) 个币种",value:account.currentBalance,unit:"USDT",expanded:expanded) {
            expandedBinanceAccount = expanded ? nil : account.id
        } details: {
            ForEach(assets) { asset in
                if asset.id != assets.first?.id { Divider() }
                binanceAssetRow(asset)
            }
        }
    }

    private func assetAccountRow<Details: View>(title: String, subtitle: String, value: Double?, unit: String, expanded: Bool,
                                                toggle: @escaping () -> Void, @ViewBuilder details: () -> Details) -> some View {
        VStack(alignment:.leading,spacing:0) {
            Button(action:toggle) {
                HStack(spacing:10) {
                    Image(systemName:"wallet.bifold").frame(width:22).accessibilityHidden(true)
                    VStack(alignment:.leading,spacing:4) {
                        Text(title).font(.subheadline.weight(.semibold))
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength:8)
                    VStack(alignment:.trailing,spacing:4) {
                        Text(value.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—")
                            .font(.subheadline.weight(.semibold)).monospacedDigit()
                        Text(unit).font(.caption).foregroundStyle(.secondary)
                    }
                    Image(systemName:expanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(.secondary).frame(width:12).accessibilityHidden(true)
                }
                .frame(maxWidth:.infinity,minHeight:52,alignment:.leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "已展开" : "已折叠")
            .accessibilityHint(expanded ? "收起币种明细" : "展开币种明细")
            if expanded {
                VStack(alignment:.leading,spacing:10) {
                    details()
                }
                .padding(12)
                .background(HakoStyle.background,in:RoundedRectangle(cornerRadius:10))
                .padding(.bottom,10)
            }
        }
    }

    private func binanceAssetRow(_ asset: CryptoBinanceAsset) -> some View {
        let isStock = asset.equitySymbol != nil
        let unitPrice = asset.price.map { String(format:"%.*f",isStock ? 8 : 2,$0) }
        return exchangeAssetRow(symbol:asset.symbol,quantity:asset.quantity,unit:isStock ? "股" : asset.symbol,value:asset.usdtValue) {
            if asset.name != asset.symbol { Text(asset.name).font(.caption).foregroundStyle(.secondary) }
            if let unitPrice {
                Text("单价 \(unitPrice) \(isStock ? "USD" : "USDT")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func exchangeAmount(_ amount: Double) -> String {
        amount.formatted(.number.precision(.fractionLength(2)))
    }

    private func exchangeAssetRow<Notes: View>(symbol: String, quantity: Double, unit: String, value: Double?,
                                                @ViewBuilder notes: () -> Notes) -> some View {
        HStack(alignment:.top,spacing:10) {
            VStack(alignment:.leading,spacing:4) {
                Text(symbol).font(.subheadline.weight(.semibold))
                notes()
            }
            Spacer(minLength:0)
            VStack(alignment:.trailing,spacing:4) {
                Text(exchangeAmount(quantity) + " " + unit).font(.subheadline.weight(.semibold))
                Text(value.map { exchangeAmount($0) + " USDT" } ?? "暂无报价")
                    .font(.caption).foregroundStyle(.secondary)
            }.multilineTextAlignment(.trailing)
        }
        .monospacedDigit()
        .accessibilityElement(children:.combine)
    }

    private var currentContractPanel: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("今日合约 · TRX 币本位永续").font(.headline)
            metric("当前权益",store.currentContract?.trx,"TRX")
            metric("合约总权益",store.currentContract?.totalEquity,"USDT")
            metric("TRX 价格",store.currentContract?.price,"USDT/TRX")
            metric("今日资金费净收入",store.currentContract?.fundingTRX,"TRX")
            metric("今日资金费率合计",store.currentContract?.fundingRate,"%",precision:3)
            metric("可用保证金",store.currentContract?.available,"TRX")
            metric("未实现盈亏",store.currentContract?.unrealizedProfit,"TRX")
            metric("强平价",store.currentContract?.liquidation,"USD/TRX",precision:3)
            if let current=store.currentContract {
                Text("更新于：" + current.sampledAt.formatted(Date.FormatStyle(date:.numeric,time:.standard,timeZone:CryptoDay.calendar.timeZone)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.cryptoPanel()
    }
    private var recentContractTable: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("最近7天").font(.headline)
            ScrollView(.horizontal) {
                Grid(horizontalSpacing:12,verticalSpacing:12) {
                    GridRow {
                        contractTableCell("日期",alignment:.leading).gridColumnAlignment(.leading)
                        contractTableCell("总 USDT").gridColumnAlignment(.trailing)
                        contractTableCell("总 TRX").gridColumnAlignment(.trailing)
                        contractTableCell("资金费用/TRX").gridColumnAlignment(.trailing)
                    }.foregroundStyle(.secondary)
                    ForEach(CryptoSyncPolicy.recentContractDays(now:.now),id:\.self) { date in
                        let day=CryptoDay.key(date)
                        let values=store.contracts.first(where:{$0.day==day})?.values
                        Divider().gridCellColumns(4)
                        GridRow {
                            contractTableCell(day,alignment:.leading)
                            contractTableCell(contractTableValue(values?["equity"]))
                            contractTableCell(contractTableValue(values?["trx"]))
                            contractTableCell(contractTableValue(values?["funding_trx"],signed:true))
                        }.accessibilityElement(children:.combine)
                    }
                }.font(.caption).monospacedDigit().fixedSize(horizontal:true,vertical:false)
                    .frame(minWidth:0,maxWidth:.infinity,alignment:.leading)
            }
            .onGeometryChange(for:CGFloat.self) { $0.size.width } action: { contractTableWidth=$0 }
        }.frame(maxWidth:.infinity,alignment:.leading).cryptoPanel()
    }
    private func contractTableCell(_ text:String,alignment:Alignment = .trailing) -> some View {
        Text(text).frame(minWidth:max(0,(contractTableWidth-36)/4),alignment:alignment)
    }
    private func contractTableValue(_ value:Double?,signed:Bool=false) -> String {
        guard let value else { return "—" }
        return (signed && value>0 ? "+" : "")+value.formatted(.number.precision(.fractionLength(2)))
    }
    private func amountPanel(_ title:String,value:Double?) -> some View {
        VStack(alignment:.leading,spacing:8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment:.firstTextBaseline) { Text(value.map{String(format:"%.2f",$0)} ?? "—").font(.system(size:32,weight:.semibold)).monospacedDigit();Text("USDT").font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth:.infinity,alignment:.leading).cryptoPanel()
    }
    private func source(_ title:String,value:Double?,tab:Tab) -> some View {
        Button { self.tab=tab } label: { HStack { Text(title);Spacer();Text(value.map{String(format:"%.2f USDT",$0)} ?? "未配置").monospacedDigit();Image(systemName:"chevron.right").font(.caption) } }.buttonStyle(.plain)
    }
    private func metric(_ title:String,_ value:Double?,_ unit:String,precision:Int=2) -> some View {
        HStack { Text(title).font(.subheadline);Spacer();Text(value.map{String(format:"%.*f",precision,$0)} ?? "—").monospacedDigit();Text(unit).font(.caption).foregroundStyle(.secondary) }
    }
    private func contractChart(_ index:Int) -> some View {
        let titles=["TRX 与 USDT 总额","TRX 总额与 TRX 价格","USDT 总额与 TRX 价格","强平价格与 TRX 价格","每日资金费与费率","累计资金费用"]
        let keys=[["trx","usdt"],["trx","price"],["usdt","price"],["liquidation","price"],["funding_trx","rate_percent"],["cumulative"]]
        let names=[["TRX 权益","合约总权益"],["TRX 权益","TRX 价格"],["合约总权益","TRX 价格"],["强平价","TRX 价格"],["资金费","资金费率总和"],["资金费累计"]]
        let units=[["TRX","USDT"],["TRX","USDT/TRX"],["USDT","USDT/TRX"],["USD/TRX","USDT/TRX"],["TRX","%"],["TRX"]]
        var sum=0.0
        let rows=store.contracts.map { r -> CryptoRecord in
            var r=r
            if let fee=r.values["funding_trx"] { sum += fee;r.values["cumulative"]=sum }
            r.values["usdt"]=r.equity
            r.values["rate_percent"]=r.values["funding_rate"];return r
        }
        let component:Calendar.Component = (days == 180 || days == 365) ? .month : .day
        let offset = days == 180 ? -6 : days == 365 ? -12 : -days
        let cutoff=CryptoDay.key(CryptoDay.calendar.date(byAdding:component,value:offset,to:.now)!)
        return CryptoTrend(title:titles[index],records:rows.filter { days==0 || $0.day>=cutoff },keys:keys[index],names:names[index],units:units[index],sharedScale:index==3,zeroReferenceKey:index==4 ? "rate_percent" : nil)
    }
}

struct CryptoWalletDetailView: View {
    let wallet:CryptoWallet
    @ObservedObject var store:CryptoStore
    private var snapshot:CryptoWalletSnapshot? { store.walletSnapshot(wallet) }
    private var visibleAssets:[CryptoWalletAsset] {
        (snapshot?.assets ?? []).filter {
            CryptoWalletAsset.isIncluded($0.symbol)
        }.sorted { ($0.value ?? -1) > ($1.value ?? -1) }
    }
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                VStack(alignment:.leading,spacing:8) {
                    Text(wallet.network).font(.subheadline).foregroundStyle(.secondary)
                    Text(wallet.address).font(.caption.monospaced()).textSelection(.enabled)
                    Text("折算总资产").font(.caption).foregroundStyle(.secondary).padding(.top,8)
                    Text(store.walletValues[wallet.id].map { $0.formatted(.number.precision(.fractionLength(2)))+" USDT" } ?? "暂无估值")
                        .font(.title.weight(.semibold)).monospacedDigit()
                    if let snapshot {
                        Text("更新于："+snapshot.sampledAt.formatted(date:.numeric,time:.standard))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).cryptoPanel()
                if let error=store.walletErrors[wallet.id] {
                    Text((snapshot == nil ? "更新失败：" : "更新失败，当前显示上次数据：")+error).font(.caption).foregroundStyle(.red)
                }
                VStack(alignment:.leading,spacing:14) {
                    Text("币种资产").font(.headline)
                    Text("BTC · ETH · ATOM · TRX · USDT · USDC").font(.caption).foregroundStyle(.secondary)
                    if snapshot != nil {
                        if visibleAssets.isEmpty { Text("该地址暂无所选六种币种的资产").foregroundStyle(.secondary) }
                        ForEach(visibleAssets) { asset in
                            Divider()
                            VStack(alignment:.leading,spacing:6) {
                                CryptoCoinIdentity(symbol:asset.symbol,name:asset.name)
                                Text("数量："+asset.quantity.formatted(.number.precision(.fractionLength(2)))+" "+asset.symbol)
                                    .font(.subheadline).monospacedDigit()
                                Text(asset.value.map { "折合 "+$0.formatted(.number.precision(.fractionLength(2)))+" USDT" } ?? "暂无报价，未计入折算总额")
                                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                            }.accessibilityElement(children:.combine)
                        }
                    } else if store.busy {
                        ProgressView("正在获取币种资产…")
                    } else {
                        Text("暂无币种明细，重新进入资产页可更新。").font(.subheadline).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth:.infinity,alignment:.leading).cryptoPanel()
            }.padding(20)
        }
        .background(HakoStyle.background).foregroundStyle(HakoStyle.text)
        .navigationTitle(wallet.name).navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    func cryptoPanel() -> some View { padding(16).background(HakoStyle.card,in:RoundedRectangle(cornerRadius:14)) }
}

struct CryptoTrend: View {
    let title: String
    let records: [CryptoRecord]
    let keys: [String]
    let names: [String]
    let units: [String]
    var sharedScale = false
    var zeroReferenceKey: String? = nil
    @State private var selectedDay: String?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var independentScales: Bool { keys.count > 1 && !sharedScale }
    private var selectedRecord: CryptoRecord? { records.first { $0.day == selectedDay } }
    private var hasValues: Bool { records.contains { row in keys.contains { row.values[$0] != nil } } }
    private var tickDates: [Date] {
        let step = max(1, Int(ceil(Double(records.count) / 4)))
        return records.enumerated().compactMap { index, row in
            index % step == 0 || index == records.count - 1 ? row.date : nil
        }
    }
    private var dateDomain: ClosedRange<Date> {
        let first = records.first?.date ?? .now
        let last = records.last?.date ?? first
        return first == last ? first.addingTimeInterval(-43200)...last.addingTimeInterval(43200) : first...last
    }
    private func range(_ key: String) -> (Double, Double) {
        let values = sharedScale ? records.flatMap { r in keys.compactMap { r.values[$0] } } : records.compactMap { $0.values[key] }
        var low = values.min() ?? 0, high = values.max() ?? 1
        if key == zeroReferenceKey {
            low = min(low, 0)
            high = max(high, 0)
        }
        let pad = max((high - low) * 0.1, abs(high) * 0.001, 0.000001)
        return (low - pad, high + pad)
    }
    private func position(_ value: Double, key: String) -> Double {
        let bounds = range(key)
        return (value - bounds.0) / (bounds.1 - bounds.0)
    }
    private func digits(_ key: String) -> Int {
        ["rate_percent", "liquidation"].contains(key) ? 3 : 2
    }
    private func display(_ value: Double, key: String) -> String {
        String(format: "%.*f", digits(key), value)
    }
    private func axisLabel(_ fraction: Double, key: String) -> String {
        let bounds = range(key)
        let value = bounds.0 + fraction * (bounds.1 - bounds.0)
        return value.formatted(.number.notation(.compactName).precision(.fractionLength(0...digits(key))))
    }
    private func color(_ index: Int) -> Color {
        index == 0 ? HakoStyle.adaptive(0x478d80, 0x78b8aa) : HakoStyle.adaptive(0x5b88bf, 0x8aaedb)
    }
    private func dateLabel(_ date: Date) -> String {
        let day = CryptoDay.key(date)
        return records.first?.day.prefix(4) == records.last?.day.prefix(4)
            ? String(day.suffix(5)).replacingOccurrences(of: "-", with: "/")
            : day.replacingOccurrences(of: "-", with: "/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Spacer(minLength: 8)
                Text(independentScales ? "双刻度" : units.joined(separator: " / "))
                    .font(.system(size: 11)).foregroundStyle(HakoStyle.muted)
            }
            if !hasValues {
                Text("暂无历史数据").font(.caption).foregroundStyle(HakoStyle.muted)
                    .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                if independentScales {
                    HStack {
                        Text("左轴 · " + units[0]).foregroundStyle(color(0))
                        Spacer()
                        Text("右轴 · " + units[1]).foregroundStyle(color(1))
                    }.font(.system(size: 10))
                }
                renderedChart
                if let row = selectedRecord {
                    selectionDetails(row)
                }
            }
        }
        .foregroundStyle(HakoStyle.text)
        .frame(maxWidth: .infinity, alignment: .leading).cryptoPanel()
        .onChange(of: records) { _, _ in selectedDay = nil }
        .onChange(of: keys) { _, _ in selectedDay = nil }
    }

    @ChartContentBuilder
    private func marks(_ record: CryptoRecord, value: Double, index: Int, key: String) -> some ChartContent {
        let y = position(value, key: key)
        let label = Text(record.day + "，" + names[index])
        let description = Text(display(value, key: key) + " " + units[index])
        LineMark(x: .value("日期", record.date), y: .value(names[index], y), series: .value("指标", names[index]))
            .foregroundStyle(by: .value("指标", names[index]))
            .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            .accessibilityLabel(label).accessibilityValue(description)
    }

    private var renderedChart: some View {
        Chart {
            if let key = zeroReferenceKey {
                RuleMark(y: .value("资金费率基准", position(0, key: key)))
                    .foregroundStyle(Color.red)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .accessibilityLabel("资金费率 0%")
            }
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                ForEach(records) { record in
                    if let value = record.values[key] {
                        marks(record, value: value, index: index, key: key)
                    }
                }
            }
            if let row = selectedRecord {
                RuleMark(x: .value("日期", row.date))
                    .foregroundStyle(HakoStyle.muted.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).zIndex(2)
            }
        }
        .chartForegroundStyleScale(domain: names, range: keys.indices.map { color($0) })
        .chartLegend(.hidden)
        .chartXScale(domain: dateDomain)
        .chartYScale(domain: 0...1)
        .chartXAxis {
            AxisMarks(values: tickDates) { value in
                if let date = value.as(Date.self) {
                    let first = date == dateDomain.lowerBound
                    let last = date == dateDomain.upperBound
                    let label = Text(dateLabel(date)).font(.system(size: 10)).foregroundStyle(HakoStyle.muted)
                    if last && independentScales {
                        AxisValueLabel { label }
                    } else {
                        AxisValueLabel(centered:false,anchor:first ? .topLeading : last ? .topTrailing : nil,
                                       collisionResolution:first || last ? .disabled : .greedy) {
                            label
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0.0, 0.5, 1.0]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7)).foregroundStyle(HakoStyle.line)
                AxisValueLabel {
                    if let fraction = value.as(Double.self), let key = keys.first {
                        Text(axisLabel(fraction, key: key)).font(.system(size: 10))
                            .foregroundStyle(independentScales ? color(0) : HakoStyle.muted)
                    }
                }
            }
            if independentScales {
                AxisMarks(position: .trailing, values: [0.0, 0.5, 1.0]) { value in
                    AxisValueLabel {
                        if let fraction = value.as(Double.self) {
                            Text(axisLabel(fraction, key: keys[1])).font(.system(size: 10)).foregroundStyle(color(1))
                        }
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let anchor=proxy.plotFrame {
                    let frame=geometry[anchor]
                    CryptoChartInteraction { point,toggle in
                        let x=min(max(point.x,0),frame.width)
                        guard let date=proxy.value(atX:x,as:Date.self),
                              let row=records.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }) else { return }
                        selectedDay=toggle && selectedDay == row.day ? nil : row.day
                    }
                    .frame(width:max(0,frame.width),height:max(0,frame.height))
                    .position(x:frame.midX,y:frame.midY)
                }
            }
        }
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 230 : 160)
        .accessibilityLabel(title + "，" + zip(names, units).map { $0 + "，单位" + $1 }.joined(separator: "；"))
        .accessibilityHint("点击或左右拖动图表竖线，在下方查看所选日期的各项数据，松手后保留选择，再次点击可收起。")
    }

    private func selectionDetails(_ row: CryptoRecord) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(row.day).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { selectedDay = nil } label: {
                    Label("收起", systemImage: "chevron.up")
                        .font(.system(size: 11)).frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain).foregroundStyle(HakoStyle.muted)
                .accessibilityLabel("收起所选日期的数据")
            }
            valueDetails(row)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(HakoStyle.background, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityAddTraits(.updatesFrequently)
    }
    private func valueDetails(_ row: CryptoRecord) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 12) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        Circle().fill(color(index)).frame(width: 6, height: 6)
                        Text(names[index]).font(.system(size: 11)).foregroundStyle(HakoStyle.muted)
                    }
                    Text(row.values[key].map { display($0, key: key) + " " + units[index] } ?? "暂无数据")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// Own the plot's gestures so the surrounding ScrollView cannot consume horizontal scrubbing.
private struct CryptoChartInteraction: UIViewRepresentable {
    let select:(CGPoint,Bool)->Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context:Context) -> InteractionView {
        let view=InteractionView()
        view.backgroundColor = .clear
        view.isAccessibilityElement=false
        let coordinator=context.coordinator
        coordinator.attach(to:view)
        view.connectScroll={ [weak coordinator] scroll in coordinator?.connect(to:scroll) }
        return view
    }
    func updateUIView(_ view:InteractionView,context:Context) { context.coordinator.parent=self }

    final class InteractionView:UIView {
        var connectScroll:((UIScrollView)->Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var ancestor=superview
            while let view=ancestor {
                if let scroll=view as? UIScrollView { connectScroll?(scroll);break }
                ancestor=view.superview
            }
        }
    }

    final class Coordinator:NSObject,UIGestureRecognizerDelegate {
        var parent:CryptoChartInteraction
        private weak var view:UIView?
        private weak var scrollView:UIScrollView?
        private var pan:UIPanGestureRecognizer!
        private var press:UILongPressGestureRecognizer!
        init(_ parent:CryptoChartInteraction) { self.parent=parent }
        func attach(to view:UIView) {
            self.view=view
            let tap=UITapGestureRecognizer(target:self,action:#selector(tapped(_:)))
            pan=UIPanGestureRecognizer(target:self,action:#selector(moved(_:)))
            pan.maximumNumberOfTouches=1
            press=UILongPressGestureRecognizer(target:self,action:#selector(held(_:)))
            press.minimumPressDuration=0.2
            press.allowableMovement=10
            for gesture in [tap,pan!,press!] as [UIGestureRecognizer] {
                gesture.delegate=self
                view.addGestureRecognizer(gesture)
            }
            pan.require(toFail:press)
            tap.require(toFail:pan)
            tap.require(toFail:press)
        }
        func connect(to scroll:UIScrollView) {
            guard scrollView !== scroll else { return }
            scrollView=scroll
            // Vertical movement rejects both plot recognizers and hands the touch to page scrolling.
            scroll.panGestureRecognizer.require(toFail:pan)
            scroll.panGestureRecognizer.require(toFail:press)
        }
        func gestureRecognizerShouldBegin(_ recognizer:UIGestureRecognizer) -> Bool {
            guard recognizer === pan,let view else { return true }
            let velocity=pan.velocity(in:view)
            return abs(velocity.x) > abs(velocity.y)
        }
        @objc private func tapped(_ gesture:UITapGestureRecognizer) {
            guard gesture.state == .ended,let view else { return }
            parent.select(gesture.location(in:view),true)
        }
        @objc private func moved(_ gesture:UIPanGestureRecognizer) {
            guard [.began,.changed,.ended].contains(gesture.state),let view else { return }
            parent.select(gesture.location(in:view),false)
        }
        @objc private func held(_ gesture:UILongPressGestureRecognizer) {
            guard [.began,.changed,.ended].contains(gesture.state),let view else { return }
            parent.select(gesture.location(in:view),false)
        }
    }
}
