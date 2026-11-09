import SwiftUI

struct DeviceCapabilityPages<Overview: View, Content: View, Terminal: View>: View {
    private let capabilities: [ConsoleAgentCapability]
    private let emptyMessage: String
    private let tabTitle: (ConsoleAgentCapability) -> String
    private let overview: () -> Overview
    private let content: (ConsoleAgentCapability) -> Content
    private let terminal: () -> Terminal
    @AppStorage private var savedOrder: Data
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedName: String?
    @State private var showingTerminal = false

    init(capabilities: [ConsoleAgentCapability], order: DeviceCardOrder.Storage, emptyMessage: String,
         tabTitle: @escaping (ConsoleAgentCapability) -> String,
         @ViewBuilder overview: @escaping () -> Overview,
         @ViewBuilder content: @escaping (ConsoleAgentCapability) -> Content,
         @ViewBuilder terminal: @escaping () -> Terminal) {
        self.capabilities = capabilities
        self.emptyMessage = emptyMessage
        self.tabTitle = tabTitle
        self.overview = overview
        self.content = content
        self.terminal = terminal
        _savedOrder = AppStorage(wrappedValue: order.initialData, order.key)
    }

    var body: some View {
        let pages = DeviceCardOrder.pages(capabilities, savedOrder: savedOrder)
        let selected = pages.first { $0.name == selectedName } ?? pages.first
        Group {
            if showingTerminal {
                VStack(spacing: 0) {
                    overview()
                        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
                    tabBar(pages, selected: nil)
                        .padding(.horizontal, 20)
                    terminal()
                }
            } else {
                scrollablePages(pages, selected: selected)
            }
        }
        .background(HakoStyle.background)
        .foregroundStyle(HakoStyle.text)
    }

    private func scrollablePages(_ pages: [ConsoleAgentCapability], selected: ConsoleAgentCapability?) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    overview()
                        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
                        .id("device-overview")
                    if let selected {
                        Section {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(selected.pageTitle).font(.headline).accessibilityAddTraits(.isHeader)
                                content(selected)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 24)
                            .id(selected.name)
                        } header: {
                            tabBar(pages, selected: selected.name)
                                .padding(.horizontal, 20)
                                .background(HakoStyle.background)
                        }
                    } else {
                        Section {
                            Text(emptyMessage).font(.subheadline).foregroundStyle(HakoStyle.muted)
                                .frame(maxWidth: .infinity).padding(20)
                        } header: {
                            tabBar(pages, selected: nil).padding(.horizontal, 20)
                                .background(HakoStyle.background)
                        }
                    }
                }
            }
            .onChange(of: selected?.name, initial: true) { previous, name in
                // Keep the selected page when it moves between the bar and the menu.
                selectedName = name
                if previous != name { scroll.scrollTo("device-overview", anchor: .top) }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func tabBar(_ pages: [ConsoleAgentCapability], selected: String?) -> some View {
        let visible = pages.prefix(DeviceCardOrder.visiblePageLimit)
        let overflow = pages.dropFirst(DeviceCardOrder.visiblePageLimit)
        let overflowSelection = overflow.first { $0.name == selected }
        return HStack(spacing: 4) {
            if visible.isEmpty {
                Button { showingTerminal = false } label: {
                    Text("概览").frame(maxWidth: .infinity, minHeight: 44)
                        .modifier(DevicePageTabStyle(selected: !showingTerminal))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(showingTerminal ? [] : .isSelected)
            } else if dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(visible) { page in tab(page, selected: selected, expands: false) }
                    }
                }
                .scrollIndicators(.hidden)
            } else {
                ForEach(visible) { page in tab(page, selected: selected, expands: true) }
            }
            Button { showingTerminal = true } label: {
                Text("终端").frame(minWidth: 44, maxWidth: dynamicTypeSize.isAccessibilitySize ? nil : .infinity, minHeight: 44)
                    .modifier(DevicePageTabStyle(selected: showingTerminal))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(showingTerminal ? .isSelected : [])
            if !overflow.isEmpty {
                Menu {
                    ForEach(overflow) { page in
                        Button { select(page) } label: {
                            if page.name == selected {
                                Label(page.pageTitle, systemImage: "checkmark")
                            } else {
                                Text(page.pageTitle)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(overflowSelection.map(tabTitle) ?? "更多").lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }
                    .frame(minWidth: 48, maxWidth: 65, minHeight: 44)
                    .modifier(DevicePageTabStyle(selected: overflowSelection != nil))
                }
                .menuOrder(.fixed)
                .accessibilityLabel(overflowSelection.map { "更多页面，当前为\($0.pageTitle)" } ?? "更多设备页面")
                .accessibilityAddTraits(overflowSelection == nil ? [] : .isSelected)
            }
        }
        .background(alignment: .bottom) { Rectangle().fill(HakoStyle.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("设备页面")
    }

    private func select(_ page: ConsoleAgentCapability) {
        selectedName = page.name
        showingTerminal = false
    }

    private func tab(_ page: ConsoleAgentCapability, selected: String?, expands: Bool) -> some View {
        Button { select(page) } label: {
            Text(tabTitle(page)).lineLimit(1).minimumScaleFactor(0.85)
                .frame(minWidth: expands ? nil : 44, maxWidth: expands ? .infinity : nil, minHeight: 44)
                .modifier(DevicePageTabStyle(selected: selected == page.name))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(page.pageTitle)
        .accessibilityAddTraits(selected == page.name ? .isSelected : [])
    }
}

private struct DevicePageTabStyle: ViewModifier {
    let selected: Bool

    func body(content: Content) -> some View {
        content
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? HakoStyle.text : HakoStyle.muted)
            .overlay(alignment: .bottom) {
                if selected { Rectangle().fill(HakoStyle.text).frame(height: 2).padding(.horizontal, 4) }
            }
    }
}

struct DevicePageOrderSection: View {
    private let agent: ConsoleAgent
    private let capabilities: [ConsoleAgentCapability]
    @AppStorage private var savedOrder: Data

    init(agent: ConsoleAgent, capabilities: [ConsoleAgentCapability], order: DeviceCardOrder.Storage) {
        self.agent = agent
        self.capabilities = capabilities
        _savedOrder = AppStorage(wrappedValue: order.initialData, order.key)
    }

    var body: some View {
        let pages = DeviceCardOrder.pages(capabilities, savedOrder: savedOrder)
        Section {
            if pages.isEmpty {
                Text(agent.capabilities == nil ? "尚未获取设备页面。" : "此设备暂无可排序的页面。")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                HStack(spacing: 10) {
                    Text((index + 1).formatted()).font(.caption.monospacedDigit())
                        .foregroundStyle(HakoStyle.muted).frame(minWidth: 18, alignment: .leading)
                    Text(page.pageTitle).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if index >= DeviceCardOrder.visiblePageLimit {
                        Text("更多").font(.caption).foregroundStyle(HakoStyle.muted)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                .moveDisabled(pages.count < 2)
            }
            .onMove { source, destination in
                var names = pages.map(\.name)
                guard source.allSatisfy(names.indices.contains), (0...names.count).contains(destination) else { return }
                names.move(fromOffsets: source, toOffset: destination)
                let merged = DeviceCardOrder.saving(visible: names, previous: DeviceCardOrder.names(from: savedOrder))
                if let encoded = try? JSONEncoder().encode(merged) { savedOrder = encoded }
            }
        } header: {
            VStack(alignment: .leading, spacing: 4) {
                Text("页面排序").accessibilityAddTraits(.isHeader)
                Text("设备 ID \(agent.id) · 设备名 \(agent.name)").font(.caption)
            }
            .textCase(nil)
        } footer: {
            if pages.count > 1 {
                Text("拖动右侧手柄，松手后自动保存。")
            }
        }
    }
}

private extension DeviceCardOrder {
    static func pages(_ capabilities: [ConsoleAgentCapability], savedOrder: Data) -> [ConsoleAgentCapability] {
        let byName = Dictionary(capabilities.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return arranged(available: capabilities.map(\.name), saved: names(from: savedOrder)).compactMap { byName[$0] }
    }
}

private extension ConsoleAgentCapability {
    var pageTitle: String {
        switch (name, version) {
        case ("query.system.metrics", 1): "系统指标"
        case ("query.codex.usage", 1): "Codex 活动"
        case ("query.network.listeners", 1): "监听端口"
        case ("action.network.http.check", 1): "URL 连通性检测"
        case (DeviceGitCommand.list, 1): "Git 仓库"
        default: name + " · v\(version)"
        }
    }
}

extension View {
    func devicePagePanel() -> some View {
        padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HakoStyle.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(HakoStyle.line, lineWidth: 1) }
    }
}
