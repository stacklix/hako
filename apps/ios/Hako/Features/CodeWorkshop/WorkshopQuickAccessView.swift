import SwiftUI

// Both lists use the same status precedence as well as the same ordering.
struct WorkshopSessionStatusIcon: View {
    let item: WorkshopSessionListItem

    var body: some View {
        Image(systemName: item.session.access?.state == "occupied" ? "lock" :
            item.hasDraft || item.session.inProgress || item.isUnread ? "terminal.fill" : "terminal")
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(item.hasDraft ? Color.orange : item.session.inProgress ? Color.green :
                item.isUnread ? Color.blue : HakoStyle.text)
            .accessibilityHidden(true)
    }
}

struct WorkshopPinnedSessionIcon: View {
    let page: HakoPinnedPage
    @ObservedObject private var store = WorkshopRuntime.shared.store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            if page.parameters["namespace"] == store.networkNamespace.consoleDigest,
               let agentID = page.parameters["computerID"], let threadID = page.parameters["threadID"],
               let item = store.quickAccessItem(agentID: agentID, threadID: threadID, at: timeline.date) {
                WorkshopSessionStatusIcon(item: item)
            } else { Image(systemName: page.symbol) }
        }
    }
}

struct WorkshopQuickAccessView: View {
    let select: (HakoPinnedPage) -> Void
    @ObservedObject private var store = WorkshopRuntime.shared.store
    @ObservedObject private var pins = HakoPinStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshing = false
    @State private var loadingMore = false
    @State private var failure: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let items = store.quickAccessItems(at: timeline.date)
            List {
                if items.isEmpty {
                    if refreshing {
                        ProgressView("正在读取工坊会话…").frame(maxWidth: .infinity, minHeight: 120)
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    } else {
                        ContentUnavailableView(store.authenticated ? "暂无工坊会话" : "请先登录服务器",
                            systemImage: "terminal", description: Text(store.authenticated ?
                                "电脑在线后会显示各项目的会话。" : "在主应用设置中连接服务器后查看工坊会话。"))
                            .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    }
                } else {
                    Section {
                        ForEach(items) { value in
                            if let page = WorkshopPinContributor.page(for: value.item.session, agent: value.agent,
                                application: value.application, namespace: store.networkNamespace.consoleDigest) {
                                row(value, page: page)
                            }
                        }
                    }
                }
                if let failure {
                    Section {
                        Text(failure).font(.footnote).foregroundStyle(.secondary)
                        Button("重新加载") { Task { await refresh(discover: true) } }.disabled(refreshing || loadingMore)
                    }.listRowBackground(HakoStyle.card)
                }
                if store.quickAccessHasMore {
                    Button {
                        Task { await refresh(more: true) }
                    } label: {
                        HStack {
                            Text("加载更早的会话")
                            Spacer()
                            if loadingMore { ProgressView() }
                        }.frame(minHeight: 44)
                    }
                    .disabled(refreshing || loadingMore)
                    .listRowBackground(HakoStyle.card)
                }
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden)
            .refreshable { await refresh(discover: true) }
        }
        .task(id: store.scope + "|\(scenePhase == .active)") {
            failure = nil; refreshing = false; loadingMore = false
            guard scenePhase == .active else { return }
            await store.prepareNetwork()
            store.beginVisit()
            if !store.authenticated { await store.restore() }
            else { await store.loadComputers() }
            var discoveredAt = Date.now
            while !Task.isCancelled {
                let discover = Date.now.timeIntervalSince(discoveredAt) >= 30
                await refresh(discover: discover)
                if discover { discoveredAt = .now }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func row(_ value: WorkshopQuickAccessItem, page: HakoPinnedPage) -> some View {
        let item = value.item
        let occupied = item.session.access?.state == "occupied"
        return HStack(spacing: 0) {
            Button { select(page) } label: {
                HStack(spacing: 12) {
                    WorkshopSessionStatusIcon(item: item).font(.title3).frame(width: 38, height: 38)
                        .background(HakoStyle.background, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.session.listTitle).font(.subheadline.weight(.medium)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(value.application.name + (store.agents.count > 1 ? " · " + value.agent.name : ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .frame(minHeight: 60).frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue((occupied ? "其他客户端占用，" : "") + (item.hasDraft ? "有未发送的草稿" :
                item.session.inProgress ? (item.session.state == "waiting" ? "等待确认" : "处理中") : item.isUnread ? "未读" : "已读"))
            Button {
                if pins.contains(page) { pins.remove([page.id]) } else { pins.pin(page) }
            } label: {
                Image(systemName: pins.contains(page) ? "pin.fill" : "pin")
                    .font(.subheadline).foregroundStyle(pins.contains(page) ? HakoStyle.text : HakoStyle.muted)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel((pins.contains(page) ? "取消固定" : "固定") + page.title)
        }
        .listRowBackground(HakoStyle.card)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
    }

    private func refresh(more: Bool = false, discover: Bool = false) async {
        guard !refreshing, !loadingMore, store.authenticated else { return }
        let ticket = store.scope
        if more { loadingMore = true } else { refreshing = true }
        defer { if ticket == store.scope { refreshing = false; loadingMore = false } }
        do {
            if discover {
                store.beginVisit()
                await store.loadComputers()
                try Task.checkCancellation()
                guard ticket == store.scope else { return }
            }
            try await store.refreshQuickAccess(more: more)
            try Task.checkCancellation()
            guard ticket == store.scope else { return }
            failure = nil
        } catch is CancellationError { }
        catch { if ticket == store.scope, !Task.isCancelled { failure = error.localizedDescription } }
    }
}
