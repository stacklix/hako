import SwiftUI

struct DeviceGitRepositoriesView: View {
    let agent: ConsoleAgent
    let cacheFile: URL
    @ObservedObject private var client = DeviceMonitorClient.shared
    @State private var inventory: DeviceGitInventory?
    @State private var loading = false
    @State private var error: String?
    @State private var scanTask: Task<Void, Never>?

    private var repositories: [DeviceGitRepository] { inventory?.repositories ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(inventory?.root ?? "~/Code").font(.caption.monospaced())
                    Text(loading ? "正在扫描…" : "\(repositories.count) 个 Git 仓库").font(.caption)
                }
                .foregroundStyle(HakoStyle.muted)
                Spacer()
                Button {
                    scanTask = Task { await scan() }
                } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 44)
                }
                .disabled(loading || !client.authenticated)
            }
            if !repositories.isEmpty {
                LazyVStack(spacing: 0) {
                    ForEach(repositories) { repository in
                        if repository.id != repositories.first?.id { Divider() }
                        NavigationLink {
                            DeviceGitRepositoryView(agent: agent, repository: repository, updateSummary: updateSummary)
                        } label: {
                            repositoryRow(repository)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(HakoStyle.line, lineWidth: 1).allowsHitTesting(false) }
            } else if inventory != nil && !loading && error == nil {
                Text("此设备的 Code 目录中没有发现 Git 仓库。")
                    .font(.subheadline).foregroundStyle(HakoStyle.muted).devicePagePanel()
            }
            if inventory?.scanIncomplete == true {
                Text("部分目录无法访问或指向其他位置，已略过。")
                    .font(.caption).foregroundStyle(HakoStyle.muted)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        .task {
            guard inventory == nil, !loading else { return }
            if let data = try? Data(contentsOf: cacheFile),
               let saved = try? JSONDecoder().decode(DeviceGitInventory.self, from: data) {
                inventory = saved
            } else {
                await scan()
            }
        }
        .onDisappear { scanTask?.cancel() }
    }

    private func repositoryRow(_ repo: DeviceGitRepository) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(repo.name).font(.subheadline.weight(.semibold))
                Text(repo.remoteUrl ?? "未配置远程仓库")
                    .font(.caption).foregroundStyle(HakoStyle.muted)
                    .lineLimit(1).truncationMode(.middle)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) { branch(repo); GitStatusBadges(repository: repo) }
                    VStack(alignment: .leading, spacing: 5) { branch(repo); GitStatusBadges(repository: repo) }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(HakoStyle.muted)
                .accessibilityHidden(true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func branch(_ repo: DeviceGitRepository) -> some View {
        Text(repo.branch ?? "分离的 HEAD").font(.caption.monospaced()).foregroundStyle(HakoStyle.muted)
    }

    private func scan() async {
        guard !loading, !Task.isCancelled, client.authenticated else { return }
        let context = client.requestContext
        loading = true
        error = nil
        defer { loading = false }
        var cursor: String?
        var seen = Set<String>()
        var cursors = Set<String>()
        var discovered: [DeviceGitRepository] = []
        var root = "~/Code"
        var incomplete = false
        do {
            repeat {
                guard context == client.requestContext else { return }
                let params = cursor.map { ["cursor": $0] } ?? [:]
                let page = try await client.invokeAgent(agent, method: DeviceGitCommand.list, version: 1,
                                                        params: params, as: DeviceGitPage.self)
                try Task.checkCancellation()
                root = page.root
                discovered.append(contentsOf: page.repositories.filter { seen.insert($0.id).inserted })
                incomplete = incomplete || page.scanIncomplete
                if let next = page.nextCursor, !cursors.insert(next).inserted {
                    throw HakoError(message: "设备返回的仓库分页信息无效。")
                }
                cursor = page.nextCursor
            } while cursor != nil
            guard context == client.requestContext else { return }
            try save(DeviceGitInventory(root: root, repositories: discovered, scanIncomplete: incomplete))
        } catch is CancellationError { }
        catch { if context == client.requestContext { self.error = error.localizedDescription } }
    }

    private func updateSummary(_ updated: DeviceGitRepository) {
        guard !loading, var current = inventory,
              let index = current.repositories.firstIndex(where: { $0.id == updated.id }) else { return }
        current.repositories[index] = updated
        do { try save(current) }
        catch { self.error = error.localizedDescription }
    }

    private func save(_ next: DeviceGitInventory) throws {
        do {
            var directory = cacheFile.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var flags = URLResourceValues()
                flags.isExcludedFromBackup = true
                try directory.setResourceValues(flags)
            }
            try JSONEncoder().encode(next).write(to: cacheFile, options: .atomic)
            inventory = next
        } catch {
            throw HakoError(message: "无法保存 Git 仓库缓存。")
        }
    }
}

private struct GitStatusBadges: View {
    let repository: DeviceGitRepository

    var body: some View {
        let tags = tags
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) { badges(tags) }.fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) { badges(tags) }
        }
    }

    private var tags: [(String, Color)] {
        if repository.error != nil { return [("状态不可用", .secondary)] }
        var tags: [(String, Color)] = []
        if repository.changedCount > 0 { tags.append(("未提交 · \(repository.changedCount) 文件", .orange)) }
        if let ahead = repository.ahead, ahead > 0 { tags.append(("已提交未推送 · \(ahead)", .blue)) }
        if let behind = repository.behind, behind > 0 { tags.append(("落后远端 · \(behind)", .orange)) }
        if repository.remoteUrl == nil { tags.append(("无远程仓库", .secondary)) }
        else if repository.ahead == nil { tags.append(("未跟踪远端", .secondary)) }
        if tags.isEmpty { tags.append(("已推送", .green)) }
        return tags
    }

    private func badges(_ tags: [(String, Color)]) -> some View {
        ForEach(tags.indices, id: \.self) { index in
            Text(tags[index].0).font(.caption2.weight(.medium))
                .foregroundStyle(tags[index].1)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(tags[index].1.opacity(0.12), in: Capsule())
        }
    }
}

private struct DeviceGitRepositoryView: View {
    let agent: ConsoleAgent
    let repository: DeviceGitRepository
    let updateSummary: (DeviceGitRepository) -> Void
    @ObservedObject private var client = DeviceMonitorClient.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var snapshot: DeviceGitDetail?
    @State private var action: GitSheetAction?
    @State private var loading = false
    @State private var checkingRemote = false
    @State private var remoteWarning: String?
    @State private var error: String?
    @State private var notice: String?
    private var current: DeviceGitRepository { snapshot?.repository ?? repository }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(current.name).font(.title2.bold())
                Text(current.id == "." ? "~/Code" : "~/Code/" + current.id)
                    .font(.caption.monospaced()).foregroundStyle(HakoStyle.muted).textSelection(.enabled)
                GitStatusBadges(repository: current)
                VStack(alignment: .leading, spacing: 9) {
                    gitFact("当前分支", current.branch ?? "分离的 HEAD")
                    Divider()
                    gitFact(current.remoteName.map { "远程仓库 · \($0)" } ?? "远程仓库", current.remoteUrl ?? "未配置")
                    Divider()
                    gitFact("推送目标", current.pushTarget ?? "未配置")
                }
                .devicePagePanel()
                actions
                if let snapshot {
                    changes(snapshot)
                    if !snapshot.pending.isEmpty {
                        commitList(snapshot, title: "待推送提交")
                    }
                }
                if loading {
                    Text(checkingRemote ? "正在检查远端…" : "正在读取仓库…")
                        .font(.footnote).foregroundStyle(HakoStyle.muted)
                }
                if let remoteWarning { Text(remoteWarning).font(.footnote).foregroundStyle(.orange) }
                if let notice { Text(notice).font(.footnote).foregroundStyle(.green) }
                if let error = error ?? (snapshot == nil && !loading ? repository.error : nil) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            .padding(20)
        }
        .background(HakoStyle.background)
        .foregroundStyle(HakoStyle.text)
        .navigationTitle("仓库详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(HakoStyle.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(item: $action) { action in
            DeviceGitOperationSheet(agent: agent, action: action) { result in
                notice = nil
                switch result {
                case .success(let text): notice = text
                case .failure: break
                }
                Task {
                    await reload(checkRemote: false)
                    if case .failure(let failure) = result { error = failure.localizedDescription }
                }
            }
        }
    }

    private var actions: some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
        let ready = !loading && error == nil
        let canCommit = ready && snapshot?.repository.canCommit == true &&
            snapshot?.changes.isEmpty == false && supports(DeviceGitCommand.commit)
        let canPush = ready && snapshot?.repository.canPush == true && supports(DeviceGitCommand.push)
        let showsPull = supports(DeviceGitCommand.pull) && (current.behind ?? 0) > 0
        let canPull = ready && remoteWarning == nil && snapshot?.canPull == true
        return VStack(alignment: .leading, spacing: 8) {
            layout {
                Button("创建提交") { if let snapshot { action = GitSheetAction(kind: .commit, snapshot: snapshot) } }
                    .buttonStyle(HakoActionButtonStyle(primary: canCommit, outlined: true))
                    .disabled(!canCommit)
                Button("推送") { if let snapshot { action = GitSheetAction(kind: .push, snapshot: snapshot) } }
                    .buttonStyle(HakoActionButtonStyle(primary: canPush, outlined: true))
                    .disabled(!canPush)
                if showsPull {
                    Button("拉取") { if let snapshot { action = GitSheetAction(kind: .pull, snapshot: snapshot) } }
                        .buttonStyle(HakoActionButtonStyle(primary: canPull, outlined: true))
                        .disabled(!canPull)
                }
            }
            if showsPull, ready, remoteWarning == nil, !canPull {
                Text((current.ahead ?? 0) > 0 ? "本地和远端分支已分叉，请在电脑上处理。" :
                     current.changedCount > 0 ? "处理本地改动后可拉取。" : "当前分支无法快进，请在电脑上检查。")
                    .font(.footnote).foregroundStyle(HakoStyle.muted)
            }
        }
    }

    private func supports(_ command: String) -> Bool {
        agent.capabilities?.contains { $0.name == command && $0.version == 1 } == true
    }

    @ViewBuilder private func changes(_ snapshot: DeviceGitDetail) -> some View {
        if snapshot.repository.changedCount > 0 {
            VStack(alignment: .leading, spacing: 8) {
                Text("未提交的文件 · \(snapshot.repository.changedCount)").font(.subheadline.weight(.semibold))
                ForEach(snapshot.changes) { change in
                    Divider()
                    LabeledContent {
                        Text(change.label).font(.caption).foregroundStyle(HakoStyle.muted)
                    } label: {
                        Text(change.path).font(.footnote).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if snapshot.changesTruncated {
                    Text("仅显示部分文件，其余文件可在电脑上处理。").font(.caption).foregroundStyle(HakoStyle.muted)
                }
            }
            .devicePagePanel()
        }
    }

    private func reload(checkRemote: Bool = true) async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false; checkingRemote = false }
        let context = client.requestContext
        do {
            try await readDetail()
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription; return }
        guard checkRemote, !Task.isCancelled, context == client.requestContext else { return }
        remoteWarning = nil
        guard snapshot?.pullSource != nil, supports(DeviceGitCommand.remote) else { return }
        checkingRemote = true
        do {
            let initial = try await client.invokeAgent(agent, method: DeviceGitCommand.remote, version: 1,
                params: ["repository": repository.id], as: DeviceGitOperation.self)
            let final = try await awaitGitOperation(initial, agent: agent, client: client)
            guard final.state == .succeeded else {
                remoteWarning = final.message ?? "远端检查尚未确认，请下拉刷新。"
                return
            }
            try await readDetail()
        } catch is CancellationError { }
        catch { remoteWarning = error.localizedDescription }
    }

    private func readDetail() async throws {
        let detail = try await client.invokeAgent(agent, method: DeviceGitCommand.detail, version: 1,
            params: ["repository": repository.id], as: DeviceGitDetail.self)
        try Task.checkCancellation()
        snapshot = detail
        updateSummary(detail.repository)
    }
}

private struct GitSheetAction: Identifiable {
    enum Kind: String {
        case commit, push, pull

        var command: String {
            switch self {
            case .commit: DeviceGitCommand.commit
            case .push: DeviceGitCommand.push
            case .pull: DeviceGitCommand.pull
            }
        }
        var title: String {
            switch self {
            case .commit: "创建提交"
            case .push: "确认推送"
            case .pull: "确认拉取"
            }
        }
        var progress: String {
            switch self {
            case .commit: "正在提交…"
            case .push: "正在推送…"
            case .pull: "正在拉取…"
            }
        }
    }
    let kind: Kind
    let snapshot: DeviceGitDetail
    var id: String { kind.rawValue }
}

private struct DeviceGitOperationSheet: View {
    let agent: ConsoleAgent
    let action: GitSheetAction
    let finished: (Result<String, Error>) -> Void
    @ObservedObject private var client = DeviceMonitorClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var selected: Set<Int> = []
    @State private var working = false
    private var repo: DeviceGitRepository { action.snapshot.repository }
    private var committing: Bool { action.kind == .commit }
    private var branchDescription: String {
        let branch = repo.branch ?? "—"
        switch action.kind {
        case .commit: return branch
        case .push: return "\(branch) → \(repo.pushTarget ?? "—")"
        case .pull: return "\(action.snapshot.pullSource ?? "—") → \(branch)"
        }
    }
    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    Text(repo.name).font(.title2.bold())
                    Text(branchDescription)
                        .font(.caption.monospaced()).foregroundStyle(HakoStyle.muted)
                    switch action.kind {
                    case .commit: commitFields
                    case .push: pushFields
                    case .pull: pullFields
                    }
                    HStack(spacing: 12) {
                        Button("取消") { dismiss() }
                            .buttonStyle(HakoActionButtonStyle(primary: false))
                            .disabled(working)
                        Button(working ? action.kind.progress : action.kind.title) { Task { await execute() } }
                            .buttonStyle(HakoActionButtonStyle())
                            .disabled(working || (committing && (trimmedMessage.isEmpty || trimmedMessage.utf16.count > 2000 || selected.isEmpty)))
                    }
                }
                .padding(20)
            }
            .background(HakoStyle.background)
            .foregroundStyle(HakoStyle.text)
            .navigationTitle(action.kind.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(working)
        .onAppear { selected = Set(action.snapshot.changes.map(\.index)) }
    }

    private var commitFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("提交说明").font(.subheadline).foregroundStyle(HakoStyle.muted)
            TextField("简述本次改动", text: $message, axis: .vertical)
                .lineLimit(2...5).accessibilityLabel("提交说明")
                .devicePagePanel()
            VStack(alignment: .leading, spacing: 5) {
                Text("本次提交的文件").font(.subheadline.weight(.semibold))
                ForEach(action.snapshot.changes) { change in
                    Divider()
                    Toggle(isOn: Binding(get: { selected.contains(change.index) }, set: { enabled in
                        if enabled { selected.insert(change.index) } else { selected.remove(change.index) }
                    })) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(change.path).font(.footnote).fixedSize(horizontal: false, vertical: true)
                            Text(change.label).font(.caption2).foregroundStyle(HakoStyle.muted)
                        }
                    }
                    .toggleStyle(GitFileSelectionStyle())
                }
                if action.snapshot.changesTruncated {
                    Text("仅显示部分文件，其余文件可在电脑上处理。").font(.caption).foregroundStyle(HakoStyle.muted)
                }
            }
            .devicePagePanel()
        }
        .disabled(working)
    }

    private var pushFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 9) {
                gitFact(repo.remoteName.map { "远程仓库 · \($0)" } ?? "远程仓库", repo.remoteUrl ?? "—")
                Divider()
                gitFact("推送分支", repo.pushTarget ?? "—")
            }.devicePagePanel()
            commitList(action.snapshot, title: "本次推送")
        }
    }

    private var pullFields: some View {
        VStack(alignment: .leading, spacing: 9) {
            gitFact("远程仓库", action.snapshot.pullUrl ?? "—")
            Divider()
            gitFact("拉取来源", action.snapshot.pullSource ?? "—")
            Divider()
            gitFact("待拉取提交", "\(repo.behind ?? 0) 个")
        }
        .devicePagePanel()
    }

    private func execute() async {
        guard !working else { return }
        working = true
        defer { working = false }
        var params: [String: Any] = ["repository": repo.id, "revision": action.snapshot.revision]
        if committing {
            params["message"] = trimmedMessage
            params["files"] = action.snapshot.changes.map(\.index).filter(selected.contains)
        }
        let result: Result<String, Error>
        do {
            let initial = try await client.invokeAgent(agent, method: action.kind.command,
                                                       version: 1, params: params, as: DeviceGitOperation.self)
            let final = try await awaitGitOperation(initial, agent: agent, client: client)
            if final.state == .succeeded {
                switch action.kind {
                case .commit: result = .success("已创建本地提交")
                case .push: result = .success("已推送到 \(repo.pushTarget ?? "远程仓库")")
                case .pull: result = .success("已拉取并更新本地分支")
                }
            } else {
                result = .failure(HakoError(message: final.message ?? "操作结果未能确认，请刷新仓库核对。"))
            }
        } catch let error as ConsoleAgentError {
            result = .failure(error)
        } catch {
            result = .failure(HakoError(message: "操作结果未能确认，请刷新仓库核对后再操作。"))
        }
        finished(result)
        dismiss()
    }

}

@MainActor private func awaitGitOperation(_ initial: DeviceGitOperation, agent: ConsoleAgent,
                                          client: DeviceMonitorClient) async throws -> DeviceGitOperation {
    var operation = initial
    let deadline = ContinuousClock.now + .seconds(150)
    let context = client.requestContext
    while operation.state == .running && ContinuousClock.now < deadline {
        try await Task.sleep(for: .seconds(1))
        guard client.requestContext == context else { throw CancellationError() }
        do {
            operation = try await client.invokeAgent(agent, method: DeviceGitCommand.operation, version: 1,
                params: ["operation": initial.id], as: DeviceGitOperation.self)
        } catch is URLError {
            // Only status reads are retried.
        }
    }
    return operation
}

private struct GitFileSelectionStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(configuration.isOn ? HakoStyle.text : HakoStyle.muted)
                    .accessibilityHidden(true)
                configuration.label
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

private func gitFact(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(label).font(.caption).foregroundStyle(HakoStyle.muted)
        Text(value).font(.subheadline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
}

private func commitList(_ snapshot: DeviceGitDetail, title: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
        Text(snapshot.repository.ahead.map { "\(title) · \($0) 个提交" } ?? title)
            .font(.subheadline.weight(.semibold))
        if snapshot.repository.ahead == nil {
            Text("该远程分支暂无跟踪记录，以下为本地最近的提交。")
                .font(.caption).foregroundStyle(HakoStyle.muted)
        }
        ForEach(snapshot.pending) { commit in
            Divider()
            Text(commit.subject.isEmpty ? String(commit.id.prefix(8)) : commit.subject)
                .font(.footnote).fixedSize(horizontal: false, vertical: true)
        }
        if let ahead = snapshot.repository.ahead, ahead > snapshot.pending.count {
            Text("仅显示最近的提交。").font(.caption).foregroundStyle(HakoStyle.muted)
        }
    }
    .devicePagePanel()
}
