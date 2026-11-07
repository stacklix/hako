import SwiftUI

struct DeviceCapabilityPages<Overview: View, Content: View>: View {
    private let capabilities: [ConsoleAgentCapability]
    private let emptyMessage: String
    private let title: (ConsoleAgentCapability) -> String
    private let tabTitle: (ConsoleAgentCapability) -> String
    private let overview: () -> Overview
    private let content: (ConsoleAgentCapability) -> Content
    @AppStorage private var savedOrder: Data
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedName: String?
    @State private var showingOrder = false

    init(capabilities: [ConsoleAgentCapability], storageKey: String, emptyMessage: String,
         initialOrder: [String], title: @escaping (ConsoleAgentCapability) -> String,
         tabTitle: @escaping (ConsoleAgentCapability) -> String,
         @ViewBuilder overview: @escaping () -> Overview,
         @ViewBuilder content: @escaping (ConsoleAgentCapability) -> Content) {
        self.capabilities = capabilities
        self.emptyMessage = emptyMessage
        self.title = title
        self.tabTitle = tabTitle
        self.overview = overview
        self.content = content
        _savedOrder = AppStorage(wrappedValue: (try? JSONEncoder().encode(initialOrder)) ?? Data(), storageKey)
    }

    private var persistedNames: [String] {
        (try? JSONDecoder().decode([String].self, from: savedOrder)) ?? []
    }
    private var orderedPages: [ConsoleAgentCapability] {
        let byName = Dictionary(capabilities.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        return DeviceCardOrder.arranged(available: capabilities.map(\.name), saved: persistedNames)
            .compactMap { byName[$0] }
    }

    var body: some View {
        let pages = orderedPages
        let selected = pages.first { $0.name == selectedName } ?? pages.first
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    overview()
                        .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
                        .id("device-overview")
                    if let selected {
                        Section {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(title(selected)).font(.headline).accessibilityAddTraits(.isHeader)
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
                        Text(emptyMessage).font(.subheadline).foregroundStyle(HakoStyle.muted)
                            .frame(maxWidth: .infinity).padding(20)
                    }
                }
            }
            .onChange(of: selected?.name, initial: true) { previous, name in
                // Keep the selected page when it moves between the bar and the menu.
                selectedName = name
                if previous != name { scroll.scrollTo("device-overview", anchor: .top) }
            }
        }
        .background(HakoStyle.background)
        .foregroundStyle(HakoStyle.text)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingOrder = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("设备页面排序设置")
                    .disabled(pages.count < 2)
            }
        }
        .sheet(isPresented: $showingOrder) {
            DevicePageOrderEditor(pages: pages, title: title) { names in
                let current = DeviceCardOrder.arranged(available: capabilities.map(\.name), saved: names)
                let merged = DeviceCardOrder.saving(visible: current, previous: persistedNames)
                if let encoded = try? JSONEncoder().encode(merged) { savedOrder = encoded }
            }
        }
    }

    private func tabBar(_ pages: [ConsoleAgentCapability], selected: String) -> some View {
        let visible = pages.prefix(DeviceCardOrder.tabLimit)
        let overflow = pages.dropFirst(DeviceCardOrder.tabLimit)
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
                        Button { selectedName = page.name } label: {
                            if page.name == selected {
                                Label(title(page), systemImage: "checkmark")
                            } else {
                                Text(title(page))
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
                .accessibilityLabel(overflowSelection.map { "更多页面，当前为\(title($0))" } ?? "更多设备页面")
                .accessibilityAddTraits(overflowSelection == nil ? [] : .isSelected)
            }
        }
        .background(alignment: .bottom) { Rectangle().fill(HakoStyle.line).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("设备页面")
    }

    private func tab(_ page: ConsoleAgentCapability, selected: String, expands: Bool) -> some View {
        Button { selectedName = page.name } label: {
            Text(tabTitle(page)).lineLimit(1).minimumScaleFactor(0.85)
                .frame(minWidth: expands ? nil : 44, maxWidth: expands ? .infinity : nil, minHeight: 44)
                .modifier(DevicePageTabStyle(selected: selected == page.name))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title(page))
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

private struct DevicePageOrderEditor: View {
    let pages: [ConsoleAgentCapability]
    let title: (ConsoleAgentCapability) -> String
    let save: ([String]) -> Void
    @State private var draft: [String]
    @Environment(\.dismiss) private var dismiss

    init(pages: [ConsoleAgentCapability], title: @escaping (ConsoleAgentCapability) -> String,
         save: @escaping ([String]) -> Void) {
        self.pages = pages
        self.title = title
        self.save = save
        _draft = State(initialValue: pages.map(\.name))
    }

    var body: some View {
        let titles = Dictionary(uniqueKeysWithValues: pages.map { ($0.name, title($0)) })
        NavigationStack {
            List {
                Section {
                    // One native reorder group lets the handle cross the fifth position.
                    ForEach(draft, id: \.self) { name in
                        let position = (draft.firstIndex(of: name) ?? 0) + 1
                        HStack(spacing: 10) {
                            Text(position.formatted()).font(.caption.monospacedDigit())
                                .foregroundStyle(HakoStyle.muted).frame(minWidth: 18, alignment: .leading)
                            Text(titles[name] ?? name).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if position > DeviceCardOrder.tabLimit {
                                Text("更多").font(.caption).foregroundStyle(HakoStyle.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                        .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                        .listRowBackground(HakoStyle.card)
                    }
                    .onMove { source, destination in draft.move(fromOffsets: source, toOffset: destination) }
                } header: {
                    Text("长按右侧手柄拖动整行。前五项显示在顶部，其余放入更多菜单。")
                        .textCase(nil)
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(HakoStyle.background)
            .navigationTitle("页面排序")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { save(draft); dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .onChange(of: pages.map(\.name)) { _, names in
            draft = DeviceCardOrder.arranged(available: names, saved: draft)
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
