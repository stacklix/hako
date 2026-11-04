import SwiftUI

struct CryptoSettingsView: View {
    var body: some View {
        Form {
            Section("交易所接口") {
                NavigationLink("HTX · API Key / Secret Key") { CryptoCredentialEditor(exchange:"htx",title:"HTX 接口") }
                NavigationLink("Binance · API Key / Secret Key") { CryptoCredentialEditor(exchange:"binance",title:"Binance 接口") }
            }
            Section("链上资产") {
                NavigationLink("观察地址管理") { CryptoWalletSettings() }
                NavigationLink("TRONSCAN API Token") { CryptoCredentialEditor(exchange:"tronscan",title:"TRONSCAN",tokenOnly:true) }
                NavigationLink("Moralis API Token · Ethereum / BSC") { CryptoCredentialEditor(exchange:"moralis",title:"Moralis",tokenOnly:true) }
                Text("链上估值涵盖可定价的代币，不含 NFT、借贷或协议内头寸；Ethereum / BSC 按数据服务的净值口径过滤垃圾代币。").font(.caption)
            }
            Section("私有仓库归档") {
                Text("在主应用 GitHub 配置中设置私有仓库；已有公开库继续服务运动与使用记录。")
                Text("TRX 合约：data/crypto/htx-trx/年份.csv\n总资产：data/crypto/portfolio/年份.csv").font(.caption).textSelection(.enabled)
            }
            Section("自动触发") {
                Text("在快捷指令中添加「同步加密资产」，可设置每日自动化；打开子应用时也会在后台执行。")
                Text("合约采集前一天的最后结算权益与日度资金费；总资产采集当天首次成功获取的完整快照。各自成功同步后，当天再次触发会跳过；失败保留待同步数据。时区：Asia/Shanghai。")
            }
        }.navigationTitle("资产设置").navigationBarTitleDisplayMode(.inline)
    }
}

private struct CryptoCredentialEditor: View {
    let exchange:String
    let title:String
    var tokenOnly=false
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
                    Text("使用只读权限。凭据保存在本机钥匙串，不写入 GitHub。").font(.caption)
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
            try credential.save(exchange);dismiss()
        } catch { self.error=error.localizedDescription }
    }
}

struct CryptoWalletSettings: View {
    @State private var wallets:[CryptoWallet]=[]
    @State private var editing:CryptoWallet?
    @State private var error:String?
    var body: some View {
        List {
            Section {
                Button("添加观察地址",systemImage:"plus") { editing=CryptoWallet() }
                ForEach(wallets) { wallet in
                    Button { editing=wallet } label: {
                        VStack(alignment:.leading,spacing:5) {
                            Text(wallet.name).foregroundStyle(.primary)
                            Text(wallet.network+" · "+wallet.address).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.onDelete { indices in
                    var next=wallets;next.remove(atOffsets:indices)
                    do { try CryptoWallet.save(next);wallets=next } catch { self.error=error.localizedDescription }
                }
            } footer: { Text("左滑可移除地址。只保存观察地址，不需要钱包私钥。") }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.navigationTitle("观察地址").navigationBarTitleDisplayMode(.inline)
            .task { do { wallets=try CryptoWallet.load() } catch { self.error=error.localizedDescription } }
            .sheet(item:$editing) { wallet in CryptoWalletEditor(wallet:wallet,existing:wallets) { wallets=$0 } }
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
                Picker("网络",selection:$wallet.network) { ForEach(["TRON","Ethereum","BNB Smart Chain"],id:\.self) { Text($0) } }
                VStack(alignment:.leading,spacing:6) {
                    Text("钱包公开地址").font(.subheadline).foregroundStyle(.secondary)
                    TextField("完整公开地址",text:$wallet.address).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("钱包公开地址")
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
