import SwiftUI
import Combine

struct HakoTokensView: View {
    @State private var definitions: [HakoTokenDefinition] = []
    @State private var records: [String: HakoTokenVault.Record] = [:]
    @State private var errors: [String: String] = [:]
    @State private var error: String?
    @State private var editing: HakoTokenDefinition?
    @State private var validationResults: [String: HakoCredentialValidationResult] = [:]
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SettingsSheet(title: "金融 API Token") {
            Form {
                Section {
                    Text("由主应用统一保存，按子应用 JSON 声明加载，并显示密钥 key 与使用子应用。")
                }
                ForEach(definitions) { definition in
                    Section {
                        Button { editing = definition } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(definition.title).foregroundStyle(.primary)
                                    Spacer()
                                    Text(status(definition.id)).font(.caption).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                                ForEach(definition.fields) { field in
                                    Text(field.title + " · key: " + field.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Text("使用子应用：" + definition.applications.joined(separator: "、"))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let result = validationResults[definition.id] {
                                    Text(result.title + " · " + result.checkedAt.formatted(date: .omitted, time: .shortened))
                                        .font(.caption).foregroundStyle(result.status == .passed ? Color.green : Color.secondary)
                                }
                                if let issue = errors[definition.id] { Text(issue).font(.caption).foregroundStyle(.red) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    }
                }
                Section {
                    Button("重新读取", action: load)
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
        }
        .task { load() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { load() } }
        .onReceive(NotificationCenter.default.publisher(for: HakoTokenVault.didSave).receive(on: RunLoop.main)) { _ in load() }
        .sheet(item: $editing) { definition in
            HakoTokenEditor(definition: definition, onSave: load, onResult: { validationResults[definition.id] = $0 })
        }
    }

    private func status(_ id: String) -> String {
        if errors[id] != nil { return "读取失败" }
        guard let values = records[id]?.values else { return "未读取" }
        if values.values.allSatisfy({ !$0.isEmpty }) { return "已配置" }
        return values.values.allSatisfy({ $0.isEmpty }) ? "未配置" : "配置不完整"
    }

    private func load() {
        do {
            definitions = try HakoTokens.shared.definitions()
            error = nil
            for definition in definitions {
                do {
                    let record = try HakoTokens.shared.read(definition.id)
                    if records[definition.id]?.values != record.values { validationResults[definition.id] = nil }
                    records[definition.id] = record; errors[definition.id] = nil
                }
                catch {
                    records[definition.id] = nil; validationResults[definition.id] = nil
                    errors[definition.id] = error.localizedDescription
                }
            }
        } catch { self.error = error.localizedDescription }
    }
}

private struct HakoTokenEditor: View {
    let definition: HakoTokenDefinition
    var onSave: () -> Void
    var onResult: (HakoCredentialValidationResult?) -> Void
    @State private var values: [String: String] = [:]
    @State private var original: [String: String]?
    @State private var error: String?
    @State private var validating = false
    @State private var validationRequest = UUID()
    @State private var result: HakoCredentialValidationResult?
    @State private var revealedKeys: Set<String> = []
    @Environment(\.scenePhase) private var scenePhase

    private var hasChanges: Bool { original.map { $0 != values } ?? false }
    var body: some View {
        SettingsSheet(title: definition.title, hasChanges: hasChanges, saveEnabled: hasChanges && !validating, onSave: save) {
            Form {
                Section {
                    ForEach(definition.fields) { field in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top) {
                                Text(field.key).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 8)
                                Button {
                                    if !revealedKeys.insert(field.key).inserted { revealedKeys.remove(field.key) }
                                } label: {
                                    Image(systemName: revealedKeys.contains(field.key) ? "eye" : "eye.slash")
                                        .frame(minWidth: 44, minHeight: 44)
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel((revealedKeys.contains(field.key) ? "隐藏 " : "显示 ") + field.title)
                                .accessibilityValue(revealedKeys.contains(field.key) ? "已显示" : "已隐藏")
                            }
                            HakoSecureTextEditor(
                                text: Binding(get: { values[field.key] ?? "" }, set: { values[field.key] = $0 }),
                                isSecure: !revealedKeys.contains(field.key), label: field.title + "，key: " + field.key)
                                .frame(minHeight: 88, alignment: .topLeading)
                                .privacySensitive()
                                .overlay(alignment: .topLeading) {
                                    if (values[field.key] ?? "").isEmpty {
                                        Text("输入 " + field.title).font(.body.monospaced())
                                            .foregroundStyle(.tertiary).padding(.top, 8)
                                            .allowsHitTesting(false).accessibilityHidden(true)
                                    }
                                }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    }
                } footer: {
                    Text("使用子应用：" + definition.applications.joined(separator: "、") + "。保存后由这些子应用读取同一组凭据。全部留空并保存可清除凭据。")
                }
                .textInputAutocapitalization(.never).autocorrectionDisabled().disabled(original == nil || validating)
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        if validating { invalidateValidation() }
                        else { result = nil; onResult(nil); validating = true; validationRequest = UUID() }
                    } label: {
                        HStack {
                            if validating { ProgressView() }
                            Text(validating ? "取消验证" : "验证已保存的凭据")
                        }
                    }
                    .buttonStyle(HakoActionButtonStyle(primary: false))
                    .disabled(original == nil || hasChanges || values.values.contains(where: { $0.isEmpty }))
                    Text(hasChanges ? "请先保存修改，再验证。" : "仅运行子应用提供的只读验证；验证通过只代表本次检测接口可用。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                if let result {
                    Section {
                        Text(result.title).font(.subheadline.weight(.medium))
                            .foregroundStyle(result.status == .passed ? Color.green : Color.primary)
                        Text(result.message).font(.footnote).foregroundStyle(.secondary)
                        LabeledContent("验证时间", value: result.checkedAt.formatted(date: .abbreviated, time: .standard))
                    }
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
                if original == nil { Button("重试读取", action: load) }
            }
        }
        .task { load() }
        .task(id: validationRequest) {
            if validating { await validate() }
        }
        .onChange(of: values) { _, _ in if hasChanges { invalidateValidation() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { revealedKeys.removeAll() } }
    }

    private func load() {
        do { values = try HakoTokens.shared.read(definition.id).values; original = values; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func save() {
        do {
            try HakoTokens.shared.save(values, for: definition.id)
            invalidateValidation()
            load()
            onSave()
        }
        catch { self.error = error.localizedDescription }
    }

    private func invalidateValidation() {
        validationRequest = UUID(); validating = false; result = nil; onResult(nil)
    }

    private func validate() async {
        let request = validationRequest
        defer { if request == validationRequest { validating = false } }
        do {
            let saved = try HakoTokens.shared.read(definition.id).values
            guard original == saved, !hasChanges else {
                load(); error = "凭据已在别处更新，已重新读取，请再次验证。"; return
            }
            error = nil
            let checked = try await HakoApplications.credentialValidators.validate(definition, credentials: saved)
            try Task.checkCancellation()
            guard request == validationRequest else { return }
            guard try HakoTokens.shared.read(definition.id).values == saved else {
                load(); result = nil; onResult(nil)
                error = "凭据已变更，本次验证结果已丢弃，请重新验证。"; return
            }
            result = checked; onResult(checked)
        } catch is CancellationError { }
        catch { if request == validationRequest { self.error = error.localizedDescription } }
    }
}
