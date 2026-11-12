import SwiftUI

struct WorkshopCommandLibraryView: View {
    @ObservedObject var client: WorkshopCommands
    @State private var editor: WorkshopSavedCommand?

    var body: some View {
        SettingsSheet(title: "快捷命令") {
            List {
                Section {
                    LabeledContent("执行电脑", value: client.agent.name)
                    LabeledContent("项目", value: client.application.name)
                }
                Section {
                    if client.commands.isEmpty {
                        ContentUnavailableView("还没有快捷命令", systemImage: "terminal",
                            description: Text("点击右上角 +，添加要在电脑上执行的命令。"))
                    }
                    ForEach(client.commands) { command in
                        NavigationLink {
                            WorkshopCommandDetailView(client: client, commandID: command.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(command.name)
                                if !command.note.isEmpty { Text(command.note).font(.caption).foregroundStyle(.secondary) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    }
                } header: { Text("保存在这台手机") } footer: {
                    Text("命令直接发送到所选电脑执行，执行记录独立于 Codex 会话。")
                }
                if let id = client.taskID {
                    Section("当前任务") {
                        NavigationLink { WorkshopCommandTaskView(client: client) } label: {
                            LabeledContent(client.task?.name ?? "命令任务", value: client.task?.status ?? "正在确认")
                        }
                        .id(id)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    }
                }
                if !client.tasks.isEmpty {
                    Section("执行历史") {
                        ForEach(client.tasks) { task in
                            NavigationLink {
                                WorkshopCommandTaskView(client: client).onAppear { client.select(task) }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(task.name)
                                        Text(Date(timeIntervalSince1970: Double(task.startedAt) / 1000), format: .dateTime.month().day().hour().minute())
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(task.status).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                        }
                    }
                }
                if let error = client.error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editor = WorkshopSavedCommand() } label: { Image(systemName: "plus") }
                        .accessibilityLabel("新增快捷命令").disabled(client.busy)
                }
            }
            .refreshable { await client.prepare() }
        }
        .sheet(item: $editor) { editor in
            WorkshopCommandEditorView(client: client, initial: editor)
        }
        .task { await client.prepare() }
    }
}

private struct WorkshopCommandDetailView: View {
    @ObservedObject var client: WorkshopCommands
    let commandID: UUID
    @State private var editing = false
    @State private var showingTask = false
    private var command: WorkshopSavedCommand? { client.commands.first { $0.id == commandID } }

    var body: some View {
        Form {
            if let command {
                Section("名称") { Text(command.name) }
                Section("命令") { Text(command.command).font(.footnote.monospaced()).textSelection(.enabled) }
                if !command.note.isEmpty { Section("说明") { Text(command.note) } }
                Section {
                    LabeledContent("执行电脑", value: client.agent.name)
                    LabeledContent("执行环境", value: "PowerShell 7")
                    LabeledContent("超时", value: "\(command.timeoutSeconds) 秒")
                    ApplicationValue(label: "工作目录", value: client.application.path, monospaced: true)
                }
                Section {
                    Button {
                        Task { await client.execute(command); showingTask = client.taskID != nil }
                    } label: { Label(client.busy ? "正在提交…" : "在电脑上执行", systemImage: "play.fill") }
                        .buttonStyle(HakoActionButtonStyle()).disabled(client.busy)
                        .listRowBackground(Color.clear)
                }
                if let error = client.error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
            } else { ContentUnavailableView("命令已删除", systemImage: "terminal") }
        }
        .navigationTitle("命令详情").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { editing = true } label: { Image(systemName: "pencil") }.accessibilityLabel("编辑快捷命令")
                    .disabled(command == nil || client.busy)
            }
        }
        .sheet(isPresented: $editing) { if let command { WorkshopCommandEditorView(client: client, initial: command) } }
        .sheet(isPresented: $showingTask) { SettingsSheet(title: "命令执行") { WorkshopCommandTaskView(client: client) } }
    }
}

private struct WorkshopCommandEditorView: View {
    @ObservedObject var client: WorkshopCommands
    let initial: WorkshopSavedCommand
    @Environment(\.dismiss) private var dismiss
    @State private var draft: WorkshopSavedCommand
    @State private var error: String?
    @State private var deleting = false
    init(client: WorkshopCommands, initial: WorkshopSavedCommand) {
        self.client = client; self.initial = initial; _draft = State(initialValue: initial)
    }
    private var existing: Bool { client.commands.contains { $0.id == initial.id } }
    var body: some View {
        SettingsSheet(title: existing ? "编辑快捷命令" : "新增快捷命令", hasChanges: draft != initial,
                      saveEnabled: draft.valid, onSave: save) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("名称").font(.subheadline).foregroundStyle(.secondary)
                        TextField("命令名称", text: $draft.name).accessibilityLabel("命令名称")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("命令").font(.subheadline).foregroundStyle(.secondary)
                        TextEditor(text: $draft.command).font(.footnote.monospaced()).frame(minHeight: 130)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("命令内容")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("说明（选填）").font(.subheadline).foregroundStyle(.secondary)
                        TextField("命令用途", text: $draft.note).accessibilityLabel("命令说明")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("超时（秒）").font(.subheadline).foregroundStyle(.secondary)
                        TextField("1 至 86400", value: $draft.timeoutSeconds, format: .number.grouping(.never))
                            .keyboardType(.numberPad).accessibilityLabel("执行超时秒数")
                    }
                }
                Section { Text("保存在当前手机，执行时发送完整命令。工作目录为 \(client.application.path)。").font(.footnote).foregroundStyle(.secondary) }
                if existing {
                    Section { HakoDeleteButton(title: "删除快捷命令") { deleting = true }.listRowBackground(Color.clear) }
                }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
            }
        }
        .hakoDeleteConfirmation(Text("删除「\(initial.name)」？"), isPresented: $deleting,
            message: Text("已启动的任务继续使用提交时的命令。")) {
            do { try client.delete(initial); dismiss() } catch { self.error = error.localizedDescription }
        }
    }
    private func save() {
        do { try client.saveCommand(draft); dismiss() } catch { self.error = error.localizedDescription }
    }
}

struct WorkshopCommandTaskView: View {
    @ObservedObject var client: WorkshopCommands
    @State private var confirmingStop = false
    var body: some View {
        List {
            Section("执行任务") {
                LabeledContent("名称", value: client.task?.name ?? "正在确认任务")
                LabeledContent("电脑", value: client.agent.name)
                LabeledContent("状态", value: client.task?.status ?? "正在确认")
                if let id = client.taskID { ApplicationValue(label: "任务 ID", value: id, monospaced: true) }
                if let code = client.task?.exitCode { LabeledContent("退出码", value: String(code)) }
            }
            if let task = client.task {
                Section("提交时的命令") {
                    Text(task.command).font(.caption.monospaced()).textSelection(.enabled)
                    ApplicationValue(label: "工作目录", value: task.directory, monospaced: true)
                }
            }
            Section("执行日志") {
                Text(client.output.isEmpty ? "等待命令输出…" : client.output)
                    .font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if let error = client.task?.error { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            if let error = client.error { Section { Text(error).font(.footnote).foregroundStyle(.secondary) } }
            if let pending = client.pendingCommand {
                Section {
                    Button("重试原请求：\(pending.name)") { Task { await client.execute(pending) } }
                        .buttonStyle(HakoActionButtonStyle()).disabled(client.busy)
                        .listRowBackground(Color.clear)
                } footer: { Text("保留原请求 ID，已被电脑接收的命令不会重复执行。") }
            }
            if client.task?.active == true {
                Section {
                    Button("停止任务", role: .destructive) { confirmingStop = true }
                        .buttonStyle(HakoActionButtonStyle(destructive: true)).disabled(client.busy || client.task?.canStop == false)
                        .listRowBackground(Color.clear)
                } footer: { Text("关闭此页后，电脑上的任务继续运行。Agent 更新时执行器会保持独立连接。") }
            }
        }
        .navigationTitle("命令执行").navigationBarTitleDisplayMode(.inline)
        .alert("停止当前命令？", isPresented: $confirmingStop) {
            Button("停止任务", role: .destructive) { Task { await client.stop() } }
            Button("取消", role: .cancel) { }
        } message: { Text("正在执行的命令及其子进程会停止。") }
    }
}
