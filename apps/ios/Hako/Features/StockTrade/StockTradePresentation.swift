import SwiftUI

enum StockTradeAppearance {
    static let background = HakoStyle.adaptive(0xf3f2f8, 0x19191e)
    static let panel = HakoStyle.adaptive(0xffffff, 0x27272e)
    static let tint = HakoStyle.adaptive(0x0860d4, 0x77b1ff)
    static let soft = HakoStyle.adaptive(0xedf4ff, 0x20314c)
    static let line = HakoStyle.adaptive(0xe9e8ee, 0x393940)
    static let selectedText = HakoStyle.adaptive(0xffffff, 0x11213b)
    static let action = HakoActionButtonStyle(backgroundColor: tint)
}

enum StockTradeTab: String, CaseIterable, Identifiable {
    case picks = "选股", watch = "关注", monitor = "监控", work = "工作台"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .picks: "line.3.horizontal.decrease"
        case .watch: "star"
        case .monitor: "waveform.path.ecg"
        case .work: "square.3.layers.3d"
        }
    }
    var accessibilityID: String {
        switch self {
        case .picks: "cerno.tab.picks"
        case .watch: "cerno.tab.watch"
        case .monitor: "cerno.tab.monitor"
        case .work: "cerno.tab.work"
        }
    }
}

struct StockTradeBottomTabs: View {
    @Binding var selection: StockTradeTab
    var body: some View {
        HStack(spacing: 4) {
            ForEach(StockTradeTab.allCases) { tab in
                Button { selection = tab } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol).font(.system(size: 20, weight: .regular))
                        Text(tab.rawValue).font(.caption2.weight(selection == tab ? .semibold : .regular))
                    }
                    .foregroundStyle(selection == tab ? StockTradeAppearance.tint : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(selection == tab ? [.isSelected] : [])
                .accessibilityIdentifier(tab.accessibilityID)
            }
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 6)
        .background(StockTradeAppearance.panel)
        .overlay(alignment: .top) { Rectangle().fill(StockTradeAppearance.line).frame(height: 0.5) }
        .accessibilityElement(children: .contain).accessibilityLabel("Cerno 导航")
    }
}

struct StockTradeScreen<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
        }.background(StockTradeAppearance.background)
    }
}

struct StockTradeCard<Content: View>: View {
    var padding: CGFloat = 19
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding).background(StockTradeAppearance.panel, in: RoundedRectangle(cornerRadius: 25))
    }
}

struct StockTradeHeading: View {
    let title: String
    let subtitle: String
    var action: String? = nil
    var symbol: String? = nil
    var perform: (() -> Void)? = nil
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 29
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("CERNO / A 股").font(.caption2).tracking(1).foregroundStyle(.secondary)
                Text(title).font(.system(size: titleSize, weight: .bold))
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let action, let perform {
                Button(action: perform) {
                    Group {
                        if let symbol { Image(systemName: symbol).font(.title3) }
                        else { Text(action).font(.subheadline) }
                    }.frame(minWidth: 44, minHeight: 44)
                }.buttonStyle(.plain).foregroundStyle(StockTradeAppearance.tint).accessibilityLabel(action)
            }
        }.padding(.bottom, 7)
    }
}

struct StockTradeSectionLabel: View {
    let title: String
    var body: some View { Text(title).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4).padding(.top, 8) }
}

struct StockTradeEntryRow: View {
    let title: String
    var subtitle: String = ""
    var separator = true
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.subheadline).foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { if separator { Divider() } }
            .accessibilityElement(children: .combine)
    }
}

struct StockTradeTaskBanner: View {
    let task: StockTradeWorkflowTask
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                Text(task.kind.title + " · " + StockTradeWorkflowKind.phaseTitle(task.phase))
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
            }.font(.footnote).foregroundStyle(StockTradeAppearance.tint)
                .padding(.horizontal, 15).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StockTradeAppearance.soft, in: RoundedRectangle(cornerRadius: 17))
        }.buttonStyle(.plain)
    }
}

struct StockTradeTimeline: View {
    let phases: [String]
    var task: StockTradeWorkflowTask? = nil
    private var current: Int { task.flatMap { phases.firstIndex(of: $0.phase) } ?? -1 }
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(phases.enumerated()), id: \.element) { index, phase in
                let done = task?.state == .succeeded || index < current
                let active = index == current
                HStack(alignment: .top, spacing: 13) {
                    VStack(spacing: 0) {
                        Group {
                            if done { Image(systemName: "checkmark").font(.caption.weight(.semibold)) }
                            else { Text("\(index + 1)").font(.caption) }
                        }.frame(width: 27, height: 27)
                            .foregroundStyle(active ? StockTradeAppearance.selectedText : done ? StockTradeAppearance.tint : Color.secondary)
                            .background(active ? StockTradeAppearance.tint : done ? StockTradeAppearance.soft : StockTradeAppearance.background, in: Circle())
                        if index < phases.count - 1 { Rectangle().fill(StockTradeAppearance.line).frame(width: 1).frame(maxHeight: .infinity) }
                    }.frame(width: 27)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(StockTradeWorkflowKind.phaseTitle(phase)).font(.subheadline.weight(.semibold))
                        Text(description(phase, done: done, active: active)).font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 3).padding(.bottom, 20).frame(maxWidth: .infinity, alignment: .leading)
                }.fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .contain)
    }
    private func description(_ phase: String, done: Bool, active: Bool) -> String {
        guard let task else {
            return ["fetch": "更新全市场日线与基础数据", "preselect": "生成候选名单，沿用后台策略", "review": "形成评分、入选原因与风险说明", "publish": "确认完整性后切换最新结果"][phase] ?? ""
        }
        if done { return "已完成" }
        if active { return task.state == .failed ? "此步骤未完成" : "执行中 · 等待后台进度" }
        return "等待前序步骤"
    }
}

struct StockTradeFootnote: View {
    let text: String
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 4) }
}
