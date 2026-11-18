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
                                ForEach(profiles.entries) { profile in Text(profile.name + " · " + profile.configuration.selectionSummary).tag(profile.id) }
                            }
                            .pickerStyle(.menu)
                        } else {
                            LabeledContent("当前模型", value: active.name)
                        }
                    } footer: {
                        Text("记账助手与青龙助手使用这里选中的模型。切换模型、速度或推理强度后，下一条消息会开启新对话。")
                    }
                }
                Section("模型配置") {
                    ForEach(profiles.entries) { profile in
                        Button { editing = profile } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(profile.name).foregroundStyle(.primary)
                                    Text(profile.configuration.selectionSummary)
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
        var skipped = false
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let original: LanguageModelProfile
    let existing: Bool
    @State private var draft: LanguageModelProfile
    @State private var testing = false
    @State private var checks: [ConnectionCheck] = []
    @State private var error: String?
    @State private var confirmsClear = false
    @State private var showsToken = false

    init(profile: LanguageModelProfile, existing: Bool) {
        self.existing = existing
        var initial = profile
        if !existing && initial.configuration.model.isEmpty, let preset = LanguageModelPreset.all.first {
            preset.configure(&initial.configuration)
            initial.name = preset.title
        }
        original = existing ? profile : initial
        _draft = State(initialValue: initial)
    }

    private var validConfiguration: Bool { (try? draft.configuration.endpoint()) != nil }
    private var preset: LanguageModelPreset? { LanguageModelPreset.matching(draft.configuration) }
    private var providerSelection: Binding<String> {
        Binding(get: { preset?.provider.rawValue ?? "custom" }, set: { id in
            if let next = LanguageModelPreset.all.first(where: { $0.provider.rawValue == id }) { choose(next) }
            else {
                draft.configuration.presetID = nil
                draft.configuration.speed = nil
                draft.configuration.reasoningEffort = nil
            }
        })
    }

    var body: some View {
        SettingsSheet(title: existing ? "编辑模型" : "添加模型", hasChanges: draft != original, isBusy: testing,
                      saveEnabled: validConfiguration && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      onSave: save) {
            Form {
                Section {
                    Picker("服务商", selection: providerSelection) {
                        ForEach(LanguageModelProvider.allCases) { provider in Text(provider.title).tag(provider.rawValue) }
                        Text("自定义接口").tag("custom")
                    }.pickerStyle(.menu)
                    if let preset {
                        Picker("模型", selection: Binding(get: { preset.id }, set: { id in
                            if let next = LanguageModelPreset.all.first(where: { $0.id == id }) { choose(next) }
                        })) {
                            ForEach(LanguageModelPreset.all.filter { $0.provider == preset.provider }) { model in
                                Text(model.title).tag(model.id)
                            }
                        }.pickerStyle(.menu)
                        if preset.provider.endpoints.count > 1 {
                            Picker("服务区域", selection: Binding(get: { draft.configuration.baseURL }, set: { url in
                                if draft.configuration.baseURL != url { draft.configuration.token = "" }
                                draft.configuration.baseURL = url
                            })) {
                                ForEach(preset.provider.endpoints, id: \.url) { endpoint in Text(endpoint.title).tag(endpoint.url) }
                            }.pickerStyle(.menu)
                        }
                        if preset.speeds.count > 1 {
                            Picker("速度", selection: Binding(get: { draft.configuration.speed ?? .standard }, set: { draft.configuration.speed = $0 })) {
                                ForEach(preset.speeds) { speed in Text(speed.title).tag(speed) }
                            }.pickerStyle(.menu)
                        } else { LabeledContent("速度", value: "标准（无独立加速档）") }
                        if !preset.efforts.isEmpty {
                            Picker("推理强度", selection: Binding(get: { draft.configuration.reasoningEffort ?? "" }, set: {
                                draft.configuration.reasoningEffort = $0.isEmpty ? nil : $0
                            })) {
                                Text("服务商默认").tag("")
                                ForEach(preset.efforts, id: \.self) { Text(LanguageModelPreset.effortTitle($0)).tag($0) }
                            }.pickerStyle(.menu)
                        } else { LabeledContent("推理强度", value: "由模型自动控制") }
                    } else {
                        field("配置名称") { TextField("例如工作模型", text: $draft.name) }
                        Picker("API 格式", selection: $draft.configuration.format) {
                            ForEach(LanguageModelFormat.allCases) { format in Text(format.title).tag(format) }
                        }
                        field("API Base URL") {
                            TextField("https://example.com/v1", text: $draft.configuration.baseURL).keyboardType(.URL)
                        }
                        field("模型 ID") { TextField("服务商提供的模型 ID", text: $draft.configuration.model) }
                    }
                } header: {
                    Text("选择模型")
                } footer: {
                    if let preset {
                        Text("官方接口已配置，只需填写对应服务商的 Token。快速档可能额外收费；推理越高，等待和用量通常越大。" +
                             (preset.images ? "" : "此模型不支持图片，可选择 DeepSeek Flash 处理图片。"))
                    } else { Text("自定义接口使用服务商默认速度和推理参数。") }
                }
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("API Token").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Button { showsToken.toggle() } label: {
                                Image(systemName: showsToken ? "eye" : "eye.slash")
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(showsToken ? "隐藏 API Token" : "显示 API Token")
                            .accessibilityValue(showsToken ? "已显示" : "已隐藏")
                        }
                        HakoSecureTextEditor(text: $draft.configuration.token, isSecure: !showsToken, label: "API Token")
                            .frame(minHeight: 88, alignment: .topLeading)
                            .privacySensitive()
                            .overlay(alignment: .topLeading) {
                                if draft.configuration.token.isEmpty {
                                    Text("输入 API Token").font(.body.monospaced())
                                        .foregroundStyle(.tertiary).padding(.top, 8)
                                        .allowsHitTesting(false).accessibilityHidden(true)
                                }
                            }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                } header: {
                    Text("访问凭据")
                } footer: {
                    Text("Token 仅保存在本机钥匙串。使用记账助手时，消息、图片和必要的账本数据会发送给所选服务商。")
                }
                if preset != nil {
                    Section {
                        DisclosureGroup("配置名称") {
                            field("名称") { TextField("模型配置名称", text: $draft.name) }
                        }
                    }
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
            .onChange(of: draft.configuration.baseURL) { old, new in
                if URL(string: old)?.host != URL(string: new)?.host { draft.configuration.token = "" }
            }
            .onChange(of: draft.configuration) { checks = [] }
        }
        .hakoDeleteConfirmation(Text("删除这项模型配置？"), isPresented: $confirmsClear, disabled: testing, confirm: clear)
        .onChange(of: scenePhase) { _, phase in if phase != .active { showsToken = false } }
        .alert("大模型配置", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func choose(_ preset: LanguageModelPreset) {
        let previousTitle = self.preset?.title
        preset.configure(&draft.configuration)
        if !existing || draft.name.isEmpty || draft.name == previousTitle { draft.name = preset.title }
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
        let statusColor = check.skipped ? HakoStyle.muted : passed ? HakoStyle.adaptive(0x18743b, 0x5cdb83) : HakoStyle.adaptive(0xa52b38, 0xff9da8)
        return VStack(alignment: .leading, spacing: 3) {
            LabeledContent {
                Label(check.skipped ? "不支持" : passed ? "通过" : "失败", systemImage: check.skipped ? "minus.circle" : passed ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
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
        if preset?.images == false {
            checks.append(.init(id: "图片", skipped: true))
        } else if let image {
            do {
                let message = client.userMessage("Name the color in the image. Answer with one English word.", images: [image])
                let reply = try await client.complete(system: "You are performing a vision test.", messages: [message])
                let word = reply.text.lowercased().split(whereSeparator: { !$0.isLetter })
                checks.append(.init(id: "图片", failure: word.contains("red") ? nil : "未识别测试图颜色"))
            } catch { checks.append(.init(id: "图片", failure: error.localizedDescription)) }
        }
    }
}
