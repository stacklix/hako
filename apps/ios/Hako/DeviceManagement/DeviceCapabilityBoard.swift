import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DeviceCapabilityBoard<Overview: View, Content: View>: View {
    let capabilities: [ConsoleAgentCapability]
    let emptyMessage: String
    let title: (ConsoleAgentCapability) -> String
    let icon: (ConsoleAgentCapability) -> String
    let summary: (ConsoleAgentCapability) -> String
    let overview: () -> Overview
    let content: (ConsoleAgentCapability) -> Content
    @AppStorage private var savedOrder: Data
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var contentSpace
    @State private var search = ""
    @State private var expandedName: String?
    @State private var scrollPosition = ScrollPosition()
    @State private var scrollGeometry = DeviceCardScrollGeometry()
    @State private var measuredContentHeight: CGFloat = 0
    @State private var cardGeometry: [String: DeviceCardFrame] = [:]
    @State private var returnBookmark: DeviceCardBookmark?
    @State private var scrollRequest: ScrollRequest?
    @State private var draggedName: String?
    @State private var liveOrder: [String]?
    @State private var dragBookmark: DeviceCardBookmark?
    @State private var dragPoint: CGPoint?
    @State private var lastDragTarget: String?

    init(capabilities: [ConsoleAgentCapability], storageKey: String, emptyMessage: String,
         title: @escaping (ConsoleAgentCapability) -> String,
         icon: @escaping (ConsoleAgentCapability) -> String,
         summary: @escaping (ConsoleAgentCapability) -> String,
         @ViewBuilder overview: @escaping () -> Overview,
         @ViewBuilder content: @escaping (ConsoleAgentCapability) -> Content) {
        self.capabilities = capabilities
        self.emptyMessage = emptyMessage
        self.title = title
        self.icon = icon
        self.summary = summary
        self.overview = overview
        self.content = content
        _savedOrder = AppStorage(wrappedValue: Data(), storageKey)
    }

    private var persistedNames: [String] { (try? JSONDecoder().decode([String].self, from: savedOrder)) ?? [] }
    private var orderedNames: [String] {
        DeviceCardOrder.arranged(available: capabilities.map(\.name), saved: liveOrder ?? persistedNames)
    }
    private var visibleCapabilities: [ConsoleAgentCapability] {
        let byName = Dictionary(capabilities.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return orderedNames.compactMap { byName[$0] }.filter {
            term.isEmpty || title($0).localizedCaseInsensitiveContains(term) || $0.name.localizedCaseInsensitiveContains(term)
        }
    }
    private var frames: [String: CGRect] { cardGeometry.mapValues(\.rect) }
    private var animation: Animation? { reduceMotion ? nil : .smooth(duration: 0.24) }
    private var dragEdge: Int {
        guard draggedName != nil, let point = dragPoint, scrollGeometry.viewportHeight > 0 else { return 0 }
        if point.y < 52 { return -1 }
        if point.y > scrollGeometry.viewportHeight - 52 { return 1 }
        return 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                overview()
                if !capabilities.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索名称或命令", text: $search)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("搜索设备命令")
                    }
                    .padding(12).background(Color(uiColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                }
                if visibleCapabilities.isEmpty {
                    Text(capabilities.isEmpty ? emptyMessage : "没有匹配的命令")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 32)
                } else {
                    DeviceCardLayout(columns: dynamicTypeSize.isAccessibilitySize ? 1 : 2) {
                        ForEach(visibleCapabilities) { capability in
                            capabilityCard(capability)
                                .layoutValue(key: DeviceCardExpandedKey.self, value: expandedName == capability.name)
                                .background {
                                    GeometryReader { proxy in
                                        Color.clear.preference(key: DeviceCardFramesKey.self,
                                            value: [capability.name: DeviceCardFrame(rect: proxy.frame(in: .named(contentSpace)),
                                                expanded: expandedName == capability.name,
                                                order: orderedNames.firstIndex(of: capability.name) ?? 0)])
                                    }
                                }
                        }
                    }
                }
            }
            .padding(20)
            .coordinateSpace(name: contentSpace)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                measuredContentHeight = height
                applyScrollRequest()
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollPosition($scrollPosition)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: DeviceCardScrollGeometry.self) { value in
            DeviceCardScrollGeometry(offset: value.contentOffset.y + value.contentInsets.top,
                viewportHeight: max(0, value.containerSize.height - value.contentInsets.top - value.contentInsets.bottom),
                contentHeight: value.contentSize.height)
        } action: { _, value in
            scrollGeometry = value
            if draggedName != nil { updateDragTarget() }
            applyScrollRequest()
        }
        .onScrollPhaseChange { _, phase in
            if phase == .tracking || phase == .interacting { scrollRequest = nil }
        }
        .onPreferenceChange(DeviceCardFramesKey.self) { value in
            cardGeometry = value
            applyScrollRequest()
        }
        .onDrop(of: [UTType.plainText], delegate: DeviceCardDropTarget(
            accepts: { draggedName != nil }, entered: {}))
        .onChange(of: search) { _, _ in
            scrollRequest = nil
            expandedName = nil
            returnBookmark = nil
        }
        .onChange(of: capabilities.map(\.name)) { _, names in
            if let draggedName, !names.contains(draggedName) { finishDrag(committed: false) }
            if let expandedName, !names.contains(expandedName) {
                self.expandedName = nil
                returnBookmark = nil
                scrollRequest = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { finishDrag(committed: false) }
        }
        .onDisappear {
            finishDrag(committed: false)
            scrollRequest = nil
        }
        .task(id: dragEdge) {
            let edge = dragEdge
            guard edge != 0 else { return }
            while !Task.isCancelled, draggedName != nil {
                do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
                guard !Task.isCancelled, draggedName != nil else { return }
                let next = scrollGeometry.clamped(scrollGeometry.offset + CGFloat(edge) * 10)
                guard abs(next - scrollGeometry.offset) > 0.5 else { return }
                scrollPosition.scrollTo(y: next)
            }
        }
    }

    private func capabilityCard(_ capability: ConsoleAgentCapability) -> some View {
        let expanded = expandedName == capability.name
        return VStack(alignment: .leading, spacing: 0) {
            DeviceCardDragHeader(name: capability.name,
                accessibilityTitle: title(capability),
                accessibilitySummary: summary(capability) + (expanded ? "，已展开" : "，已收起"),
                canDrag: capabilities.count > 1 && draggedName == nil,
                activate: { toggle(capability.name) }, begin: { beginDrag(capability.name) },
                moved: { updateDragLocation($0, source: capability.name) },
                ended: { committed in finishDrag(committed: committed) },
                moveBy: { moveBy($0, name: capability.name) }) {
                    DeviceCardHeader(title: title(capability), icon: icon(capability),
                        subtitle: expanded ? capability.name + " · v\(capability.version)" : summary(capability), expanded: expanded)
                        .environment(\.dynamicTypeSize, dynamicTypeSize).environment(\.colorScheme, colorScheme)
                }
            if expanded {
                VStack(alignment: .leading, spacing: 18) {
                    Divider()
                    content(capability)
                    Button { toggle(capability.name) } label: {
                        Label("收起", systemImage: "chevron.up")
                            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.plain).accessibilityLabel("收起\(title(capability))并恢复浏览位置")
                }.padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17))
        .overlay {
            if draggedName == capability.name {
                RoundedRectangle(cornerRadius: 17).strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
            }
        }
        .onDrop(of: [UTType.plainText], delegate: DeviceCardDropTarget(
            accepts: { draggedName != nil }, entered: { moveDraggedCard(to: capability.name) }))
    }

    private func bookmark() -> DeviceCardBookmark { .capture(frames: frames, offset: scrollGeometry.offset) }

    private func toggle(_ name: String) {
        guard draggedName == nil else { return }
        let closing = expandedName == name
        let operation: ScrollOperation
        if closing {
            operation = .restore(returnBookmark ?? bookmark())
            returnBookmark = nil
        } else {
            // Keep the bookmark from the collapsed board when switching cards.
            if expandedName == nil { returnBookmark = bookmark() }
            operation = .fit(name)
        }
        let request = ScrollRequest(operation: operation, expectedExpanded: closing ? nil : name)
        scrollRequest = request
        withAnimation(animation, completionCriteria: .removed) {
            expandedName = closing ? nil : name
        } completion: {
            guard scrollRequest?.id == request.id else { return }
            scrollRequest?.ready = true
            applyScrollRequest()
        }
    }

    private func applyScrollRequest() {
        guard let request = scrollRequest, request.ready, scrollGeometry.viewportHeight > 0,
              abs(scrollGeometry.contentHeight - measuredContentHeight) < 1,
              cardGeometry.sorted(by: { $0.value.order < $1.value.order }).map(\.key) == visibleCapabilities.map(\.name),
              cardGeometry.values.filter(\.expanded).count == (request.expectedExpanded == nil ? 0 : 1) else { return }
        if let expected = request.expectedExpanded, cardGeometry[expected]?.expanded != true { return }
        let offset: CGFloat?
        switch request.operation {
        case .fit(let name):
            guard let rect = frames[name] else { return }
            offset = scrollGeometry.fitting(rect)
        case .restore(let bookmark): offset = bookmark.restoredOffset(frames: frames, geometry: scrollGeometry)
        }
        scrollRequest = nil
        if let offset {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) { scrollPosition.scrollTo(y: offset) }
        }
    }

    private func beginDrag(_ name: String) {
        guard draggedName == nil else { return }
        scrollRequest = nil
        dragBookmark = bookmark()
        liveOrder = orderedNames
        draggedName = name
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func updateDragLocation(_ point: CGPoint, source: String) {
        guard draggedName == source, let frame = frames[source] else { return }
        dragPoint = CGPoint(x: frame.minX + point.x, y: frame.minY + point.y - scrollGeometry.offset)
        updateDragTarget()
    }

    private func updateDragTarget() {
        guard let point = dragPoint else { return }
        let contentPoint = CGPoint(x: point.x, y: point.y + scrollGeometry.offset)
        if let target = frames.first(where: { $0.value.contains(contentPoint) })?.key { moveDraggedCard(to: target) }
    }

    private func moveDraggedCard(to target: String) {
        guard let source = draggedName else { return }
        if source == target { lastDragTarget = nil; return }
        guard lastDragTarget != target,
              capabilities.contains(where: { $0.name == target }) else { return }
        let moved = DeviceCardOrder.moving(source, to: target, in: orderedNames)
        guard moved != orderedNames else { return }
        lastDragTarget = target
        withAnimation(animation) { liveOrder = moved }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func finishDrag(committed: Bool) {
        guard draggedName != nil else { return }
        let restore = dragBookmark
        if committed, let liveOrder {
            saveOrder(liveOrder)
        }
        draggedName = nil
        dragPoint = nil
        dragBookmark = nil
        lastDragTarget = nil
        liveOrder = nil
        if !committed, let restore {
            let request = ScrollRequest(operation: .restore(restore), expectedExpanded: expandedName, ready: true)
            scrollRequest = request
            // Geometry preferences apply this after the original order has laid out.
            applyScrollRequest()
        }
    }

    private func moveBy(_ distance: Int, name: String) -> Bool {
        guard draggedName == nil, let index = orderedNames.firstIndex(of: name),
              orderedNames.indices.contains(index + distance) else { return false }
        let saved = bookmark()
        let target = orderedNames[index + distance]
        withAnimation(animation) { saveOrder(DeviceCardOrder.moving(name, to: target, in: orderedNames)) }
        scrollRequest = ScrollRequest(operation: .restore(saved), expectedExpanded: expandedName, ready: true)
        return true
    }

    private func saveOrder(_ names: [String]) {
        if let data = try? JSONEncoder().encode(DeviceCardOrder.saving(visible: names, previous: persistedNames)) { savedOrder = data }
    }

    private enum ScrollOperation { case fit(String), restore(DeviceCardBookmark) }
    private struct ScrollRequest {
        let id = UUID()
        let operation: ScrollOperation
        let expectedExpanded: String?
        var ready = false
    }
}

private struct DeviceCardFrame: Equatable { let rect: CGRect; let expanded: Bool; let order: Int }
private struct DeviceCardFramesKey: PreferenceKey {
    static let defaultValue: [String: DeviceCardFrame] = [:]
    static func reduce(value: inout [String: DeviceCardFrame], nextValue: () -> [String: DeviceCardFrame]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct DeviceCardExpandedKey: LayoutValueKey { static let defaultValue = false }
private struct DeviceCardLayout: Layout {
    var columns: Int
    private let spacing: CGFloat = 12
    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let columnWidth = max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
        let expanded = subviews.map { $0[DeviceCardExpandedKey.self] }
        let heights = subviews.enumerated().map { index, view in
            view.sizeThatFits(ProposedViewSize(width: expanded[index] ? width : columnWidth, height: nil)).height
        }
        return DeviceCardPlacement.frames(width: width, columns: columns, spacing: spacing, heights: heights, expanded: expanded)
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? 350
        return CGSize(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placements = frames(width: bounds.width, subviews: subviews)
        for (index, frame) in placements.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }
}

private struct DeviceCardHeader: View {
    let title: String
    let icon: String
    let subtitle: String
    let expanded: Bool
    private var symbol: some View {
        Image(systemName: icon).font(.body).frame(width: 32, height: 32)
            .background(Color(uiColor: .tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 9))
    }
    private var chevron: some View {
        Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
    }
    private var text: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(expanded ? .caption2.monospaced() : .caption)
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    var body: some View {
        Group {
            if expanded {
                HStack(spacing: 10) { symbol; text; chevron }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack { symbol; Spacer(); chevron }
                    text
                }.frame(minHeight: 92, alignment: .topLeading)
            }
        }.padding(14).foregroundStyle(.primary)
    }
}

private struct DeviceCardDropTarget: DropDelegate {
    let accepts: () -> Bool
    let entered: () -> Void
    func validateDrop(info: DropInfo) -> Bool { accepts() }
    func dropEntered(info: DropInfo) { if accepts() { entered() } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: accepts() ? .move : .forbidden) }
    func performDrop(info: DropInfo) -> Bool { accepts() }
}
