import SwiftUI
import UIKit

/// Cerno owns its page history so its tab bar stays present on detail pages.
@MainActor final class StockTradeNavigation: ObservableObject {
    struct Route: Identifiable {
        let id = UUID()
        let page: Page
    }
    enum Page {
        case search, history, publications, operations, alerts, health, monitorControl
        case stock(StockTradeRecord, StockTradeRun?)
        case alert(StockTradeRecord, String?)
        case create(StockTradeWorkflowKind)
        case task(StockTradeWorkflowTask)
    }
    @Published private(set) var routes: [Route] = []
    func push(_ page: Page) { dismissKeyboard(); routes.append(.init(page: page)) }
    func pop() { dismissKeyboard(); if !routes.isEmpty { routes.removeLast() } }
    func reset() { dismissKeyboard(); routes = [] }
    private func dismissKeyboard() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
}

struct StockTradeDestination: View {
    @ObservedObject var store: StockTradeStore
    let route: StockTradeNavigation.Route
    let showResults: () -> Void
    let showMonitor: () -> Void
    var body: some View {
        switch route.page {
        case .search: StockTradeSearchView(store: store)
        case .history: StockTradeWorkflowHistory(store: store, showResults: showResults)
        case .publications: StockTradePublications(store: store, showResults: showResults)
        case .operations: StockTradeOperations(store: store, showResults: showResults)
        case .alerts: StockTradeFeedView(store: store, kind: .alerts)
        case .health: StockTradeHealthView(store: store)
        case .monitorControl: StockTradeMonitorManagement(store: store, showMonitor: showMonitor)
        case .stock(let record, let run): StockTradeStockView(store: store, record: record, run: run)
        case .alert(let record, let snapshot): StockTradeAlertView(store: store, record: record, snapshotID: snapshot)
        case .create(let kind): StockTradeWorkflowFormContent(store: store, kind: kind, showResults: showResults)
        case .task(let task): StockTradeWorkflowDetail(store: store, initial: task, showResults: showResults)
        }
    }
}
