import SwiftUI

@MainActor enum ArcanePinContributor {
    static func register(in registry: HakoPinRegistry) {
        registry.register(applicationID: "容器管理", route: "container") { AnyView(ArcanePinnedContainer(page: $0)) }
    }
}

private struct ArcanePinnedContainer: View {
    let page: HakoPinnedPage
    @ObservedObject private var store = ArcaneStore.shared
    private struct Selection { let environment: ArcaneEnvironment; let container: ArcaneContainer }
    @State private var selection: Selection?
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let route = ArcanePinRoute(page: page), let selection, store.connection?.id == route.connectionID {
                ArcaneContainerView(store: store, environment: selection.environment, container: selection.container, initialTab: route.tab)
            } else if let failure {
                VStack(spacing: 16) {
                    ContentUnavailableView("无法打开固定容器", systemImage: "shippingbox", description: Text(failure))
                    Button("重试") { attempt += 1 }.buttonStyle(HakoActionButtonStyle()).padding(.horizontal, 20)
                }
            } else { ProgressView("正在读取容器…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: (store.connection?.id ?? "") + "|\(attempt)") {
            selection = nil; failure = nil
            store.loadConfiguration()
            guard let route = ArcanePinRoute(page: page), store.connection?.id == route.connectionID else {
                failure = "原 Arcane 连接已变更，请恢复原连接或重新固定容器。"; return
            }
            do {
                let client = try store.client()
                let environments = try await client.environments()
                try Task.checkCancellation()
                guard let environment = environments.first(where: { $0.id == route.environmentID }) else {
                    throw ArcaneFailure(message: "固定容器所属的环境已不可用。")
                }
                let containers = try await client.containers(route.environmentID)
                try Task.checkCancellation()
                guard let container = containers.first(where: { $0.id == route.containerID }) else {
                    throw ArcaneFailure(message: "固定容器已不存在，可以从 Pin 列表中取消固定。")
                }
                guard store.connection?.id == route.connectionID else { throw CancellationError() }
                selection = Selection(environment: environment, container: container)
            } catch is CancellationError { }
            catch { failure = error.localizedDescription }
        }
    }
}
