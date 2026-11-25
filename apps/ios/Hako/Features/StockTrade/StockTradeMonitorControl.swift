import SwiftUI

struct StockTradeMonitorSteps: View {
    private let steps = [
        ("初始化观察名单", "导入最新完整选股结果中的正式推荐，保留已有纸面持仓。"),
        ("发布首份监控快照", "名单为空也发布有效快照，App 可正常读取监控与提醒。"),
        ("启用持续调度", "后台按交易时段采样、处理规则提醒及邮件重试，离开 App 后继续。")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(steps.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(index + 1)").font(.caption.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .background(StockTradeAppearance.soft, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(steps[index].0).font(.subheadline.weight(.semibold))
                        Text(steps[index].1).font(.footnote).foregroundStyle(.secondary)
                    }
                }.accessibilityElement(children: .combine)
            }
        }.padding(.bottom, 16)
    }
}

struct StockTradeMonitorControlStatus: View {
    @ObservedObject var store: StockTradeStore
    @State private var status: StockTradeMonitorStatus?
    @State private var error: String?
    @State private var loading = false
    @State private var displayedScope: UUID?
    var body: some View {
        StockTradeCard {
            VStack(alignment: .leading, spacing: 12) {
                if displayedScope == store.scope, let status {
                    LabeledContent("监控调度", value: status.title).font(.subheadline)
                    if let date = status.activatedAt {
                        Text("首次启用 · " + StockTradeTime.display(date)).font(.caption).foregroundStyle(.secondary)
                    }
                    if status.failureCode != nil {
                        StockTradeMessage(text: "最近一次监控任务异常，后台会在下次调度重试；可查看采样时间核对进展。")
                    }
                } else if loading { ProgressView("读取监控状态…") }
                if let error { StockTradeMessage(text: error) }
                Button(loading ? "正在刷新…" : "刷新监控状态") { Task { await load() } }
                    .font(.subheadline).disabled(loading)
            }
        }.task(id: store.scope) { status = nil; displayedScope = nil; await load() }
    }
    private func load() async {
        let scope = store.scope
        loading = true; error = nil
        defer { if scope == store.scope { loading = false } }
        do {
            let value = try await store.read(["monitor", "status"], as: StockTradeMonitorStatus.self)
            guard scope == store.scope else { return }
            status = value; displayedScope = scope
        } catch is CancellationError { }
        catch { if scope == store.scope { self.error = error.localizedDescription } }
    }
}
