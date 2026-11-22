import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private actor RouterTestNetwork {
    var local: Bool
    init(local: Bool) { self.local = local }
    func setLocal(_ value: Bool) { local = value }
}

private final class RouterMockProtocol: URLProtocol {
    nonisolated(unsafe) static var handle: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var expectedProxy: String?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            precondition(request.httpMethod == "POST", "Network classification must not probe router HTTP pages")
            precondition(request.value(forHTTPHeaderField: "X-Proxy") == Self.expectedProxy,
                         "All logins, reads, mutations and retries must keep the selected route")
            let (status, data) = try Self.handle!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                         httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}

@main struct RouterTests {
    static func expectFailure(_ body: () throws -> Void) {
        do { try body(); fatalError("Expected validation failure") } catch { }
    }
    // Synthetic wire fixture: these tests do not claim authenticated hardware verification.
    static func fixture() -> [String: Any] {
        ["error_code": 0,
         "network": ["lan": ["ipaddr": "192.168.0.1", "netmask": "255.255.255.0"]],
         "system": ["sys_mode": ["mode": "0"]],
         "hosts_info": ["offline_host": [], "blocked_host": [], "online_host": [
            ["host_1": ["mac": "02-11-22-33-44-55", "ip": "192.168.0.10", "hostname": "%E7%94%B5%E8%84%91", "type": "0", "up_speed": "1024", "down_speed": 2048]]
         ]],
         "ip_mac_bind": ["user_bind": [
            ["user_bind_1": ["mac": "02-aa-bb-cc-dd-ee", "ip": "192.168.0.20", "hostname": "NAS"]]
         ]]]
    }

    static func main() async throws {
        let snapshot = try RouterSnapshot(fixture())
        assert(snapshot.devices.count == 1 && snapshot.devices[0].name == "电脑")
        assert(snapshot.devices[0].connection == "有线" && snapshot.devices[0].download == 2048)
        assert(snapshot.bindings[0].mac == "02-AA-BB-CC-DD-EE")
        var orderedFixture = fixture()
        orderedFixture["hosts_info"] = ["offline_host": [], "blocked_host": [], "online_host": [
            ["host_1": ["mac": "02-11-22-33-44-01", "ip": "192.168.0.11", "hostname": "Beta", "type": "0"]],
            ["host_2": ["mac": "02-11-22-33-44-02", "ip": "192.168.0.12", "hostname": "Z-local", "type": "0", "is_cur_host": "1"]],
            ["host_3": ["mac": "02-11-22-33-44-03", "ip": "192.168.0.13", "hostname": "Alpha", "type": "0"]]
        ]]
        let ordered = try RouterSnapshot(orderedFixture)
        assert(ordered.onlineDevices.map(\.name) == ["Z-local", "Alpha", "Beta"])
        assert(ordered.onlineDevices.first?.isCurrent == true)
        assert(RouterPassword.encode("admin") == "WaQ7xbhc9TefbwK")
        assert(RouterAddress.ipv4("192.168.000.1") == nil)
        assert(RouterAddress.ipv4("256.1.1.1") == nil)
        for ip in ["127.0.0.1", "8.8.8.8", "172.32.0.1", "192.169.0.1", "192.168.0.1/path"] {
            expectFailure { _ = try RouterConnection(address: ip, password: "admin").normalized() }
        }
        for ip in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.0.1"] {
            _ = try RouterConnection(address: ip, password: "admin").normalized()
        }
        for mac in ["ff:ff:ff:ff:ff:ff", "00:00:00:00:00:00", "01:11:22:33:44:55", "00:11:22:33:44:5g"] {
            expectFailure { _ = try RouterAddress.mac(mac) }
        }
        let normalizedMAC = try RouterAddress.mac("02:11:22:33:44:55")
        assert(normalizedMAC == "02-11-22-33-44-55")
        for ip in ["192.168.0.0", "192.168.0.255", "192.168.0.1", "192.168.1.30", "192.168.0.20", "192.168.0.10"] {
            expectFailure { _ = try RouterBindingDraft(ip: ip, mac: "02:88:88:88:88:88").validated(in: snapshot) }
        }
        let draft = try RouterBindingDraft(ip: "192.168.0.30", mac: "02:88:88:88:88:88", name: "电视").validated(in: snapshot)
        expectFailure { _ = try RouterBindingDraft(ip: "192.168.0.30", mac: "02:aa:bb:cc:dd:ee").validated(in: snapshot) }
        _ = try RouterBindingDraft(ip: "192.168.0.20", mac: "02:aa:bb:cc:dd:ee", name: "NAS").validated(in: snapshot, replacing: "user_bind_1")
        var malformed = fixture()
        malformed["ip_mac_bind"] = ["user_bind": "not a table"]
        expectFailure { _ = try RouterSnapshot(malformed) }
        malformed = fixture(); malformed["network"] = ["lan": ["ipaddr": "192.168.0.1", "netmask": "255.0.255.0"]]
        expectFailure { _ = try RouterSnapshot(malformed) }
        assert(!RouterSnapshot.validSection("user_bind_1/anything"))
        var relayFixture = fixture()
        relayFixture["system"] = ["sys_mode": ["mode": "1"]]
        assert(tryValue { try RouterSnapshot(relayFixture).routerMode } == false)
        var stateFixture = fixture()
        stateFixture["hosts_info"] = ["offline_host": [], "online_host": [
            ["host_info_1": ["mac": "02-11-22-33-44-55", "ip": "192.168.0.10", "hostname": "电脑", "type": "0"]]
        ], "blocked_host": [["host_info_1": ["mac": "02-11-22-33-44-55", "ip": "192.168.0.10", "hostname": "电脑", "type": "0", "blocked": "1"]]]]
        let merged = try RouterSnapshot(stateFixture)
        assert(merged.devices.count == 1 && merged.blockedDevices.count == 1 && merged.onlineDevices.isEmpty)
        let wireless = try RouterJSON(["wireless": ["wlan_bs": ["bs_enable": "0"], "wlan_host_2g": ["ssid": "Old", "enable": "1", "key": "testpass1", "encryption": "1"]]])
        let wifiChange = try RouterConfigurationChange.wifi(section: "wlan_host_2g", enabled: true, ssid: "新网络", password: "testpass2", original: wireless["wireless"]["wlan_host_2g"])
        _ = try wifiChange.payload(current: wireless, snapshot: snapshot)
        let changedWireless = try RouterJSON(["wireless": ["wlan_bs": ["bs_enable": "1"], "wlan_host_2g": ["ssid": "Old"]]])
        expectFailure { _ = try wifiChange.payload(current: changedWireless, snapshot: snapshot) }
        expectFailure { _ = try RouterConfigurationChange.wifi(section: "wlan_host_2g", enabled: true, ssid: "A", password: "short", original: .null) }
        let noForward = try RouterJSON(["firewall": ["redirect": []]])
        let forwardDraft = RouterForwardDraft(ip: "192.168.0.30", externalStart: "443", externalEnd: "", internalPort: "8443", proto: "tcp", wan: "0")
        let forwardChange = try forwardDraft.change(current: noForward, snapshot: snapshot)
        assert(forwardChange.section == "redirect_1")
        expectFailure { _ = try forwardChange.payload(current: noForward, snapshot: RouterSnapshot(relayFixture)) }
        let occupiedForward = try RouterJSON(["firewall": ["redirect": [["redirect_1": ["src_dport_start": "440", "src_dport_end": "450", "proto": "all", "wan_port": "0"]]]]])
        expectFailure { _ = try forwardDraft.change(current: occupiedForward, snapshot: snapshot) }
        let noSchedules = try RouterJSON(["time_switch": ["general": ["enable": "0"], "time_switch": []]])
        let scheduleChange = try RouterScheduleDraft(name: "夜间", start: "23:30", end: "07:00").change(resource: .wirelessSchedule, current: noSchedules)
        assert(scheduleChange.section == "time_switch_1" && scheduleChange.fields["mon"] == "1")
        expectFailure { _ = try RouterScheduleDraft(name: "无日期", days: Array(repeating: false, count: 7)).change(resource: .wirelessSchedule, current: noSchedules) }
        assert(!RouterScheduleDraft.validTime("24:00") && !RouterScheduleDraft.validTime("7:00") && RouterScheduleDraft.validTime("07:00"))
        let portData = try RouterJSON(["port_manage": ["dev_info": [["mac": "02-11-22-33-44-55", "phy_info": [["phy": "0", "type": "SFP", "role": "wan1", "status": "1", "nego_rate": "1000MF"]]]]]])
        assert(RouterPort.all(portData).first?.rate == "1 Gbps · 全双工")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RouterMockProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let connection = RouterConnection(password: "admin")
        for route in RouterRoute.allCases {
            let network = RouterTestNetwork(local: route == .direct)
            RouterMockProtocol.expectedProxy = route == .sora ? "192.168.0.1:80" : nil
            let client = try RouterClient(connection: connection, isLocal: { await network.local }, session: session)
            var requests: [[String: Any]] = []
            var paths: [String] = []
            RouterMockProtocol.handle = { request in
                paths.append(request.url!.path)
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                requests.append(body)
                let method = body["method"] as! String
                if body["login"] != nil {
                    assert(request.url!.path == "/")
                    assert((body["login"] as! [String: String])["password"] == RouterPassword.encode("admin"))
                    return (200, try JSONSerialization.data(withJSONObject: ["error_code": 0, "stok": "test-token"]))
                }
                assert(request.url!.path == "/stok=test-token/ds")
                if method == "get" { return (200, try JSONSerialization.data(withJSONObject: fixture())) }
                return (200, Data("{\"error_code\":0}".utf8))
            }
            _ = try await client.read()
            let selectedRoute = await client.currentRoute()
            assert(selectedRoute == route)
            try await client.save(draft, replacing: nil)
            let added = requests.last!["ip_mac_bind"] as! [String: Any]
            assert(requests.last!["method"] as! String == "add")
            assert(added["table"] as! String == "user_bind")
            assert(added["name"] as! String == "user_bind_2")
            assert((added["para"] as! [String: String])["mac"] == draft.mac)
            assert((added["para"] as! [String: String])["hostname"] == "%E7%94%B5%E8%A7%86")
            try await client.remove(snapshot.bindings[0])
            assert(requests.last!["method"] as! String == "delete")
            assert((requests.last!["ip_mac_bind"] as! [String: Any])["name"] as! [String] == ["user_bind_1"])
            let beforeRelay = requests.count
            RouterMockProtocol.handle = { _ in (200, try JSONSerialization.data(withJSONObject: relayFixture)) }
            do { try await client.save(draft, replacing: nil); fatalError("Expected router-mode restriction") }
            catch { assert(requests.count == beforeRelay) }

            var mutations = 0
            RouterMockProtocol.handle = { request in
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                if body["method"] as? String == "set" {
                    mutations += 1
                    let fields = (body["wireless"] as! [String: Any])["wlan_host_2g"] as! [String: String]
                    assert(fields["ssid"] == "%E6%96%B0%E7%BD%91%E7%BB%9C")
                    return (200, Data("{\"error_code\":0}".utf8))
                }
                var result = body["wireless"] != nil ? wireless.raw as! [String: Any] : fixture()
                result["error_code"] = 0
                return (200, try JSONSerialization.data(withJSONObject: result))
            }
            try await client.apply(wifiChange)
            assert(mutations == 1)

            // Expired reads reauthenticate once. An invalid password is tried once.
            var attempts = 0
            RouterMockProtocol.handle = { request in
                attempts += 1
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                if attempts == 1 { return (200, Data("{\"error_code\":-40401}".utf8)) }
                if body["login"] != nil { return (200, Data("{\"error_code\":0,\"stok\":\"new-token\"}".utf8)) }
                return (200, try JSONSerialization.data(withJSONObject: fixture()))
            }
            _ = try await client.read()
            assert(attempts == 3)
            let badClient = try RouterClient(connection: connection, isLocal: { await network.local }, session: session)
            attempts = 0
            RouterMockProtocol.handle = { _ in attempts += 1; return (200, Data("{\"error_code\":-40401}".utf8)) }
            do { _ = try await badClient.read(); fatalError("Expected authentication failure") } catch { assert(attempts == 1) }

            // A lost write response must never cause an automatic second write.
            var writes = 0
            RouterMockProtocol.handle = { request in
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                if body["method"] as? String == "add" { writes += 1; throw URLError(.timedOut) }
                return (200, try JSONSerialization.data(withJSONObject: fixture()))
            }
            do { try await client.save(draft, replacing: nil); fatalError("Expected ambiguous write") }
            catch let error as RouterFailure { assert(error.outcomeUnknown && writes == 1) }
            let symbolClient = try RouterClient(connection: connection, isLocal: { await network.local }, session: session)
            let symbolToken = "a+b/c?d#e%f|[]"
            let encodedToken = "a%2Bb%2Fc%3Fd%23e%25f%7C%5B%5D"
            RouterMockProtocol.handle = { request in
                if request.url!.path == "/" {
                    return (200, try JSONSerialization.data(withJSONObject: ["error_code": 0, "stok": encodedToken]))
                }
                assert(request.url!.absoluteString.contains("/stok=" + encodedToken + "/ds"))
                return (200, try JSONSerialization.data(withJSONObject: fixture()))
            }
            _ = try await symbolClient.read()
            let entries = HakoLogStore.shared.snapshot().entries
            assert(!entries.map(\.text).joined().contains("test-token"))
            assert(!entries.map(\.text).joined().contains("new-token"))
            assert(!entries.map(\.text).joined().contains(symbolToken))
            assert(!entries.map(\.text).joined().contains(encodedToken))
            if route == .sora {
                let unavailable = try RouterClient(connection: connection, isLocal: { await network.local }, session: session)
                var failures = 0
                RouterMockProtocol.handle = { _ in failures += 1; throw URLError(.cannotConnectToHost) }
                do { _ = try await unavailable.read(); fatalError("Expected proxy failure") }
                catch let error as RouterFailure {
                    assert(failures == 1 && error.message.contains("Sora 代理连接失败"))
                }
            }
        }
        // A network transition is reevaluated on refresh. Sessions are not reused
        // across routes. Only the injected host state determines the route.
        let switchingNetwork = RouterTestNetwork(local: true)
        let switchingClient = try RouterClient(connection: connection, isLocal: { await switchingNetwork.local }, session: session)
        var logins = 0
        RouterMockProtocol.handle = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            if body["login"] != nil {
                logins += 1
                return (200, Data("{\"error_code\":0,\"stok\":\"switch-token\"}".utf8))
            }
            return (200, try JSONSerialization.data(withJSONObject: fixture()))
        }
        for local in [true, false, true] {
            await switchingNetwork.setLocal(local)
            RouterMockProtocol.expectedProxy = local ? nil : "192.168.0.1:80"
            _ = try await switchingClient.read()
            let selected = await switchingClient.currentRoute()
            assert(selected == (local ? .direct : .sora))
        }
        assert(logins == 3)
        var wakeRequests = 0, rebootRequests = 0
        RouterMockProtocol.handle = { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            if body["wake_on_lan"] != nil { wakeRequests += 1 }
            if (body["system"] as? [String: Any])?["reboot"] != nil { rebootRequests += 1 }
            if body["login"] != nil { return (200, Data("{\"error_code\":0,\"stok\":\"action-token\"}".utf8)) }
            return (200, try JSONSerialization.data(withJSONObject: fixture()))
        }
        // Wake/reboot also consult host state before sending once.
        await switchingNetwork.setLocal(false)
        RouterMockProtocol.expectedProxy = "192.168.0.1:80"
        try await switchingClient.wake(mac: "02:11:22:33:44:55")
        await switchingNetwork.setLocal(true)
        RouterMockProtocol.expectedProxy = nil
        try await switchingClient.reboot()
        assert(wakeRequests == 1 && rebootRequests == 1)
        print("Router validation and automatic direct/Sora transport tests passed")
    }
    static func tryValue<T>(_ body: () throws -> T) -> T { try! body() }
}
