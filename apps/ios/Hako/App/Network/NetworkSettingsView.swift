import SwiftUI
import CoreLocation

struct NetworkSettingsView: View {
    @ObservedObject private var network = AppNetworkService.shared
    @StateObject private var location = NetworkLocationAuthorization()
    @Environment(\.scenePhase) private var scenePhase
    @State private var adding = false
    @State private var error: String?
    @State private var editing: LocalNetworkApplication?
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
                if network.configuration.ssids.isEmpty { Text("尚未登记 Wi-Fi").foregroundStyle(.secondary) }
                ForEach(Array(network.configuration.ssids.enumerated()), id: \.offset) { _, ssid in
                    HStack {
                        Label(ssid, systemImage: "wifi")
                        Spacer()
                        Button(role: .destructive) {
                            var draft = network.configuration
                            draft.ssids.removeAll { $0.utf8.elementsEqual(ssid.utf8) }
                            do { try network.save(draft) } catch { self.error = error.localizedDescription }
                        } label: { Image(systemName: "trash").foregroundStyle(.red).frame(width: 44, height: 44) }
                            .buttonStyle(.borderless).accessibilityLabel("移除内网 Wi-Fi \(ssid)")
                    }.alignmentGuide(.listRowSeparatorLeading) { _ in 0 }.alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
            } header: { Text("内网 Wi-Fi") } footer: {
                Text("只有连接到已登记的 Wi-Fi，子应用才会使用配置的局域网地址。")
            }
            Section("子应用局域网地址") {
                ForEach(LocalNetworkApplication.allCases) { application in
                    Button { editing = application } label: {
                        HStack {
                            Text(application.title).foregroundStyle(.primary)
                            Spacer()
                            Text(network.configuration.endpoints[application.rawValue]?.address ?? "未配置").foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }.alignmentGuide(.listRowSeparatorLeading) { _ in 0 }.alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
            }
        }
        .navigationTitle("网络配置").navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(HakoStyle.background)
        .sheet(item: $editing) { LocalNetworkEndpointEditor(application: $0) }
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
        guard !network.configuration.ssids.contains(where: { $0.utf8.elementsEqual(ssid.utf8) }) else {
            error = "当前 Wi-Fi 已在内网列表中。"; return
        }
        var draft = network.configuration; draft.ssids.append(ssid)
        do { try network.save(draft) } catch { self.error = error.localizedDescription }
    }
}

private struct LocalNetworkEndpointEditor: View {
    let application: LocalNetworkApplication
    @ObservedObject private var network = AppNetworkService.shared
    @Environment(\.dismiss) private var dismiss
    @State private var ip = ""
    @State private var port = ""
    @State private var original: LocalNetworkEndpoint?
    @State private var error: String?
    private var endpoint: LocalNetworkEndpoint? { Int(port).flatMap { LocalNetworkEndpoint(ip: ip, port: $0) } }
    private var changed: Bool { ip != (original?.ip ?? "") || port != (original.map({ String($0.port) }) ?? "") }
    var body: some View {
        SettingsSheet(title: application.title + "局域网地址", hasChanges: changed,
                      saveEnabled: endpoint != nil, onSave: save) {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("局域网 IP").font(.subheadline).foregroundStyle(.secondary)
                        TextField("例如 192.168.0.10", text: $ip).keyboardType(.URL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("局域网 IP")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("端口").font(.subheadline).foregroundStyle(.secondary)
                        TextField("Agent 的直连端口", text: $port).keyboardType(.numberPad).accessibilityLabel("端口")
                    }
                } footer: { Text("填写运行 Windows Agent 的电脑地址及直连端口。") }
                if let error { Text(error).foregroundStyle(.red) }
                if original != nil {
                    HakoDeleteButton(title: "清除局域网地址") {
                        var draft = network.configuration; draft.endpoints[application.rawValue] = nil
                        do { try network.save(draft); dismiss() } catch { self.error = error.localizedDescription }
                    }.listRowBackground(Color.clear)
                }
            }
        }.onAppear {
            original = network.configuration.endpoints[application.rawValue]
            ip = original?.ip ?? ""; port = original.map { String($0.port) } ?? ""
        }
    }
    private func save() {
        guard let endpoint else { return }
        var draft = network.configuration; draft.endpoints[application.rawValue] = endpoint
        do { try network.save(draft); dismiss() } catch { self.error = error.localizedDescription }
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
