import SwiftUI

struct CryptoSettingsView: View {
    @State private var wallets:[CryptoWallet]=[]
    @State private var editing:CryptoWallet?
    @State private var walletError:String?
    var body: some View {
        Form {
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
                Text("点击地址可编辑，左滑可移除。只保存观察地址，不需要钱包私钥。")
            }
            Section("链上浏览器") {
                CryptoCredentialLink(exchange:"tronscan",title:"TRONSCAN",tokenOnly:true)
                CryptoCredentialLink(exchange:"moralis",title:"Moralis",tokenOnly:true)
            }
            Section("私有仓库归档") {
                Text("TRX 合约：data/crypto/htx-trx/年份.csv").font(.caption).textSelection(.enabled).cryptoSettingsRowSeparators()
                Text("总资产：data/crypto/portfolio/年份.csv").font(.caption).textSelection(.enabled).cryptoSettingsRowSeparators()
            }
        }.navigationTitle("资产设置").navigationBarTitleDisplayMode(.inline)
            .task {
                do { wallets=try CryptoWallet.load();walletError=nil } catch { walletError=error.localizedDescription }
            }
            .sheet(item:$editing) { wallet in
                CryptoWalletEditor(wallet:wallet,existing:wallets) { wallets=$0;walletError=nil }
            }
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

private extension View {
    func cryptoSettingsRowSeparators() -> some View {
        frame(maxWidth:.infinity,alignment:.leading)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }
}
