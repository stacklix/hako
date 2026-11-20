import SwiftUI

struct WorkshopCommandLibraryView: View {
    @ObservedObject var client: WorkshopCommands
    @ObservedObject var conversation: WorkshopConversation
    @Environment(\.dismiss) private var dismiss
    @State private var editor: WorkshopSavedCommand?
    @State private var promptEditor: WorkshopQuickPrompt?
    @State private var confirmsCompact = false

    var body: some View {
        SettingsSheet(title: "快捷命令") {
            List {
                Section {
                    LabeledContent("执行电脑", value: client.agent.name)
                    LabeledContent("项目", value: client.application.name)
                }
                Section {
                    Button {
                        confirmsCompact = true
                    } label: { Label("压缩上下文", systemImage: "arrow.down.right.and.arrow.up.left") }
                        .disabled(!conversation.canCompact)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                } header: { Text("会话操作") } footer: {
                    Text("会话空闲时可手动压缩上下文，保留会话历史；执行进度显示在会话中。")
                }
                Section {
                    ForEach(client.prompts) { prompt in
                        HStack {
                            Button {
                                Task { await conversation.sendPrompt(prompt.text) }
                                dismiss()
                            } label: {
                                Label(prompt.name, systemImage: "paperplane")
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .disabled(!conversation.canSendPrompt)
                            Button { promptEditor = prompt } label: { Image(systemName: "pencil").frame(minWidth: 44, minHeight: 44) }
                                .accessibilityLabel("编辑提示词：" + prompt.name)
                        }
                        .buttonStyle(.borderless)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    }
                    Button { promptEditor = WorkshopQuickPrompt() } label: { Label("添加快捷提示词", systemImage: "plus") }
                } header: { Text("快捷提示词") } footer: {
                    Text("保存在这台手机的当前项目中。点击名称直接发送到当前会话；保留输入框中的草稿。")
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
                if let id = client.taskID, client.task?.active == true || client.pendingCommand != nil {
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
        .sheet(item: $promptEditor) { prompt in WorkshopQuickPromptEditor(client: client, initial: prompt) }
        .alert("压缩上下文", isPresented: $confirmsCompact) {
            Button("取消", role: .cancel) { }
            Button("开始压缩") { Task { await conversation.compactContext() }; dismiss() }
        } message: { Text("将压缩当前会话的模型上下文，历史消息仍会保留。") }
        .task { await client.prepare() }
    }
}

private struct WorkshopQuickPromptEditor: View {
    @ObservedObject var client: WorkshopCommands
    let initial: WorkshopQuickPrompt
    @State private var draft: WorkshopQuickPrompt
    @State private var error: String?
    @State private var confirmsDelete = false
    @Environment(\.dismiss) private var dismiss
    init(client: WorkshopCommands, initial: WorkshopQuickPrompt) {
        self.client = client; self.initial = initial; _draft = State(initialValue: initial)
    }
    var body: some View {
        SettingsSheet(title: "快捷提示词", hasChanges: draft != initial, saveEnabled: draft.valid, onSave: {
            do { try client.savePrompt(draft); dismiss() } catch { self.error = error.localizedDescription }
        }) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("名称").font(.subheadline).foregroundStyle(.secondary)
                        TextField("例如检查代码", text: $draft.name).accessibilityLabel("提示词名称")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("提示词内容").font(.subheadline).foregroundStyle(.secondary)
                        TextEditor(text: $draft.text).frame(minHeight: 160).accessibilityLabel("提示词内容")
                    }
                }
                if client.prompts.contains(where: { $0.id == initial.id }) {
                    Section { HakoDeleteButton(title: "删除提示词") { confirmsDelete = true }.listRowBackground(Color.clear) }
                }
                if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
            }
        }
        .hakoDeleteConfirmation(Text("删除这条快捷提示词？"), isPresented: $confirmsDelete, confirm: {
            do { try client.deletePrompt(initial.id); dismiss() } catch { self.error = error.localizedDescription }
        })
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
                    LabeledContent("允许后台进程继续运行", value: command.allowBackgroundProcesses ? "开启" : "关闭")
                    HakoLabeledValue(label: "工作目录", value: client.application.path, monospaced: true)
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
                Section {
                    Toggle("允许后台进程继续运行", isOn: $draft.allowBackgroundProcesses)
                } footer: {
                    Text("开启后，命令退出、停止或超时只结束提交命令，已启动的后台进程继续运行。后台任务需通过其自身工具管理，例如用 xkode 取消构建。")
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
                if let id = client.taskID { HakoLabeledValue(label: "任务 ID", value: id, monospaced: true) }
                if let code = client.task?.exitCode { LabeledContent("退出码", value: String(code)) }
            }
            if let task = client.task {
                Section("提交时的命令") {
                    Text(task.command).font(.caption.monospaced()).textSelection(.enabled)
                    HakoLabeledValue(label: "工作目录", value: task.directory, monospaced: true)
                    LabeledContent("允许后台进程继续运行", value: task.allowBackgroundProcesses ? "开启" : "关闭")
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
        } message: {
            Text(client.task?.allowBackgroundProcesses == true
                 ? "当前命令会停止，已启动的后台进程继续运行，需要通过其自身工具停止。"
                 : "正在执行的命令及其子进程会停止。")
        }
    }
}
