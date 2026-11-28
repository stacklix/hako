import SwiftUI

struct WorkshopUsageIndicator: View {
    // Toolbar hosting receives values only. It must not create a second store
    // observation/timeline graph while the list's navigation is being updated.
    let window: WorkshopQuotaWindow?
    let date: Date

    var body: some View {
        WorkshopQuotaRings(window: window, date: date, size: 32)
            .accessibilityElement(children: .ignore)
            .accessibilityValue(window.map {
                "本周额度剩余 \(percent($0.remaining(at: date)))，\($0.countdown(at: date))"
            } ?? "本周额度暂不可用")
    }

    private func percent(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0...1))) + "%" } ?? "未知"
    }
}

private struct WorkshopQuotaRings: View {
    let window: WorkshopQuotaWindow?
    let date: Date
    let size: CGFloat

    var body: some View {
        let stroke = max(2.5, size * 0.075)
        ZStack {
            ring(fraction: window?.remaining(at: date).map { $0 / 100 }, color: .green, stroke: stroke)
            ring(fraction: window?.remainingTimeFraction(at: date), color: .blue, stroke: stroke)
                .padding(size * 0.2)
        }
        .padding(stroke / 2)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func ring(fraction: Double?, color: Color, stroke: Double) -> some View {
        ZStack {
            Circle().stroke(HakoStyle.line, lineWidth: stroke)
            if let fraction, fraction > 0 {
                // Deplete clockwise from twelve o'clock, keeping the remaining arc.
                Circle().trim(from: 1 - min(1, max(0, fraction)), to: 1)
                    .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

struct WorkshopUsageSheet: View {
    @ObservedObject var store: WorkshopStore
    let agent: WorkshopAgent
    @ObservedObject var state: WorkshopQuotaState
    private var identity: String { store.scope + "|" + agent.id }
    private var displayedUsage: WorkshopUsageSnapshot? { state.usageIdentity == identity ? state.usage : nil }
    private var fetching: Bool { state.usageIdentity == identity && state.usageFetching }
    private var error: String? { state.usageIdentity == identity ? state.usageError : nil }

    var body: some View {
        SettingsSheet(title: "Codex 用量") {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                Form {
                    quotaSummary(at: max(timeline.date, state.displayedAt))
                    if let usage = displayedUsage {
                        usageSummary(usage)
                        dailyUsage(usage)
                        Section {
                            LabeledContent("执行电脑", value: agent.name)
                            LabeledContent("统计时区", value: usage.timeZone)
                            if !usage.available {
                                Text("未检测到本机 Codex 日志，显示此前采集的数据。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            if !usage.warnings.isEmpty {
                                DisclosureGroup("数据提示") {
                                    ForEach(Array(usage.warnings.enumerated()), id: \.offset) { _, warning in
                                        Text(warning).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        } footer: {
                            Text("Token 总量为输入与输出之和，缓存输入和推理输出已包含在内。每次发送任务或消息计 1 次请求，不累计内部多轮模型调用。额度由账号共享，用量统计仅包含这台电脑的记录。")
                        }
                    } else {
                        Section("每日用量") {
                            if fetching { ProgressView("正在读取用量…") }
                            else { Text("暂无用量数据").foregroundStyle(.secondary) }
                        }
                    }
                    if let error {
                        Section {
                            Text(error).font(.footnote).foregroundStyle(.secondary)
                            Button("重新获取用量") { Task { await refresh() } }
                                .buttonStyle(HakoActionButtonStyle(primary: false)).disabled(fetching || state.fetching)
                        }
                    }
                }
                .scrollContentBackground(.hidden).background(HakoStyle.background)
                .refreshable { await refresh() }
            }
        }
        .task(id: identity) { await loadUsage() }
    }

    private func quotaSummary(at date: Date) -> some View {
        let snapshot = state.identity == store.settingsAccount + "|" + agent.id
            ? state.cached?.snapshot(at: date) : nil
        let window = snapshot?.weeklyWindow
        return Section {
            HStack(spacing: 24) {
                WorkshopQuotaRings(window: window, date: date, size: 76)
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        legend("剩余 Token 额度", color: .green)
                        Text(window?.remaining(at: date).map {
                            $0.formatted(.number.precision(.fractionLength(0...1))) + "%"
                        } ?? (state.fetching ? "获取中…" : "未知"))
                        .font(.title.weight(.semibold)).monospacedDigit()
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        legend("本周剩余时间", color: .blue)
                        Text(window?.countdown(at: date).replacingOccurrences(of: "后重置", with: "") ?? "未知")
                            .font(.subheadline.weight(.medium)).monospacedDigit()
                    }
                }
            }
            .padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
            LabeledContent("下次重置") {
                if let reset = window?.resetDate {
                    Text(reset, format: .dateTime.month().day().hour().minute())
                        .multilineTextAlignment(.trailing)
                } else { Text("未知").foregroundStyle(.secondary) }
            }
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
            LabeledContent("剩余 Credits", value: snapshot?.credits?.displayBalance ?? "未知")
                .monospacedDigit()
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
        }
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func usageSummary(_ usage: WorkshopUsageSnapshot) -> some View {
        Section {
            HStack(spacing: 20) {
                total("Token 总量", value: usage.totalTokens.map(compact) ?? "—")
                Divider()
                total("请求次数", value: usage.countsUserMessages ? usage.totalRequests?.formatted() ?? "—" : "—")
            }.padding(.vertical, 6)
        } header: {
            HStack {
                Text("近 7 天")
                Spacer()
                if let first = usage.days.first, let last = usage.days.last { Text(first.shortDate + " – " + last.shortDate) }
            }
        }
    }

    private func total(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dailyUsage(_ usage: WorkshopUsageSnapshot) -> some View {
        Section("每日用量") {
            WorkshopUsageChart(usage: usage)
        }
    }

    private func compact(_ value: Int64) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US")))
    }

    private func refresh() async {
        async let quota: Void = state.refresh(store: store, agent: agent, clearCache: false)
        async let usage: Void = loadUsage()
        _ = await (quota, usage)
    }

    private func loadUsage() async {
        await state.refreshUsage(store: store, agent: agent)
    }
}
