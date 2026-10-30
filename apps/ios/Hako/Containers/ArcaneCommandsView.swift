import SwiftUI
import UIKit

struct ArcaneCommandsSection: View {
    @ObservedObject var store: ArcaneStore
    @ObservedObject private var library = ArcaneCommandLibrary.shared
    let environment: ArcaneEnvironment
    let details: ArcaneContainerDetails
    @State private var editing: ArcaneCommandDefinition?
    @State private var terminal = false
    @State private var error: String?
    @State private var connectionID: String
    init(store: ArcaneStore, environment: ArcaneEnvironment, details: ArcaneContainerDetails) {
        self.store = store; self.environment = environment; self.details = details
        _connectionID = State(initialValue: store.connection?.id ?? "")
    }
    private var context: ArcaneCommandContext { ArcaneCommandContext(connection: connectionID, environment: environment.id, details: details) }
    private var caddy: Bool {
        let repository = (details.image ?? "").split(separator: "@").first?.split(separator: "/").last?.split(separator: ":").first.map(String.init)
        return repository?.lowercased() == "caddy" || details.displayName.lowercased() == "caddy"
    }
    private var customs: [ArcaneCommandDefinition] { library.definitions(context) }
    var body: some View {
        Group {
            if caddy {
                Section("常见操作") { ForEach(ArcaneCommandDefinition.caddy) { operation($0) } }
            }
            Section("容器终端") {
                Button { terminal = true } label: { Label("进入终端", systemImage: "terminal") }
                    .disabled(details.state?.status != "running" || store.terminalSessionID != nil || store.operationRunning || store.fileSaveRunning || store.pending != nil)
                    .arcaneRowSeparators()
            }
            Section {
                ForEach(customs) { definition in
                    operation(definition)
                        .contextMenu {
                            Button("编辑操作") { editing = definition }
                            Button("删除操作", role: .destructive) {
                                do { try library.remove(definition, context: context) } catch { self.error = error.localizedDescription }
                            }
                        }
                }
                if customs.isEmpty { Text("尚未添加自定义操作").foregroundStyle(.secondary).arcaneRowSeparators() }
            } header: {
                HStack {
                    Text("我的操作")
                    Spacer()
                    Button { editing = ArcaneCommandDefinition() } label: { Image(systemName: "plus").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("添加容器操作")
                }
            }
            if let history = library.results[context.stableKey], !history.isEmpty {
                Section("最近执行") {
                    ForEach(history) { result in
                        NavigationLink {
                            ArcaneCommandHistoryView(library: library, context: context, resultID: result.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(result.name)
                                HStack { Text(result.status); Text(result.began, style: .time) }.font(.caption).foregroundStyle(.secondary)
                            }
                        }.arcaneRowSeparators()
                    }
                }
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(.orange).arcaneRowSeparators() } }
        }
        .sheet(item: $editing) { definition in
            NavigationStack { ArcaneCommandEditor(library: library, context: context, initial: definition) }
        }
        .fullScreenCover(isPresented: $terminal) {
            ArcaneTerminalScreen(store: store, environment: environment, details: details, connectionID: connectionID)
        }
    }
    private func operation(_ definition: ArcaneCommandDefinition) -> some View {
        NavigationLink {
            ArcaneCommandRunView(store: store, library: library, environment: environment, details: details, context: context, definition: definition)
        } label: {
            Label(definition.name, systemImage: definition.id == "caddy.validate" ? "checkmark.shield" : definition.id == "caddy.reload" ? "arrow.clockwise" : "terminal")
        }.arcaneRowSeparators()
    }
}

private struct ArcaneCommandEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: ArcaneCommandLibrary
    let context: ArcaneCommandContext
    @State private var draft: ArcaneCommandDefinition
    @State private var parameterCache: [String: ArcaneCommandParameter]
    @State private var syncError: String?
    @State private var error: String?
    init(library: ArcaneCommandLibrary, context: ArcaneCommandContext, initial: ArcaneCommandDefinition) {
        self.library = library; self.context = context
        _draft = State(initialValue: initial)
        _parameterCache = State(initialValue: Dictionary(uniqueKeysWithValues: initial.parameters.map { ($0.key, $0) }))
    }
    var body: some View {
        Form {
            Section {
                field("操作名称", text: $draft.name, hint: "例如：配置检查")
                VStack(alignment: .leading, spacing: 6) {
                    Text("命令模板").font(.subheadline).foregroundStyle(.secondary)
                    TextEditor(text: $draft.template).font(.system(size: 13, design: .monospaced)).frame(minHeight: 90)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("命令模板")
                }
                Toggle("执行前确认", isOn: $draft.confirmation)
            } footer: { Text("用 {{参数标识}} 引用参数；占位符须作为独立参数，不能放在引号内。参数列表随模板自动更新。") }
            if let syncError { Section { Text(syncError).foregroundStyle(.orange) } }
            ForEach($draft.parameters) { $parameter in
                Section {
                    LabeledContent("模板参数", value: "{{\(parameter.key)}}").font(.subheadline)
                    field("参数名称", text: $parameter.name)
                    Picker("参数类型", selection: Binding(get: { parameter.kind }, set: { kind in
                        parameter.kind = kind
                        if kind == .password { parameter.defaultValue = "" }
                        if kind == .toggle { parameter.defaultValue = "false" }
                    })) { ForEach(ArcaneCommandParameterKind.allCases) { Text($0.title).tag($0) } }
                    if parameter.kind == .choice {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("选项（每行一个）").font(.subheadline).foregroundStyle(.secondary)
                            TextEditor(text: Binding(get: { parameter.choices.joined(separator: "\n") }, set: { parameter.choices = $0.components(separatedBy: .newlines).filter { !$0.isEmpty } }))
                                .frame(minHeight: 70).autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityLabel("选项")
                        }
                    }
                    if parameter.kind == .toggle {
                        Toggle("默认开启", isOn: Binding(get: { parameter.defaultValue == "true" }, set: { parameter.defaultValue = $0 ? "true" : "false" }))
                    } else if parameter.kind != .password { field("默认值", text: $parameter.defaultValue) }
                    if parameter.kind != .toggle { Toggle("必填", isOn: $parameter.required) }
                } header: { Text(parameter.name.isEmpty ? parameter.key : parameter.name) } footer: {
                    if parameter.kind == .password { Text("执行时填写，密码值不会保存。") }
                }
            }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(.orange) } }
        }
        .navigationTitle(library.definitions(context).contains(where: { $0.id == draft.id }) ? "编辑操作" : "添加操作").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    do { sync(); try library.save(draft, context: context); dismiss() } catch { self.error = error.localizedDescription }
                }.disabled(syncError != nil || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.template.isEmpty)
            }
        }
        .onChange(of: draft.template) { _, _ in sync() }
        .onAppear { sync() }
    }
    private func sync() {
        for parameter in draft.parameters { parameterCache[parameter.key] = parameter }
        do {
            let keys = try ArcaneCommandDefinition.keys(in: draft.template)
            draft.parameters = keys.map { parameterCache[$0] ?? ArcaneCommandDefinition.inferred($0, template: draft.template) }
            syncError = nil
        } catch { syncError = error.localizedDescription }
    }
    private func field(_ name: String, text: Binding<String>, hint: String = "") -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.subheadline).foregroundStyle(.secondary)
            TextField(hint, text: text).autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityLabel(name)
        }
    }
}

private struct ArcaneCommandRunView: View {
    @ObservedObject var store: ArcaneStore
    @ObservedObject var library: ArcaneCommandLibrary
    let environment: ArcaneEnvironment
    let details: ArcaneContainerDetails
    let context: ArcaneCommandContext
    let definition: ArcaneCommandDefinition
    @State private var values: [String: String] = [:]
    @State private var confirming = false
    @State private var resultID: UUID?
    @State private var error: String?
    @State private var acknowledged = false
    private var result: ArcaneCommandResult? { resultID.flatMap { library.result($0, context: context) } }
    private var blocked: Bool { store.operationRunning || store.fileSaveRunning || store.pending != nil || store.terminalSessionID != nil || (result?.uncertain == true && !acknowledged) }
    var body: some View {
        List {
            Section {
                LabeledContent("容器", value: details.displayName)
                LabeledContent("主机", value: environment.displayName)
            }.font(.subheadline)
            if !definition.parameters.isEmpty {
                Section("参数") { ForEach(definition.parameters) { parameter in parameterField(parameter).disabled(result?.running == true).arcaneRowSeparators() } }
            }
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("将执行的命令").font(.subheadline).foregroundStyle(.secondary)
                    Text((try? definition.resolve(values, preview: true)) ?? definition.template)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }.arcaneRowSeparators()
                Button {
                    do { _ = try definition.resolve(values); if definition.confirmation { confirming = true } else { run() } }
                    catch { self.error = error.localizedDescription }
                } label: {
                    HStack(spacing: 8) {
                        if result?.running == true { ProgressView() }
                        else { Image(systemName: "play.fill") }
                        Text(result?.running == true ? "执行中…" : "执行命令")
                    }.frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.borderedProminent).tint(.primary).disabled(blocked).arcaneRowSeparators()
                if let result, result.running {
                    Text(result.phase).font(.footnote).foregroundStyle(.secondary).arcaneRowSeparators()
                }
            }
            if let error { Section { Text(error).foregroundStyle(.orange).font(.footnote).arcaneRowSeparators() } }
            if let result {
                ArcaneCommandResultSections(library: library, result: result)
                if result.uncertain && !acknowledged {
                    Section { Button("已核对结果，允许重新执行") { acknowledged = true }.arcaneRowSeparators() }
                }
            }
        }
        .navigationTitle(definition.name).navigationBarTitleDisplayMode(.inline).privacySensitive()
        .alert("\(definition.name)？", isPresented: $confirming) {
            Button(definition.name) { run() }; Button("取消", role: .cancel) { }
        } message: { Text("主机：\(environment.displayName)\n容器：\(details.displayName)\n将在当前容器中执行此操作。") }
    }
    @ViewBuilder private func parameterField(_ parameter: ArcaneCommandParameter) -> some View {
        let binding = Binding(get: { values[parameter.key] ?? parameter.defaultValue }, set: { values[parameter.key] = $0 })
        if parameter.kind == .toggle {
            Toggle(parameter.name, isOn: Binding(get: { binding.wrappedValue == "true" }, set: { binding.wrappedValue = $0 ? "true" : "false" }))
        } else if parameter.kind == .choice {
            Picker(parameter.name, selection: binding) { ForEach(parameter.choices, id: \.self) { Text($0).tag($0) } }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(parameter.name + (parameter.required ? " · 必填" : "")).font(.subheadline).foregroundStyle(.secondary)
                if parameter.kind == .password { SecureField("", text: binding).accessibilityLabel(parameter.name) }
                else { TextField("", text: binding).accessibilityLabel(parameter.name).keyboardType(parameter.kind == .number ? .numbersAndPunctuation : .default) }
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
        }
    }
    private func run() {
        do { resultID = try library.run(definition, values: values, details: details, context: context, store: store); error = nil; acknowledged = false }
        catch { self.error = error.localizedDescription }
    }
}

private struct ArcaneCommandHistoryView: View {
    @ObservedObject var library: ArcaneCommandLibrary
    let context: ArcaneCommandContext
    let resultID: UUID
    var body: some View {
        List {
            if let result = library.result(resultID, context: context) { ArcaneCommandResultSections(library: library, result: result) }
            else { Text("此执行记录已清除。") }
        }.navigationTitle("执行结果").navigationBarTitleDisplayMode(.inline).privacySensitive()
    }
}

private struct ArcaneCommandResultSections: View {
    @ObservedObject var library: ArcaneCommandLibrary
    let result: ArcaneCommandResult
    var body: some View {
        Section {
            if result.running {
                HStack(spacing: 10) { ProgressView(); Text(result.phase).font(.subheadline) }.arcaneRowSeparators()
            }
            LabeledContent(result.name, value: result.status).foregroundStyle(result.uncertain ? Color.orange : result.running ? .secondary : result.exitCode == 0 ? .green : .red).arcaneRowSeparators()
            LabeledContent("容器", value: result.container).arcaneRowSeparators()
            LabeledContent("开始时间") { Text(result.began, style: .time) }.arcaneRowSeparators()
            if let code = result.exitCode { LabeledContent("退出码", value: String(code)).arcaneRowSeparators() }
            if let end = result.finished { LabeledContent("耗时", value: String(format: "%.1f 秒", end.timeIntervalSince(result.began))).arcaneRowSeparators() }
            if let error = result.error { Text(error).font(.footnote).foregroundStyle(.orange).arcaneRowSeparators() }
            Text(library.visibleOutput(result).isEmpty ? result.running ? "等待输出…" : "命令没有文本输出。" : library.visibleOutput(result))
                .font(.system(size: 12, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).arcaneRowSeparators()
            if result.truncated { Text("仅显示前 256 KB 输出。").font(.caption).foregroundStyle(.secondary).arcaneRowSeparators() }
            Button("复制输出") { UIPasteboard.general.string = library.visibleOutput(result) }.disabled(result.running).arcaneRowSeparators()
        } header: { Text("执行结果") }
    }
}
