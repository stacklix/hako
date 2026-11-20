import SwiftUI
import CoreLocation

struct NetworkSettingsView: View {
    @ObservedObject private var network = AppNetworkService.shared
    @StateObject private var location = NetworkLocationAuthorization()
    @Environment(\.scenePhase) private var scenePhase
    @State private var adding = false
    @State private var error: String?
    private var canAdd: Bool { adding && location.status != .notDetermined }

    var body: some View {
        Form {
            Section("网络检测") {
                LabeledContent("当前 Wi-Fi", value: network.currentSSID ?? "未获取")
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }.alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                LabeledContent("网络环境", value: network.isLocal ? "局域网" : "外网或未识别 Wi-Fi")
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }.alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                Button {
                    adding = true; location.requestIfNeeded()
                } label: {
                    HStack {
                        Label("添加当前 Wi-Fi", systemImage: "plus.circle")
                        Spacer()
                        if adding { ProgressView() }
                    }
                }.disabled(adding)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }.alignmentGuide(.listRowSeparatorTrailing) { $0.width }
            }
            Section {
                if network.ssids.isEmpty { Text("尚未登记 Wi-Fi").foregroundStyle(.secondary) }
                ForEach(Array(network.ssids.enumerated()), id: \.offset) { _, ssid in
                    HStack {
                        Label(ssid, systemImage: "wifi")
                        Spacer()
                        Button(role: .destructive) {
                            var draft = network.ssids
                            draft.removeAll { $0.utf8.elementsEqual(ssid.utf8) }
                            do { try network.save(ssids: draft) } catch { self.error = error.localizedDescription }
                        } label: { Image(systemName: "trash").foregroundStyle(.red).frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).accessibilityLabel("移除内网 Wi-Fi \(ssid)")
                    }.alignmentGuide(.listRowSeparatorLeading) { _ in 0 }.alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
            } header: { Text("内网 Wi-Fi") } footer: {
                Text("只有连接到已登记的 Wi-Fi，子应用才会使用配置的局域网地址。")
            }
        }
        .navigationTitle("网络配置").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(HakoStyle.background)
        .task(id: scenePhase == .active) { if scenePhase == .active { await network.refresh() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { adding = false } }
        .task(id: canAdd) { if canAdd { await addCurrentWiFi() } }
        .alert("网络配置", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func addCurrentWiFi() async {
        defer { adding = false }
        guard location.hasPreciseLocation else {
            error = "请在系统设置中允许 Hako 在使用期间访问位置，并打开「精确位置」。"; return
        }
        await network.refresh()
        guard !Task.isCancelled else { return }
        guard network.usesWiFi, let ssid = network.currentSSID, !ssid.isEmpty else {
            error = "未能读取 Wi-Fi 名称，请连接内网 Wi-Fi 后重试。"; return
        }
        guard !network.ssids.contains(where: { $0.utf8.elementsEqual(ssid.utf8) }) else {
            error = "当前 Wi-Fi 已在内网列表中。"; return
        }
        var draft = network.ssids; draft.append(ssid)
        do { try network.save(ssids: draft) } catch { self.error = error.localizedDescription }
    }
}

@MainActor private final class NetworkLocationAuthorization: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published private(set) var status: CLAuthorizationStatus = .notDetermined
    override init() { super.init(); status = manager.authorizationStatus; manager.delegate = self }
    var hasPreciseLocation: Bool {
        (manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways)
            && manager.accuracyAuthorization == .fullAccuracy
    }
    func requestIfNeeded() { if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() } }
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in guard let self else { return }; self.status = self.manager.authorizationStatus }
    }
}
