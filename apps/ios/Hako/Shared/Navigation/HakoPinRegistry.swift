import SwiftUI
import Combine

@MainActor final class HakoPinRegistry {
    private var routes: [String: [String: (HakoPinnedPage) -> AnyView]] = [:]

    func register(applicationID: String, route: String,
                  content: @escaping (HakoPinnedPage) -> AnyView) {
        precondition(routes[applicationID]?[route] == nil, "Pin route already registered")
        routes[applicationID, default: [:]][route] = content
    }

    func contains(_ page: HakoPinnedPage) -> Bool { routes[page.applicationID]?[page.route] != nil }

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
extension EnvironmentValues {
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
