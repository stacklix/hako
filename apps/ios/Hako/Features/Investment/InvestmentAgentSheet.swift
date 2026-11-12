import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct InvestmentAgentSheet: View {
    private struct Attachment: Identifiable {
        let id = UUID()
        let item: PhotosPickerItem
        let data: Data
    }

    private struct ImagePreview: Identifiable {
        let id = UUID()
        let images: [Data]
        let index: Int
    }

    @ObservedObject private var store: InvestmentStore
    @ObservedObject private var agent: InvestmentAgentSession
    @State private var message = ""
    @State private var attachments: [Attachment] = []
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var photoSelectionLimit = InvestmentAgentConversation.maximumImageCount
    @State private var imagePreview: ImagePreview?
    @State private var showsPhotos = false
    @State private var loadingPhoto = false
    @State private var showsModelSettings = false
    @State private var editing: InvestmentAgentProposal?
    @State private var exportDocument: InvestmentExportDocument?
    @State private var exporting = false
    @State private var showsExporter = false
    @State private var confirmsNewConversation = false
    @FocusState private var composing: Bool

    init(store: InvestmentStore, agent: InvestmentAgentSession) {
        self.store = store
        self.agent = agent
    }

    var body: some View {
        SettingsSheet(title: "记账助手", hasChanges: hasUnsentMessage,
                      isBusy: agent.committing || exporting) {
            VStack(spacing: 0) {
                thread
                composer
            }
            .background(HakoStyle.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { confirmsNewConversation = true } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("新建会话")
                    .disabled(!canStartNewConversation)
                }
            }
        }
        .onAppear { agent.checkConfiguration() }
        .onChange(of: store.hasLoaded, initial: true) { _, loaded in
            if loaded { agent.restoreConversation() }
        }
        .alert("新建会话", isPresented: $confirmsNewConversation) {
            Button("取消", role: .cancel) {}
            Button("新建会话", role: .destructive, action: startNewConversation)
        } message: {
            Text("开始新会话会清空当前对话，并放弃未发送的消息和待确认的记账草稿。")
        }
        .photosPicker(isPresented: $showsPhotos, selection: $selectedPhotos,
                      maxSelectionCount: photoSelectionLimit,
                      selectionBehavior: .ordered, matching: .images)
        .task(id: selectedPhotos) { await loadPhotos(selectedPhotos) }
        .sheet(item: $imagePreview) { preview in
            InvestmentAgentPhotoPreview(images: preview.images, selection: preview.index)
        }
        .sheet(isPresented: $showsModelSettings, onDismiss: agent.checkConfiguration) { LanguageModelSettingsSheet() }
        .sheet(item: $editing) { proposal in
            InvestmentAgentEditSheet(proposal: proposal, book: store.book) { actions in try await agent.revise(actions) }
        }
        .fileExporter(isPresented: $showsExporter, document: exportDocument, contentType: .zip,
                      defaultFilename: "投资记账-" + InvestmentBook.snapshotDateFormatter().string(from: InvestmentBook.day())) { result in
            exportDocument = nil
            if case .failure(let error) = result { agent.error = error.localizedDescription }
        }
    }

    private var thread: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if agent.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            assistantLabel
                            Text("可以告诉我一笔交易、发来成交截图，或查询账本。写入前会请你核对。")
                                .font(.subheadline)
                            if !agent.configured {
                                Button("打开大模型配置") { showsModelSettings = true }
                                    .buttonStyle(HakoActionButtonStyle(primary: false))
                            }
                        }
                    }
                    ForEach(agent.messages) { item in messageRow(item).id(item.id) }
                    if let proposal = agent.proposal {
                        InvestmentAgentPreview(proposal: proposal, committing: agent.committing, busy: agent.working, stale: agent.stale,
                            edit: { editing = proposal }, discard: agent.discard,
                            confirm: { Task { await agent.commit(proposal.id) } }, regenerate: { Task { await regenerate(proposal) } })
                            .id(proposal.id)
                    }
                    if agent.canExport {
                        Button(exporting ? "正在准备账本…" : "导出账本") { Task { await exportLedger() } }
                            .buttonStyle(HakoActionButtonStyle(primary: false))
                            .disabled(exporting || agent.committing || agent.working)
                    }
                    if let error = agent.error { Text(error).font(.footnote).foregroundStyle(.red) }
                    if let issue = agent.storageIssue { Text(issue).font(.footnote).foregroundStyle(.red) }
                    if agent.working {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在处理…").font(.footnote).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(15)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: agent.messages.last?.id, initial: true) { _, _ in
                if let proposal = agent.proposal {
                    scroll.scrollTo(proposal.id, anchor: .top)
                } else if let reply = agent.messages.last, reply.html != nil {
                    scroll.scrollTo(reply.id, anchor: .top)
                } else if !agent.messages.isEmpty {
                    scroll.scrollTo("end", anchor: .bottom)
                }
            }
            .onChange(of: agent.working) { _, working in
                if working && agent.proposal == nil { scroll.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: agent.proposal?.id) { _, id in
                if let id { scroll.scrollTo(id, anchor: .top) }
            }
        }
    }

    private var assistantLabel: some View {
        Label("记账助手", systemImage: "sparkles")
            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func messageRow(_ item: InvestmentAgentSession.Message) -> some View {
        if item.isUser {
            HStack {
                Spacer(minLength: 28)
                VStack(alignment: .leading, spacing: 7) {
                    if !item.images.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76, maximum: 100))], alignment: .leading, spacing: 8) {
                            ForEach(item.images.indices, id: \.self) { index in
                                Button {
                                    imagePreview = ImagePreview(images: item.images, index: index)
                                } label: { photo(item.images[index], size: 76) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("预览第 \(index + 1) 张图片，共 \(item.images.count) 张")
                            }
                        }
                        .frame(maxWidth: CGFloat(min(item.images.count, 3) * 84 - 8), alignment: .leading)
                    }
                    if !item.text.isEmpty { Text(verbatim: item.text).textSelection(.enabled) }
                }
                .padding(10)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                assistantLabel
                if let html = item.html {
                    InvestmentAgentReplyView(html: html)
                } else {
                    Text(verbatim: item.text).textSelection(.enabled)
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    shortcut("文字记账") { message = "帮我记一笔买入："; composing = true }
                    shortcut("成交截图") {
                        openPhotos()
                    }
                    .disabled(!canAddPhotos)
                    shortcut("查交易记录") { message = "查一下最近的交易记录。"; composing = true }
                }
            }
            .scrollIndicators(.hidden)
            if !attachments.isEmpty { photoAttachments }
            if loadingPhoto { ProgressView("正在读取图片…").font(.footnote) }
            if agent.proposal != nil {
                Text("请先确认或放弃上方草稿，再发送下一条。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 2) {
                Button(action: openPhotos) {
                    Image(systemName: "plus").font(.system(size: 22, weight: .bold))
                        .foregroundStyle(HakoStyle.text).frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("添加图片")
                .accessibilityValue("已添加 \(attachments.count) 张，最多 \(InvestmentAgentConversation.maximumImageCount) 张")
                .disabled(!canAddPhotos)
                TextField("描述这笔交易…", text: $message, axis: .vertical)
                    .font(.body).lineLimit(1...5)
                    .padding(.vertical, 11).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("聊天消息")
                    .focused($composing)
                if agent.working && agent.proposal == nil {
                    Button(action: agent.stop) {
                        Image(systemName: "square.fill").font(.system(size: 13, weight: .semibold))
                    }
                    .buttonStyle(InvestmentAgentSendButtonStyle())
                    .accessibilityLabel("停止生成")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold))
                    }
                    .buttonStyle(InvestmentAgentSendButtonStyle())
                    .disabled(!canSend)
                    .accessibilityLabel("发送消息")
                }
            }
            .padding(4)
            .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 27))
            .overlay { RoundedRectangle(cornerRadius: 27).strokeBorder(HakoStyle.line, lineWidth: 1).allowsHitTesting(false) }
        }
        .padding(.horizontal, 16).padding(.vertical, 8).background(HakoStyle.background)
        .disabled(agent.committing)
    }

    private var photoAttachments: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
                    Button {
                        imagePreview = ImagePreview(images: attachments.map(\.data), index: index)
                    } label: { photo(attachment.data, size: 76) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("预览第 \(index + 1) 张待发送图片")
                    .overlay(alignment: .topTrailing) {
                        Button { attachments.removeAll { $0.id == attachment.id } } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.65)).frame(width: 32, height: 32)
                        }
                        .accessibilityLabel("移除第 \(index + 1) 张图片")
                        .disabled(loadingPhoto)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
    }

    private var canAddPhotos: Bool {
        !loadingPhoto && !agent.committing && attachments.count < InvestmentAgentConversation.maximumImageCount
    }

    private var canSend: Bool {
        !agent.working && agent.proposal == nil && !loadingPhoto &&
            (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private var hasUnsentMessage: Bool { !message.isEmpty || !attachments.isEmpty || loadingPhoto }

    private var canStartNewConversation: Bool {
        !agent.working && !agent.committing && !exporting &&
            (!agent.messages.isEmpty || agent.proposal != nil || agent.error != nil || agent.storageIssue != nil || hasUnsentMessage)
    }

    private func startNewConversation() {
        guard canStartNewConversation, agent.startNewConversation() else { return }
        message = ""
        attachments = []
        selectedPhotos = []
        composing = false
    }

    private func shortcut(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.footnote)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(HakoStyle.card, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func photo(_ data: Data, size: CGFloat) -> some View {
        Group {
            if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo") }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("已附加的图片")
    }

    private func send() {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 12_000 else { agent.error = "消息太长，请分段发送。"; return }
        if agent.send(text, images: attachments.map(\.data)) {
            message = ""
            attachments = []
            selectedPhotos = []
            composing = false
        }
    }

    private func openPhotos() {
        guard canAddPhotos else { return }
        photoSelectionLimit = InvestmentAgentConversation.maximumImageCount - attachments.count
        selectedPhotos = []
        showsPhotos = true
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { loadingPhoto = false; return }
        loadingPhoto = true
        defer { if selectedPhotos == items { loadingPhoto = false } }
        var failures = 0
        for item in items {
            do {
                try Task.checkCancellation()
                guard selectedPhotos == items else { return }
                guard attachments.count < InvestmentAgentConversation.maximumImageCount else { break }
                if attachments.contains(where: { $0.item == item }) { continue }
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw LanguageModelError.invalid("无法读取这张图片。")
                }
                let encoded = await Task.detached(priority: .userInitiated) { Self.modelImage(data) }.value
                try Task.checkCancellation()
                guard selectedPhotos == items else { return }
                guard let encoded else { throw LanguageModelError.invalid("无法处理这张图片，请换一张。") }
                attachments.append(Attachment(item: item, data: encoded))
            } catch is CancellationError { return }
            catch {
                guard selectedPhotos == items, !Task.isCancelled else { return }
                failures += 1
            }
        }
        if failures > 0 { agent.error = "有 \(failures) 张图片未能读取，请重新选择。其余图片已保留。" }
    }

    nonisolated private static func modelImage(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        for quality in [0.86, 0.68, 0.5] {
            let encoded = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            if CGImageDestinationFinalize(destination), encoded.length <= 2_000_000 { return encoded as Data }
        }
        return nil
    }

    private func regenerate(_ proposal: InvestmentAgentProposal) async {
        do { try await agent.revise(proposal.actions) }
        catch is CancellationError { return }
        catch { agent.error = error.localizedDescription }
    }

    private func exportLedger() async {
        guard !exporting else { return }
        exporting = true
        defer { exporting = false }
        do {
            exportDocument = InvestmentExportDocument(data: try await agent.export())
            showsExporter = true
        } catch is CancellationError { return }
        catch { agent.error = error.localizedDescription }
    }
}

private struct InvestmentAgentSendButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(width: 36, height: 36)
            .foregroundStyle(enabled ? HakoStyle.background : HakoStyle.muted)
            .background(enabled ? HakoStyle.text : HakoStyle.line, in: Circle())
            .padding(4).contentShape(Circle()).opacity(configuration.isPressed ? 0.6 : 1)
    }
}

private struct InvestmentAgentPhotoPreview: View {
    let images: [Data]
    @State private var selection: Int

    init(images: [Data], selection: Int) {
        self.images = images
        _selection = State(initialValue: selection)
    }

    var body: some View {
        SettingsSheet(title: "图片 \(selection + 1)/\(images.count)") {
            TabView(selection: $selection) {
                ForEach(images.indices, id: \.self) { index in
                    Group {
                        if let image = UIImage(data: images[index]) {
                            InvestmentAgentImageZoom(image: image)
                                .accessibilityLabel("第 \(index + 1) 张图片，可双指缩放")
                        } else {
                            ContentUnavailableView("无法预览图片", systemImage: "photo")
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .background(HakoStyle.background)
        }
    }
}

private struct InvestmentAgentImageZoom: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = InvestmentAgentZoomScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.delegate = context.coordinator
        let picture = context.coordinator.picture
        scroll.picture = picture
        picture.contentMode = .scaleAspectFit
        picture.image = image
        scroll.addSubview(picture)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.picture.image = image
        scroll.setNeedsLayout()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let picture = UIImageView()

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            picture.center = CGPoint(x: max(scrollView.bounds.width, scrollView.contentSize.width) / 2,
                                     y: max(scrollView.bounds.height, scrollView.contentSize.height) / 2)
        }
    }
}

private final class InvestmentAgentZoomScrollView: UIScrollView {
    weak var picture: UIImageView?

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1, picture?.frame != bounds {
            picture?.frame = bounds
            contentSize = bounds.size
        }
    }
}

private struct InvestmentAgentPreview: View {
    let proposal: InvestmentAgentProposal
    let committing: Bool
    let busy: Bool
    let stale: Bool
    let edit: () -> Void
    let discard: () -> Void
    let confirm: () -> Void
    let regenerate: () -> Void
    @State private var page = 0
    private let pageSize = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("写入预览 · \(proposal.changes.count) 项变更").font(.caption).foregroundStyle(.secondary)
                    Text(proposal.changes.first?.title ?? "账本变更").font(.headline)
                }
                Spacer()
                Text(committing ? "正在写入" : stale ? "预览已过期" : "待确认")
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .foregroundStyle(.primary)
                    .background(.orange.opacity(0.18), in: Capsule())
            }
            ForEach(proposal.changes.dropFirst(page * pageSize).prefix(pageSize)) { change in
                changeRow(change)
            }
            if proposal.changes.count > pageSize {
                HStack {
                    Button("上一页") { page -= 1 }.disabled(page == 0)
                    Spacer()
                    Text("第 \(page + 1) 页").font(.caption)
                    Spacer()
                    Button("下一页") { page += 1 }.disabled((page + 1) * pageSize >= proposal.changes.count)
                }
                .font(.footnote)
            }
            if proposal.snapshotsOnly {
                Text("使用已保存的行情和汇率重算，缺少输入的日期会标记为不完整。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Divider()
            if proposal.editable {
                Button("修改", action: edit).font(.subheadline)
            }
            HStack(spacing: 12) {
                Button("放弃", action: discard)
                    .buttonStyle(HakoActionButtonStyle(primary: false))
                if stale {
                    Button("重新预览", action: regenerate).buttonStyle(HakoActionButtonStyle())
                } else {
                    Button("确认写入", role: proposal.destructive ? .destructive : nil, action: confirm)
                        .buttonStyle(HakoActionButtonStyle(destructive: proposal.destructive))
                }
            }
        }
        .disabled(committing || busy)
        .padding(12)
        .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func changeRow(_ change: InvestmentAgentProposal.Change) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(change.operation.rawValue) · \(change.title)").font(.subheadline.weight(.medium))
            let columns = [GridItem(.adaptive(minimum: 125), alignment: .topLeading)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
                ForEach(change.fields) { field in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.label).font(.caption).foregroundStyle(.secondary)
                        if change.operation == .edit, field.before != field.after {
                            Text(field.before ?? "—").font(.footnote).strikethrough().foregroundStyle(.secondary)
                            Text(field.after ?? "—").font(.footnote).monospacedDigit()
                        } else {
                            Text(field.after ?? field.before ?? "—").font(.footnote).monospacedDigit()
                        }
                    }
                }
            }
            Divider()
        }
    }
}

private struct InvestmentAgentEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let proposal: InvestmentAgentProposal
    let book: InvestmentBook
    let save: ([InvestmentAgentAction]) async throws -> Void
    @State private var actions: [InvestmentAgentAction]
    @State private var saving = false
    @State private var error: String?

    init(proposal: InvestmentAgentProposal, book: InvestmentBook, save: @escaping ([InvestmentAgentAction]) async throws -> Void) {
        self.proposal = proposal
        self.book = book
        self.save = save
        _actions = State(initialValue: proposal.actions)
    }

    var body: some View {
        let changed = actions.map(\.values) != proposal.actions.map(\.values)
        SettingsSheet(title: "修改草稿", hasChanges: changed, isBusy: saving, saveEnabled: changed,
                      onSave: { Task { await updatePreview() } }, saveAccessibilityLabel: "更新预览") {
            Form {
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
                ForEach(actions.indices, id: \.self) { index in
                    let action = actions[index]
                    Section(action.kind.title) {
                        ForEach(action.fields, id: \.key) { field in
                            let value = Binding(get: { actions[index].values[field.key] ?? "" }, set: { actions[index].values[field.key] = $0 })
                            fieldEditor(field, value: value)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func fieldEditor(_ field: InvestmentAgentAction.Field, value: Binding<String>) -> some View {
        let formatter = InvestmentBook.snapshotDateFormatter()
        let options = choices(for: field)
        if (field.key == "date" || field.key == "maturity_date"), formatter.date(from: value.wrappedValue) != nil {
            let date = Binding(get: { formatter.date(from: value.wrappedValue) ?? InvestmentBook.day() },
                               set: { value.wrappedValue = formatter.string(from: $0) })
            DatePicker(field.key == "date" ? "记账日期" : "到期日", selection: date, displayedComponents: .date)
                .environment(\.calendar, InvestmentBook.calendar)
                .environment(\.timeZone, InvestmentBook.calendar.timeZone)
        } else if !options.isEmpty {
            Picker(field.label, selection: value) {
                Text(field.required ? "请选择" : "未指定").tag("")
                if !value.wrappedValue.isEmpty, !options.contains(where: { $0.id == value.wrappedValue }) {
                    Text(value.wrappedValue).tag(value.wrappedValue)
                }
                ForEach(options) { Text($0.title).tag($0.id) }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(field.label).font(.subheadline).foregroundStyle(.secondary)
                TextField(field.required ? "必填" : "选填", text: value)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel(Text(field.label))
            }
        }
    }

    private struct Choice: Identifiable {
        let id: String
        let title: String
    }

    private func choices(for field: InvestmentAgentAction.Field) -> [Choice] {
        switch field.key {
        case "account_id", "target_id":
            return book.accounts.map { .init(id: $0.id.uuidString, title: "\($0.name) · \($0.currency.rawValue)") }
        case "asset_id", "collateral_id":
            return book.assets.values.sorted { $0.code < $1.code }.map { .init(id: $0.id.uuidString, title: "\($0.name) · \($0.code)") }
        case "balance_account_id":
            return (book.balanceSheet?.accounts ?? []).map { .init(id: $0.id.uuidString, title: $0.name) }
        default:
            return field.choices.map { value in
                let title: String
                switch field.key {
                case "event_type": title = InvestmentAgentAction.eventKinds[value]?.rawValue ?? value
                case "account_type": title = InvestmentAgentAction.accountTypes[value]?.rawValue ?? value
                case "asset_type": title = InvestmentAgentAction.assetKinds[value]?.title ?? value
                case "category": title = InvestmentAgentAction.balanceCategories[value]?.rawValue ?? value
                case "basis": title = InvestmentAgentAction.bases[value]?.rawValue ?? value
                case "side": title = InvestmentAgentAction.sides[value]?.rawValue ?? value
                case "funding_target": title = InvestmentAgentAction.fundingTargets[value]?.rawValue ?? value
                default: title = value == "true" ? "是" : value == "false" ? "否" : value
                }
                return Choice(id: value, title: title)
            }
        }
    }

    private func updatePreview() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do { try await save(actions); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
