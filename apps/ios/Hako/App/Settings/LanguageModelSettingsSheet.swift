import SwiftUI
import UIKit

@MainActor
struct LanguageModelSettingsSheet: View {
    @State private var profiles = LanguageModelProfiles()
    @State private var editing: LanguageModelProfile?
    @State private var loadFailed = false
    @State private var error: String?

    var body: some View {
        SettingsSheet(title: "大模型") {
            Form {
                if let active = profiles.active {
                    Section {
                        if profiles.entries.count > 1 {
                            Picker("当前模型", selection: Binding(get: { active.id }, set: select)) {
                                ForEach(profiles.entries) { profile in Text(profile.name).tag(profile.id) }
                            }
                            .pickerStyle(.menu)
                        } else {
                            LabeledContent("当前模型", value: active.name)
                        }
                    } footer: {
                        Text("记账助手使用这里选中的模型。切换后，下一条消息会开启新对话。")
                    }
                }
                Section("模型配置") {
                    ForEach(profiles.entries) { profile in
                        Button { editing = profile } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.name).foregroundStyle(.primary)
                                    Text(profile.configuration.format.title + " · " + profile.configuration.model)
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                                    .foregroundStyle(.tertiary).accessibilityHidden(true)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    }
                    Button { editing = LanguageModelProfile() } label: {
                        Label("添加模型", systemImage: "plus")
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
            }
            .disabled(loadFailed)
        }
        .onAppear(perform: load)
        .sheet(item: $editing, onDismiss: load) { profile in
            LanguageModelProfileEditor(profile: profile, existing: profiles.entries.contains { $0.id == profile.id })
        }
        .alert("大模型配置", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func load() {
        do { profiles = try LanguageModelProfiles.load(); loadFailed = false }
        catch { loadFailed = true; self.error = error.localizedDescription }
    }

    private func select(_ id: UUID) {
        guard id != profiles.active?.id else { return }
        do { profiles = try LanguageModelProfiles.update { try $0.select(id) } }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor
private struct LanguageModelProfileEditor: View {
    private struct ConnectionCheck: Identifiable {
        let id: String
        var failure: String? = nil
    }

    @Environment(\.dismiss) private var dismiss
    let original: LanguageModelProfile
    let existing: Bool
    @State private var draft: LanguageModelProfile
    @State private var testing = false
    @State private var checks: [ConnectionCheck] = []
    @State private var error: String?
    @State private var confirmsClear = false

    init(profile: LanguageModelProfile, existing: Bool) {
        original = profile
        self.existing = existing
        _draft = State(initialValue: profile)
    }

    private var validConfiguration: Bool { (try? draft.configuration.endpoint()) != nil }

    var body: some View {
        SettingsSheet(title: existing ? "编辑模型" : "添加模型", hasChanges: draft != original, isBusy: testing,
                      saveEnabled: validConfiguration && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      onSave: save) {
            Form {
                Section {
                    field("配置名称") { TextField("例如工作模型", text: $draft.name) }
                    Picker("API 格式", selection: $draft.configuration.format) {
                        ForEach(LanguageModelFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    field("API Base URL") {
                        TextField("https://example.com/v1", text: $draft.configuration.baseURL)
                            .keyboardType(.URL)
                    }
                    field("模型 ID") { TextField("服务商提供的模型 ID", text: $draft.configuration.model) }
                    field("API Token") { SecureField("输入 API Token", text: $draft.configuration.token) }
                } footer: {
                    Text("配置保存在本机钥匙串。使用记账助手时，发送的消息、图片和查询所需的账本数据会传给所填的模型服务。")
                }
                Section {
                    connectionTest
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .disabled(testing)
            .onChange(of: draft.configuration.format) { old, new in
                if draft.configuration.baseURL == old.defaultURL { draft.configuration.baseURL = new.defaultURL }
            }
            .onChange(of: draft.configuration) { checks = [] }
        }
        .hakoDeleteConfirmation(Text("删除这项模型配置？"), isPresented: $confirmsClear, disabled: testing, confirm: clear)
        .alert("大模型配置", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var connectionTest: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                if existing {
                    Button("删除模型配置", role: .destructive) { confirmsClear = true }
                        .buttonStyle(HakoActionButtonStyle(destructive: true))
                }
                Button(testing ? "正在测试…" : "测试连接") { Task { await testConnection() } }
                    .buttonStyle(HakoActionButtonStyle())
                    .disabled(testing || !validConfiguration)
            }
            if !checks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(checks) { check in
                        checkRow(check)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    private func checkRow(_ check: ConnectionCheck) -> some View {
        let passed = check.failure == nil
        let statusColor = passed ? HakoStyle.adaptive(0x18743b, 0x5cdb83) : HakoStyle.adaptive(0xa52b38, 0xff9da8)
        return VStack(alignment: .leading, spacing: 3) {
            LabeledContent {
                Label(passed ? "通过" : "失败", systemImage: passed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(statusColor)
            } label: {
                Text(check.id).font(.subheadline)
            }
            if let failure = check.failure {
                Text(failure)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            content()
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel(Text(title))
        }
    }

    private func save() {
        do { try LanguageModelProfiles.update { try $0.upsert(draft) }; dismiss() }
        catch { self.error = error.localizedDescription }
    }

    private func clear() {
        do { try LanguageModelProfiles.update { $0.remove(draft.id) }; dismiss() }
        catch { self.error = error.localizedDescription }
    }

    @MainActor
    private func testConnection() async {
        guard !testing else { return }
        testing = true
        checks = []
        defer { testing = false }
        let client = LanguageModelClient(configuration: draft.configuration)
        let probe = LanguageModelTool(name: "hako_probe", description: "Checks whether the app can receive a tool call.",
                                      properties: ["value": ["type": "string", "description": "The text to echo."]], required: ["value"])
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 96)).image { context in
            context.cgContext.setFillColor(UIColor.red.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        }.jpegData(compressionQuality: 0.8)
        do {
            let reply = try await client.complete(system: "You are performing a connection test.", messages: [client.userMessage("Reply OK.")])
            guard !reply.text.isEmpty else { throw LanguageModelError.unreadable }
            checks.append(.init(id: "文本"))
        } catch {
            checks.append(.init(id: "文本", failure: error.localizedDescription))
            return
        }
        do {
            let message = client.userMessage("Call hako_probe with value set to 'ping'. Return the tool call to the app.")
            let reply = try await client.complete(system: "You are performing a tool call test.", messages: [message], tools: [probe])
            let supported = reply.calls.contains { $0.name == probe.name && $0.arguments?["value"] as? String == "ping" }
            checks.append(.init(id: "工具调用", failure: supported ? nil : "未收到有效调用"))
        } catch { checks.append(.init(id: "工具调用", failure: error.localizedDescription)) }
        if let image {
            do {
                let message = client.userMessage("Name the color in the image. Answer with one English word.", image: image)
                let reply = try await client.complete(system: "You are performing a vision test.", messages: [message])
                let word = reply.text.lowercased().split(whereSeparator: { !$0.isLetter })
                checks.append(.init(id: "图片", failure: word.contains("red") ? nil : "未识别测试图颜色"))
            } catch { checks.append(.init(id: "图片", failure: error.localizedDescription)) }
        }
    }
}
