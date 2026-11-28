import SwiftUI

struct AssistantHistorySheet: View {
    let name: String
    let entries: () async throws -> [AssistantConversationHistory.Entry]
    let messages: (UUID) async throws -> [AssistantHistoryMessage]
    let resume: (UUID) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var history: [AssistantConversationHistory.Entry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var resuming = false

    var body: some View {
        SettingsSheet(title: "历史会话", isBusy: resuming) {
            List {
                Section {
                    if loading { ProgressView("正在读取会话…") }
                    else if let error { Text(error).foregroundStyle(.red) }
                    else if history.isEmpty { Text("暂无历史会话").foregroundStyle(.secondary) }
                    ForEach(history) { entry in
                        NavigationLink(value: entry) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.title).lineLimit(2)
                                if !entry.preview.isEmpty { Text(entry.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                                Text(entry.updatedAt, format: .dateTime.year().month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                    }
                } footer: {
                    Text("新建会话后，原对话、图片和操作结果仍保留在本机。")
                }
            }
            .navigationDestination(for: AssistantConversationHistory.Entry.self) { entry in
                AssistantHistoryDetail(name: name, entry: entry, load: { try await messages(entry.id) }, resume: {
                    resuming = true
                    defer { resuming = false }
                    if await resume(entry.id) { dismiss(); return true }
                    return false
                })
            }
        }
        .task {
            do { history = try await entries() }
            catch { self.error = "无法读取历史会话：" + error.localizedDescription }
            loading = false
        }
    }
}

private struct AssistantHistoryDetail: View {
    let name: String
    let entry: AssistantConversationHistory.Entry
    let load: () async throws -> [AssistantHistoryMessage]
    let resume: () async -> Bool
    @State private var messages: [AssistantHistoryMessage] = []
    @State private var loading = true
    @State private var switching = false
    @State private var error: String?
    @State private var preview: AssistantImageSelection?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if loading { ProgressView("正在读取会话…") }
                    ForEach(messages) { message in
                        if message.isUser {
                            AssistantUserMessage(text: message.text, images: message.images) { images, index in
                                preview = .init(images: images, index: index)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 7) {
                                Label(name, systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                                if let html = message.html {
                                    AssistantReplyView(html: html, confirmation: message.confirmationSymbols.map { .init(itemSymbols: $0) })
                                }
                                else { Text(verbatim: message.text).textSelection(.enabled) }
                                if let outcome = message.outcome { Text(verbatim: outcome).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
                            }
                        }
                    }
                    if let error { Text(error).foregroundStyle(.red) }
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(spacing: 10) {
                Text("历史结果仅供查看，打开会话不会重复执行。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button(switching ? "正在打开…" : "继续对话") {
                    switching = true
                    Task {
                        if !(await resume()) { error = "无法打开会话，请返回后重试。" }
                        switching = false
                    }
                }.buttonStyle(HakoActionButtonStyle()).disabled(loading || switching || error != nil)
            }.padding(16)
        }
        .background(HakoStyle.background)
        .navigationTitle(entry.title).navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(switching)
        .interactiveDismissDisabled(switching)
        .sheet(item: $preview) { AssistantPhotoPreview(images: $0.images, selection: $0.index) }
        .task {
            do { messages = try await load() }
            catch { self.error = "无法读取会话：" + error.localizedDescription }
            loading = false
        }
    }
}
