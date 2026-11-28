import SwiftUI

struct DeviceCapabilityPages<Overview: View, Content: View, Terminal: View>: View {
    private let capabilities: [ConsoleAgentCapability]
    private let emptyMessage: String
    private let tabTitle: (ConsoleAgentCapability) -> String
    private let refresh: @MainActor () async -> Void
    private let overview: () -> Overview
    private let content: (ConsoleAgentCapability) -> Content
    private let terminal: (Bool, Binding<Bool>) -> Terminal
    @AppStorage private var savedOrder: Data
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedName: String?
    @State private var terminalOpened = false
    @State private var terminalFullScreen = false
    private var pages: [DevicePage] { DeviceCardOrder.pages(capabilities, savedOrder: savedOrder) }
    private var selected: DevicePage { pages.first { $0.name == selectedName } ?? pages.first ?? .terminal }
    private var showingTerminal: Bool { selected.name == DeviceCardOrder.terminalPageName }
    private var showingFullScreen: Bool { showingTerminal && terminalFullScreen }

    init(capabilities: [ConsoleAgentCapability], order: DeviceCardOrder.Storage, emptyMessage: String,
         tabTitle: @escaping (ConsoleAgentCapability) -> String,
         refresh: @escaping @MainActor () async -> Void,
         @ViewBuilder overview: @escaping () -> Overview,
         @ViewBuilder content: @escaping (ConsoleAgentCapability) -> Content,
         @ViewBuilder terminal: @escaping (Bool, Binding<Bool>) -> Terminal) {
        self.capabilities = capabilities
        self.emptyMessage = emptyMessage
        self.tabTitle = tabTitle
        self.refresh = refresh
        self.overview = overview
        self.content = content
        self.terminal = terminal
        _savedOrder = AppStorage(wrappedValue: order.initialData, order.key)
    }

    var body: some View {
        let pages = self.pages
        let selected = self.selected
        ZStack {
            if !showingTerminal {
                scrollablePages(pages, selected: selected.capability)
            }
            if terminalOpened || showingTerminal {
                // Keep the SSH session and its renderer mounted until the device changes.
                VStack(spacing: 0) {
                    if !showingFullScreen {
                        overview()
                            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
                        tabBar(pages, selected: selected.name)
                            .padding(.horizontal, 20)
                    }
                    terminal(showingTerminal, $terminalFullScreen)
                }
                .opacity(showingTerminal ? 1 : 0)
                .allowsHitTesting(showingTerminal)
                .accessibilityHidden(!showingTerminal)
            }
        }
        .background(HakoStyle.background)
        .foregroundStyle(HakoStyle.text)
        .toolbar(showingFullScreen ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(showingFullScreen)
        .onChange(of: selected.name, initial: true) { _, name in
            selectedName = name
            if name == DeviceCardOrder.terminalPageName { terminalOpened = true }
            else { terminalFullScreen = false }
        }
    }

    private func scrollablePages(_ pages: [DevicePage], selected: ConsoleAgentCapability?) -> some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    overview()
                        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
                        .id("device-overview")
                    if let selected {
                        Section {
                            VStack(alignment: .leading, spacing: 10) {
                                if !selected.hasTelephonyHeading {
                                    Text(selected.pageTitle).font(.headline).accessibilityAddTraits(.isHeader)
                                }
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
            .refreshable { await refresh() }
            .onChange(of: selected?.name, initial: true) { previous, name in
                // Keep the selected page when it moves between the bar and the menu.
                if previous != name { scroll.scrollTo("device-overview", anchor: .top) }
            }
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func tabBar(_ pages: [DevicePage], selected: String?) -> some View {
        let visible = pages.prefix(DeviceCardOrder.visiblePageLimit)
        let overflow = pages.dropFirst(DeviceCardOrder.visiblePageLimit)
        let overflowSelection = overflow.first { $0.name == selected }
        return HStack(spacing: 4) {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(visible) { page in tab(page, selected: selected, expands: false) }
                    }
                }
                .scrollIndicators(.hidden)
            } else {
                ForEach(visible) { page in tab(page, selected: selected, expands: true) }
            }
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
                        Text(overflowSelection.map(title) ?? "更多").lineLimit(1)
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

    private func select(_ page: DevicePage) {
        selectedName = page.name
        if page.name == DeviceCardOrder.terminalPageName { terminalOpened = true }
        else { terminalFullScreen = false }
    }

    private func title(_ page: DevicePage) -> String {
        page.capability.map(tabTitle) ?? "终端"
    }

    private func tab(_ page: DevicePage, selected: String?, expands: Bool) -> some View {
        Button { select(page) } label: {
            Text(title(page)).lineLimit(1).minimumScaleFactor(0.85)
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
                .hakoReorderRow(showsSeparator: index < pages.count - 1)
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
                Text("拖动右侧手柄，松手后自动保存。前 \(DeviceCardOrder.visiblePageLimit) 项显示在标签栏，其余页面收进“更多”。")
            }
        }
    }
}

private enum DevicePage: Identifiable {
    case capability(ConsoleAgentCapability)
    case terminal

    var capability: ConsoleAgentCapability? {
        if case .capability(let value) = self { return value }
        return nil
    }
    var name: String { capability?.name ?? DeviceCardOrder.terminalPageName }
    var id: String { name }
    var pageTitle: String { capability?.pageTitle ?? "终端" }
}

private extension DeviceCardOrder {
    static func pages(_ capabilities: [ConsoleAgentCapability], savedOrder: Data) -> [DevicePage] {
        let byName = Dictionary(capabilities.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return pageNames(capabilities: capabilities.map(\.name), saved: names(from: savedOrder)).compactMap { name in
            name == terminalPageName ? .terminal : byName[name].map(DevicePage.capability)
        }
    }
}

private extension ConsoleAgentCapability {
    var hasTelephonyHeading: Bool {
        version == 1 && [DeviceFilesCommand.list, KageAndroidCommand.list, AndroidDeviceCommand.messages, AndroidDeviceCommand.send,
            AndroidDeviceCommand.calls, AndroidDeviceCommand.call].contains(name)
    }
    var pageTitle: String {
        switch (name, version) {
        case (AndroidDeviceCommand.status, 1): "设备状态"
        case (AndroidDeviceCommand.storage, 1): "存储空间"
        case (AndroidDeviceCommand.battery, 1): "电池信息"
        case (AndroidDeviceCommand.wifi, 1): "Wi-Fi 信息"
        case (AndroidDeviceCommand.screen, 1): "屏幕状态"
        case (AndroidDeviceCommand.sims, 1): "SIM 卡"
        case (AndroidDeviceCommand.messages, 1), (AndroidDeviceCommand.send, 1): "短信"
        case (AndroidDeviceCommand.calls, 1), (AndroidDeviceCommand.call, 1): "通话"
        case (AndroidDeviceCommand.operation, 1): "操作结果查询"
        case ("query.system.metrics", 1): "系统指标"
        case (DeviceProcessCommand.status, 1): "进程占用"
        case ("query.network.listeners", 1): "监听端口"
        case (DeviceServiceCommand.status, 1): "服务监控"
        case (DeviceGitCommand.list, 1): "Git 仓库"
        case (DeviceFilesCommand.list, 1): "文件管理"
        case (KageAndroidCommand.list, 1): "Android 设备"
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
