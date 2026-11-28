import SwiftUI
import Combine

@MainActor struct HakoPinCollection: Identifiable {
    let id: String
    let title: String
    let content: (@escaping (HakoPinnedPage) -> Void) -> AnyView
}

@MainActor final class HakoPinRegistry {
    private var routes: [String: [String: (HakoPinnedPage) -> AnyView]] = [:]
    private var previewNavigation: [String: Set<String>] = [:]
    private var icons: [String: [String: (HakoPinnedPage) -> AnyView]] = [:]
    private(set) var collections: [HakoPinCollection] = []

    func registerCollection(id: String, title: String,
                            content: @escaping (@escaping (HakoPinnedPage) -> Void) -> AnyView) {
        precondition(!collections.contains { $0.id == id }, "Pin collection already registered")
        collections.append(HakoPinCollection(id: id, title: title, content: content))
    }

    func register(applicationID: String, route: String, providesPreviewNavigation: Bool = false,
                  icon: ((HakoPinnedPage) -> AnyView)? = nil,
                  content: @escaping (HakoPinnedPage) -> AnyView) {
        precondition(routes[applicationID]?[route] == nil, "Pin route already registered")
        routes[applicationID, default: [:]][route] = content
        if providesPreviewNavigation { previewNavigation[applicationID, default: []].insert(route) }
        if let icon { icons[applicationID, default: [:]][route] = icon }
    }

    func icon(for page: HakoPinnedPage) -> AnyView {
        icons[page.applicationID]?[page.route]?(page) ?? AnyView(
            HakoApplicationIcon(application: HakoApplications.Application(rawValue: page.applicationID)))
    }

    func contains(_ page: HakoPinnedPage) -> Bool { routes[page.applicationID]?[page.route] != nil }
    func providesPreviewNavigation(for page: HakoPinnedPage) -> Bool {
        previewNavigation[page.applicationID]?.contains(page.route) == true
    }

    func content(for page: HakoPinnedPage) -> AnyView {
        routes[page.applicationID]?[page.route]?(page) ?? AnyView(
            ContentUnavailableView("页面不可用", systemImage: "pin.slash",
                description: Text("此页面已不再提供，可以从 Pin 列表中移除。")))
    }
}

@MainActor final class HakoPinStore: ObservableObject {
    static let shared = HakoPinStore()
    static let storageKey = "hako.pinnedPages"
    @Published private(set) var pages: [HakoPinnedPage]
    @Published var error: String?
    private var values: HakoPinnedPages
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        values = HakoPinnedPages(data: defaults.data(forKey: Self.storageKey) ?? Data())
        pages = values.pages
    }

    func contains(_ page: HakoPinnedPage) -> Bool { pages.contains { $0.id == page.id } }
    func pin(_ page: HakoPinnedPage) { update { $0.pin(page) } }
    func replace(_ id: String, with page: HakoPinnedPage) { update { $0.replace(id, with: page) } }
    func remove(_ ids: Set<String>) { update { $0.remove(ids) } }
    func move(from offsets: IndexSet, to destination: Int) { update { $0.move(from: offsets, to: destination) } }
    func move(from offsets: IndexSet, to destination: Int, among visibleIDs: Set<String>) {
        update { $0.move(from: offsets, to: destination, among: visibleIDs) }
    }

    private func update(_ change: (inout HakoPinnedPages) -> Void) {
        var next = values
        change(&next)
        do {
            let data = try next.encoded()
            defaults.set(data, forKey: Self.storageKey)
            values = next; pages = next.pages; error = nil
        } catch { self.error = "无法保存 Pin 列表：" + error.localizedDescription }
    }
}

private struct HakoPinPreviewKey: EnvironmentKey { static let defaultValue = false }
private struct HakoPinEnterKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    var hakoPinEnter: (() -> Void)? {
        get { self[HakoPinEnterKey.self] }
        set { self[HakoPinEnterKey.self] = newValue }
    }
    var hakoPinPreview: Bool {
        get { self[HakoPinPreviewKey.self] }
        set { self[HakoPinPreviewKey.self] = newValue }
    }
}

struct HakoPinButton: View {
    let page: HakoPinnedPage
    @ObservedObject private var pins = HakoPinStore.shared

    var body: some View {
        Button {
            if pins.contains(page) { pins.remove([page.id]) }
            else { pins.pin(page) }
        } label: {
            Label(pins.contains(page) ? "取消固定" : "加入 Pin",
                  systemImage: pins.contains(page) ? "pin.slash" : "pin")
        }
    }
}
