import SwiftUI

struct HeadplaneSettingsView: View {
    @ObservedObject var store: HeadplaneStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = HeadplaneConnection()
    @State private var original = HeadplaneConnection()
    @State private var error: String?
    @State private var disconnect = false
    var body: some View {
        HeadplaneSheet(title: "连接设置", busy: store.busy, dirty: draft != original) {
            HeadplaneField(title: "实例名称") { TextField("Homelab", text: $draft.name) }
            HeadplaneField(title: "Headplane 地址") {
                TextField("https://headplane.example.com/admin", text: $draft.address)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            HeadplaneField(title: "API Key") {
                SecureField("Headscale API Key", text: $draft.apiKey).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Toggle("允许 HTTP 不加密连接", isOn: $draft.allowHTTP).font(.subheadline)
            if draft.allowHTTP { Text("HTTP 会以未加密方式传输密钥和会话。").font(.footnote).foregroundStyle(HeadplaneStyle.orange) }
            Text("填写 Headplane 的管理页面地址。凭据仅保存在本机 Keychain，连接验证成功后才会保存。").font(.footnote).foregroundStyle(HeadplaneStyle.muted)
            HeadplaneErrorText(message: error ?? store.configurationError)
            Button(store.busy ? "正在验证连接…" : "验证并保存") {
                Task {
                    error = nil
                    do { try await store.connect(draft); dismiss() }
                    catch { self.error = error.localizedDescription }
                }
            }.buttonStyle(HeadplaneButtonStyle(primary: true))
                .disabled(store.busy || store.pending != nil || store.configurationError != nil)
            if store.connection != nil {
                Button("移除此连接", role: .destructive) { disconnect = true }
                    .frame(maxWidth: .infinity).padding(.top, 10).disabled(store.busy || store.pending != nil)
            }
        }
        .onAppear { draft = store.connection ?? HeadplaneConnection(); original = draft }
        .confirmationDialog("移除本机保存的连接和凭据？", isPresented: $disconnect, titleVisibility: .visible) {
            Button("移除连接", role: .destructive) {
                do { try store.disconnect(); dismiss() } catch { self.error = error.localizedDescription }
            }
        }
    }
}

struct HeadplaneDeviceView: View {
    @ObservedObject var store: HeadplaneStore
    let nodeID: String
    let revision: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var editing: String?
    @State private var confirmation: String?
    @State private var error: String?
    private var node: HeadplaneNode? { store.machines?.nodes.first { $0.id == nodeID } }
    private var disabled: Bool { store.busy || store.pending != nil || revision != store.revision || store.machines?.writable != true }
    var body: some View {
        HeadplaneSheet(title: "设备详情", busy: store.busy) {
            if let node {
                Image(systemName: node.symbol).font(.title2).frame(width: 50, height: 50)
                    .background(HeadplaneStyle.fill, in: RoundedRectangle(cornerRadius: 15))
                Text(node.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                HeadplaneBadge(text: node.status, good: node.online && !node.expired)
                HeadplaneFact(title: "Tailnet IP", value: node.addresses.joined(separator: "\n"))
                if !node.os.isEmpty { HeadplaneFact(title: "系统", value: node.os) }
                if !node.version.isEmpty { HeadplaneFact(title: "客户端版本", value: node.version) }
                HeadplaneFact(title: "所属用户", value: node.userName.isEmpty ? "标签设备" : node.userName)
                HeadplaneFact(title: "设备标签", value: node.tags.isEmpty ? "无" : node.tags.joined(separator: "\n"))
                HeadplaneFact(title: "最后在线", value: HeadplaneDate.display(node.lastSeen))
                HeadplaneFact(title: "密钥到期", value: HeadplaneDate.display(node.expiry, empty: "不过期"))
                if !node.availableRoutes.isEmpty { HeadplaneFact(title: "公布路由", value: node.availableRoutes.joined(separator: "\n")) }
                HeadplaneErrorText(message: error)
                if let message = store.message { Text(message).font(.footnote).foregroundStyle(HeadplaneStyle.orange) }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    Button("重命名") { editing = "rename" }.buttonStyle(HeadplaneButtonStyle())
                    Button("修改标签") { editing = "tags" }.buttonStyle(HeadplaneButtonStyle())
                    Button("使设备过期") { confirmation = "expire" }.buttonStyle(HeadplaneButtonStyle())
                    Button("删除设备") { confirmation = "delete" }.buttonStyle(HeadplaneButtonStyle(destructive: true))
                }.disabled(disabled)
                if store.pending != nil { Button("刷新并核对状态") { Task { await store.refresh(.machines) } } }
            } else { Text("设备已被移除或连接已改变。").foregroundStyle(HeadplaneStyle.muted) }
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let node, let editing { HeadplaneDeviceEditor(store: store, node: node, action: editing, revision: revision) }
        }
        .confirmationDialog(confirmation == "delete" ? "删除此设备？" : "使设备立即过期？", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            if let action = confirmation {
                Button(action == "delete" ? "确认删除" : "确认过期", role: .destructive) {
                    Task {
                        do {
                            _ = try await store.mutate(.machines, revision: revision, fields: ["action_id": action, "node_id": nodeID])
                            if action == "delete" { dismiss() }
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        } message: { Text(confirmation == "delete" ? "设备将从网络移除，需要重新注册才能加入。" : "设备需要重新认证才能继续连接网络。") }
    }
}

private struct HeadplaneDeviceEditor: View {
    @ObservedObject var store: HeadplaneStore
    let node: HeadplaneNode
    let action: String
    let revision: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var value = ""
    @State private var error: String?
    private var original: String { action == "rename" ? node.name : node.tags.joined(separator: ", ") }
    var body: some View {
        HeadplaneSheet(title: action == "rename" ? "重命名设备" : "修改标签", busy: store.busy, dirty: value != original) {
            HeadplaneField(title: action == "rename" ? "设备名称" : "设备标签") {
                TextField(action == "rename" ? "设备名称" : "tag:router, tag:home", text: $value)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if action == "tags" { Text("多个标签用逗号分隔。清空后将移除已设置的标签。").font(.footnote).foregroundStyle(HeadplaneStyle.muted) }
            HeadplaneErrorText(message: error)
            Button("保存修改") { Task { await save() } }.buttonStyle(HeadplaneButtonStyle(primary: true))
                .disabled(store.busy || store.pending != nil || value == original || store.revision != revision)
        }.onAppear { value = original }
    }
    private func save() async {
        var fields = ["node_id": node.id]
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if action == "rename" {
            guard text.range(of: "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", options: .regularExpression) != nil else {
                error = "名称需为 1–63 位小写字母、数字或连字符，首尾不能为连字符。"; return
            }
            fields["action_id"] = "rename"; fields["name"] = text
        } else {
            let tags = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard tags.allSatisfy({ $0.range(of: "^tag:[a-zA-Z][a-zA-Z0-9-]*$", options: .regularExpression) != nil }) else {
                error = "标签需以 tag: 开头，仅包含字母、数字或连字符。"; return
            }
            fields["action_id"] = "update_tags"; fields["tags"] = tags.joined(separator: ",")
        }
        do { _ = try await store.mutate(.machines, revision: revision, fields: fields); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

struct HeadplanePolicyEditor: View {
    @ObservedObject var store: HeadplaneStore
    let original: String
    let revision: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var error: String?
    @State private var preview = false
    @State private var confirm = false
    private var writable: Bool { store.policy?.writable == true && store.revision == revision }
    var body: some View {
        HeadplaneSheet(title: writable ? "编辑原始策略" : "原始策略", busy: store.busy, dirty: writable && draft != original) {
            Text("访问策略 · HuJSON").font(.subheadline).foregroundStyle(HeadplaneStyle.muted)
            if writable {
                TextEditor(text: $draft).font(.system(.caption, design: .monospaced)).frame(minHeight: 300)
                    .scrollContentBackground(.hidden).padding(10).background(HeadplaneStyle.fill, in: RoundedRectangle(cornerRadius: 10))
                    .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("访问策略 HuJSON")
            } else { Text(original).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            Text(writable ? "保留原文及注释。保存前会检查远端是否变化，规则合法性由服务器校验。" : "当前策略只读，需具备写权限且服务器使用数据库策略模式才能修改。")
                .font(.footnote).foregroundStyle(HeadplaneStyle.muted)
            HeadplaneErrorText(message: error)
            if writable {
                Button(preview ? "收起修改预览" : "预览修改") { preview.toggle() }.buttonStyle(HeadplaneButtonStyle())
                if preview {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("移除 / 新增的行").font(.caption)
                        ForEach(Array(changes.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption, design: .monospaced)).foregroundStyle(line.hasPrefix("−") ? HeadplaneStyle.red : HeadplaneStyle.green)
                        }
                    }.headplaneCard()
                }
                Button("保存策略") { confirm = true }.buttonStyle(HeadplaneButtonStyle(primary: true))
                    .disabled(draft == original || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy || store.pending != nil)
            }
        }
        .onAppear { draft = original }
        .confirmationDialog("应用此访问策略？", isPresented: $confirm, titleVisibility: .visible) {
            Button("确认保存") {
                Task {
                    do {
                        _ = try await store.mutate(.policy, revision: revision, fields: ["policy": draft], originalPolicy: original)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }
            }
        } message: { Text("规则变更会影响网络中设备的访问权限。") }
    }
    private var changes: [String] {
        let old = original.components(separatedBy: "\n"), new = draft.components(separatedBy: "\n")
        return new.difference(from: old).map {
            switch $0 { case .remove(_, let line, _): return "− " + line; case .insert(_, let line, _): return "+ " + line }
        }
    }
}
