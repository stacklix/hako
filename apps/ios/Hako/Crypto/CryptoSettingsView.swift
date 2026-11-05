import SwiftUI

struct CryptoSettingsView: View {
    @ObservedObject private var store=CryptoStore.shared
    @State private var wallets:[CryptoWallet]=[]
    @State private var editing:CryptoWallet?
    @State private var walletError:String?
    @State private var clearingCache=false
    @State private var cacheMessage:String?
    var body: some View {
        Form {
            Section {
                NavigationLink {
                    CryptoDataExplanationView()
                } label: {
                    Label("数据说明",systemImage:"info.circle")
                }
                .cryptoSettingsRowSeparators()
                .accessibilityHint("查看各项资产、权益、资金费与历史数据的取值逻辑")
            }
            Section("交易所接口") {
                CryptoCredentialLink(exchange:"htx",title:"HTX")
                CryptoCredentialLink(exchange:"binance",title:"Binance")
            }
            Section {
                ForEach(wallets) { wallet in
                    Button { editing=wallet } label: {
                        VStack(alignment:.leading,spacing:5) {
                            Text(wallet.name).foregroundStyle(.primary)
                            Text(wallet.network+" · "+wallet.address).font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
                        .padding(.horizontal,20).padding(.vertical,8)
                    }
                    .listRowInsets(EdgeInsets())
                    .cryptoSettingsRowSeparators()
                }.onDelete { indices in
                    var next=wallets;next.remove(atOffsets:indices)
                    do { try CryptoWallet.save(next);wallets=next;walletError=nil } catch { walletError=error.localizedDescription }
                }
                if let walletError { Text(walletError).font(.caption).foregroundStyle(.red).cryptoSettingsRowSeparators() }
                Button { editing=CryptoWallet() } label: {
                    Label("添加观察地址",systemImage:"plus")
                        .foregroundStyle(.blue)
                        .frame(maxWidth:.infinity,minHeight:44,alignment:.leading)
                        .padding(.horizontal,20).padding(.vertical,4)
                }
                .listRowInsets(EdgeInsets())
                .cryptoSettingsRowSeparators()
            } header: {
                Text("链上资产")
            } footer: {
                Text("点击地址可编辑，左滑可移除。只保存观察地址，不需要钱包私钥。Cosmos Hub 支持 cosmos1 地址，无需 API Token。")
            }
            Section("链上浏览器") {
                CryptoCredentialLink(exchange:"tronscan",title:"TRONSCAN",tokenOnly:true)
                CryptoCredentialLink(exchange:"moralis",title:"Moralis",tokenOnly:true)
            }
            Section("私有仓库归档") {
                Text("TRX 合约：data/crypto/htx-trx/年份.csv").font(.caption).textSelection(.enabled).cryptoSettingsRowSeparators()
                Text("总资产：data/crypto/portfolio/年份.csv").font(.caption).textSelection(.enabled).cryptoSettingsRowSeparators()
            }
            Section {
                Button("清空缓存",role:.destructive) { clearingCache=true }
                    .buttonStyle(.automatic)
                    .disabled(store.busy)
                    .cryptoSettingsRowSeparators()
                if let cacheMessage {
                    Text(cacheMessage).font(.caption).cryptoSettingsRowSeparators()
                }
            } header: {
                Text("本机缓存")
            } footer: {
                Text("清空当前私有仓库对应的资产缓存及待同步记录。再次进入加密资产时，从 GitHub 历史数据重建缓存，再采集最新资产。")
            }
        }.navigationTitle("资产设置").navigationBarTitleDisplayMode(.inline)
            .alert("清空资产缓存？",isPresented:$clearingCache) {
                Button("取消",role:.cancel) {}
                Button("清空缓存",role:.destructive) {
                    do { try store.clearCache();cacheMessage="缓存已清空，再次进入加密资产时将从 GitHub 重建。" }
                    catch { cacheMessage=error.localizedDescription }
                }
            } message: {
                Text("将删除本机资产历史、实时快照及 \(store.pendingCount) 条待同步记录。未同步数据无法恢复；GitHub 数据、接口配置和观察地址均保留。")
            }
            .task {
                do { wallets=try CryptoWallet.load();walletError=nil } catch { walletError=error.localizedDescription }
            }
            .sheet(item:$editing) { wallet in
                CryptoWalletEditor(wallet:wallet,existing:wallets) { wallets=$0;walletError=nil }
            }
    }
}

private struct CryptoDataExplanationView: View {
    var body: some View {
        Form {
            Section("总资产与各来源") {
                explanation("总资产","汇总已配置的 HTX、Binance 和链上资产，单位为 USDT。全部已配置来源获取成功后才更新当天总额；任一来源失败时保留上次成功的总额。")
                explanation("HTX 总资产","使用 HTX 平台总资产估值，按当前 BTC/USDT 报价换算，已包含合约资产，不再额外叠加今日合约权益。")
                explanation("Binance 总资产","使用 Binance 返回的各资产类型 USDT 余额之和。隐藏小额币种或空资产类型只影响明细展示，不扣减总资产。")
                explanation("链上资产","汇总已添加观察地址中 BTC、ETH、ATOM、TRX、USDT、USDC 六种资产的估值，不同地址分别统计；同一资产来源不要重复添加。")
            }
            Section("今日合约 · TRX 币本位永续") {
                explanation("当前权益 / TRX","取 HTX 的 TRX-USD 账户权益，单位为 TRX。它与全部币本位合约的总权益属于不同口径。")
                explanation("合约总权益 / USDT","直接取 HTX 全部币本位合约的资产估值，优先使用 USDT；不支持或获取失败时尝试 USD，并按 USDT 等值记录。不是 TRX 数量乘单价。")
                explanation("TRX 价格","取 HTX 当前 TRX/USDT 现货报价，单位为 USDT/TRX。")
                explanation("可用保证金与未实现盈亏","分别取 TRX-USD 账户返回的可用保证金和未实现盈亏，单位均为 TRX。")
                explanation("强平价","取当前 TRX-USD 账户的强平价，单位为 USD/TRX。空值或非正数显示 —；历史行中的强平价也是补录时的当前值。")
            }
            Section("资金费用与费率") {
                explanation("资金费净收入","取实际资金费流水，收入为正、支出为负，去重后按北京时间归集。今日统计当天零点至采集时刻，历史统计对应完整自然日，单位为 TRX。")
                explanation("资金费率合计","将统计时段内已结算的各期费率相加，不包含下一期预估费率。优先取实际费率；实际费率缺失时取同一期公布费率。取回后转换为百分比，本机缓存、GitHub 归档与页面均使用百分比，保留三位小数。")
                explanation("累计资金费用","从最早已保存的日期开始，将已有的每日资金费净收入依次相加。切换统计范围只截取图表展示区间，不把累计值重新归零；缺失日期不推算资金费。")
            }
            Section("最近7天与合约收益图表") {
                explanation("日期范围","所有日期按北京时间划分。最近7天为今天之前的七个完整自然日，不包含今天；图表按已保存日期展示，拖动竖线可查看对应日的数据。")
                explanation("历史权益补录","最近7天缺少 TRX 权益、价格或总权益时，使用本轮成功获取的当前快照填补对应空字段。多个缺失日复用同一快照，并非这些日期的实际结算权益；已有值不覆盖。")
                explanation("总 USDT、总 TRX 与资金费用","最近7天分别展示该日期已保存的合约总权益（USDT）、TRX 账户权益（TRX）和资金费净收入（TRX）。新补录的总 USDT 为全部币本位合约总估值；早期已保存值按原口径保留，不重新计算。")
                explanation("按缺失字段查询","只缺资金费率就只补查费率，只缺资金费就只补查流水。支持时间范围查询的流水覆盖整个7天，按接口的48小时限制分段，再按天填补缺失值。")
                explanation("空值与失败","— 表示尚未获取到有效数据，不代表零。实际没有资金费收支且流水查询完整时可记为零；查询失败保留已有数据，不用过期权益补录历史。")
            }
            Section("Binance 币种与股票") {
                explanation("持有金额","合并币种的可用、锁定、冻结和提现中数量，只展示合计，不单独展示各组成部分。")
                explanation("币种单价与折值","USDT 单价为 1。其他币种优先使用 Binance 对 USDT 的现货价格，没有直接交易对时尝试通过 BTC、ETH、BNB、USDC 或 FDUSD 换算；折值为持有数量乘单价。")
                explanation("EQ_ 股票","去掉 EQ_ 前缀后查询 Binance 股票行情，取买卖报价中间值作为美元单价；USD 与 USDT 按 1:1 计算，折值为缓存持股数量乘最新单价。报价缓存 1 小时且仅限同一自然日；失败保留上次报价，无历史报价时显示 —。")
                explanation("明细筛选","隐藏折算绝对值不足 1 USDT 的币种及没有可展示币种的资产类型。无法估值的非零持仓继续显示。")
            }
            Section("链上资产范围") {
                explanation("余额与估值","TRON 余额及代币的 TRX 计价来自 TRONSCAN，再用 HTX 的 TRX/USDT 报价折算。Ethereum 和 BNB Smart Chain 的余额与美元估值来自 Moralis，USD 与 USDT 按 1:1 计算。只统计所选六种资产。")
                explanation("TRX 质押","TRX 包含钱包余额、Stake 1.0 / 2.0 质押本金、委托给他人的本金，以及解押中和待提取本金。他人委托给本地址的资源不算资产。")
                explanation("ATOM 余额","Cosmos Hub 通过公开节点查询原生 ATOM，合计钱包余额、委托质押本金、解押中本金及待领取的 ATOM 奖励，再用 HTX ATOM/USDT 报价折算。转委托不重复计入；不包含其他链上的 IBC ATOM、流动性质押代币及验证者佣金。任一余额接口失败时保留上次数据。")
                explanation("未覆盖资产","不包含 NFT、第三方 DeFi 质押和借贷头寸；明细和总额均以当前支持的资产范围为准。")
            }
            Section("更新、缓存与归档") {
                explanation("自动更新","进入加密资产页时先展示本机缓存；持仓和余额缓存自成功获取起有效 6 小时，且仅在北京时间同一自然日内有效，超过 6 小时或跨日后重新获取。接口配置或观察地址变更后也重新获取。没有缓存时先读取 GitHub 历史数据建立缓存，再获取最新资产。历史读取失败时保留缺失并提示原因，下次进入重试，不上传本机数据。币价和股票报价独立缓存 1 小时且仅限同一自然日；进入页面或停留期间报价失效时只刷新价格，不查询余额。USDT 折值由缓存数量乘有效报价实时计算；有完整报价时账户合计同样重算。余额缓存有效期内不因资金费结算时段变化重新查询余额。")
                explanation("清空缓存","删除当前私有仓库对应的本机历史、实时快照及待同步记录。GitHub 数据、接口配置和观察地址保留；再次进入时从 GitHub 重建。清空前应先同步需要保留的记录。")
                explanation("同步资产","页面同步按钮和快捷指令只将本机缓存合并上传到 GitHub 私有仓库，不重新请求资产接口。上传失败保留待同步数据；历史已有值保留，只填补空字段。")
                explanation("显示精度","总额、合约权益和资金费保留两位小数，TRX 价格、强平价和百分比资金费率保留三位小数；Binance 持仓数量与单价最多显示八位小数。各指标独立保存，不用页面已舍入的数字重新计算总权益。")
            }
        }
        .navigationTitle("数据说明").navigationBarTitleDisplayMode(.inline)
    }

    private func explanation(_ title:String,_ detail:String) -> some View {
        VStack(alignment:.leading,spacing:6) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }
        .textSelection(.enabled)
        .cryptoSettingsRowSeparators()
    }
}

private struct CryptoCredentialLink: View {
    let exchange:String
    let title:String
    var tokenOnly=false
    @State private var configured:Bool?
    @State private var loadFailed=false

    var body: some View {
        NavigationLink {
            CryptoCredentialEditor(exchange:exchange,title:title,tokenOnly:tokenOnly,onSave:loadStatus)
        } label: {
            HStack {
                Text(title)
                Spacer()
                if configured == true {
                    Label("已配置",systemImage:"checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else if loadFailed {
                    Text("读取失败").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .cryptoSettingsRowSeparators()
        .accessibilityValue(loadFailed ? "配置状态读取失败" : configured.map { $0 ? "已配置" : "未配置" } ?? "正在读取配置")
        .task { loadStatus() }
    }

    private func loadStatus() {
        do {
            let credential=try CryptoCredential.load(exchange)
            configured=tokenOnly ? !credential.key.isEmpty : credential.configured
            loadFailed=false
        } catch {
            configured=nil;loadFailed=true
        }
    }
}

private struct CryptoCredentialEditor: View {
    let exchange:String
    let title:String
    var tokenOnly=false
    var onSave:()->Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var credential=CryptoCredential()
    @State private var loaded=false
    @State private var error:String?
    var body: some View {
        Form {
            Section {
                VStack(alignment:.leading,spacing:6) {
                    Text(tokenOnly ? "API Token" : "API Key").font(.subheadline).foregroundStyle(.secondary)
                    SecureField(tokenOnly ? "输入 API Token" : "输入 API Key",text:$credential.key)
                        .accessibilityLabel(tokenOnly ? "API Token" : "API Key")
                }
                if !tokenOnly {
                    VStack(alignment:.leading,spacing:6) {
                        Text("Secret Key").font(.subheadline).foregroundStyle(.secondary)
                        SecureField("输入 Secret Key",text:$credential.secret).accessibilityLabel("Secret Key")
                    }
                    Text("使用只读权限。").font(.caption)
                }
            }.textInputAutocapitalization(.never).autocorrectionDisabled().disabled(!loaded)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack(spacing:12) {
                Button("取消") { dismiss() }.buttonStyle(HakoActionButtonStyle(primary:false))
                Button("保存配置") { save() }.buttonStyle(HakoActionButtonStyle()).disabled(!loaded)
            }.listRowBackground(Color.clear)
            if !loaded { Button("重试读取") { load() } }
        }.navigationTitle(title).navigationBarTitleDisplayMode(.inline).task { load() }
    }
    private func load() { do { credential=try CryptoCredential.load(exchange);loaded=true;error=nil } catch { self.error=error.localizedDescription } }
    private func save() {
        do {
            credential.key=credential.key.trimmingCharacters(in:.whitespacesAndNewlines)
            credential.secret=tokenOnly ? credential.key : credential.secret.trimmingCharacters(in:.whitespacesAndNewlines)
            try credential.save(exchange);onSave();dismiss()
        } catch { self.error=error.localizedDescription }
    }
}

private struct CryptoWalletEditor: View {
    @State var wallet:CryptoWallet
    let existing:[CryptoWallet]
    let onSave:([CryptoWallet])->Void
    @Environment(\.dismiss) private var dismiss
    @State private var error:String?
    var body: some View {
        NavigationStack {
            Form {
                VStack(alignment:.leading,spacing:6) {
                    Text("地址名称").font(.subheadline).foregroundStyle(.secondary)
                    TextField("例如：我的冷钱包",text:$wallet.name).accessibilityLabel("地址名称")
                }
                Picker("网络",selection:$wallet.network) { ForEach(CryptoWallet.networks,id:\.self) { Text($0) } }
                VStack(alignment:.leading,spacing:6) {
                    Text("钱包公开地址").font(.subheadline).foregroundStyle(.secondary)
                    TextField("完整公开地址",text:$wallet.address).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("钱包公开地址")
                }
                if wallet.network == CryptoWallet.cosmosHub {
                    Text("填写 cosmos1 开头的 Cosmos Hub 地址，无需配置 Token。").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                HStack(spacing:12) {
                    Button("取消") { dismiss() }.buttonStyle(HakoActionButtonStyle(primary:false))
                    Button("保存地址") { save() }.buttonStyle(HakoActionButtonStyle())
                }.listRowBackground(Color.clear)
            }.navigationTitle(existing.contains(where:{$0.id==wallet.id}) ? "编辑观察地址" : "添加观察地址").navigationBarTitleDisplayMode(.inline)
        }
    }
    private func save() {
        do {
            wallet.address=wallet.address.trimmingCharacters(in:.whitespacesAndNewlines)
            wallet.name=wallet.name.trimmingCharacters(in:.whitespacesAndNewlines)
            try wallet.validate();var next=existing.filter{$0.id != wallet.id};next.append(wallet)
            try CryptoWallet.save(next);onSave(next);dismiss()
        } catch { self.error=error.localizedDescription }
    }
}

private extension View {
    func cryptoSettingsRowSeparators() -> some View {
        frame(maxWidth:.infinity,alignment:.leading)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}
