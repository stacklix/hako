import Foundation

@main struct ECSNetworkTests {
    static func main() throws {
        precondition(ECSSocketEndpoint("0.0.0.0:443") == ECSSocketEndpoint("[0.0.0.0]:443"))
        precondition(ECSSocketEndpoint("[::]:443")?.address == "::")
        precondition(ECSSocketEndpoint(":::443")?.port == 443)
        precondition(ECSSocketEndpoint("[fe80::1%eth0]:53")?.family == "IPv6")
        precondition(ECSSocketEndpoint("*:53")?.family == "通配地址")
        precondition(ECSSocketEndpoint("127.0.0.1:0") == nil && ECSSocketEndpoint("[::]:65536") == nil)
        precondition(ECSSocketEndpoint("missing") == nil)

        let data = Data(#"""
        {"version":1,"time":100,"truncated":true,"totalSockets":1503,"totalListeningPorts":3,
         "socketSummary":{"outgoing":1000,"incoming":500,"unknown":3},"primaryInterface":"eth0",
         "sockets":[
          {"protocolName":"tcp","state":"LISTEN","local":"0.0.0.0:443","peer":"0.0.0.0:*","pid":1,"process":"nginx"},
          {"protocolName":"tcp","state":"LISTEN","local":"[::]:443","peer":"[::]:*","pid":2,"process":"nginx"},
          {"protocolName":"tcp","state":"LISTEN","local":"127.0.0.1:443","peer":"0.0.0.0:*","pid":3,"process":"proxy"},
          {"protocolName":"udp","state":"UNCONN","local":"[::]:443","peer":"[::]:*","pid":4,"process":"quic"},
          {"protocolName":"udp","state":"UNCONN","local":"127.0.0.53:53","peer":"0.0.0.0:*"},
          {"protocolName":"tcp","state":"ESTAB","local":"10.0.0.1:443","peer":"192.0.2.1:50000","direction":"incoming"},
          {"protocolName":"tcp","state":"ESTAB","local":"10.0.0.1:50000","peer":"192.0.2.1:443","direction":"outgoing"},
          {"protocolName":"tcp","state":"SYN-SENT","local":"10.0.0.1:50001","peer":"192.0.2.1:443","direction":"outgoing"},
          {"protocolName":"udp","state":"ESTAB","local":"10.0.0.1:50002","peer":"192.0.2.1:53","direction":"outgoing"}
         ]}
        """#.utf8)
        let snapshot = try ECSSnapshot.decode(data)
        let ports = ECSListeningPort.grouped(snapshot.sockets!)
        precondition(ports.count == 3 && ports[0].port == 53)
        let tcp = ports.first { $0.protocolName == "tcp" && $0.port == 443 }!
        precondition(tcp.sockets.count == 3 && tcp.processes == "nginx、proxy")
        precondition(ports.first { $0.protocolName == "udp" && $0.port == 443 }!.sockets.count == 1)
        precondition(ECSConnectionDirection.incoming.sockets(snapshot.sockets!).count == 1)
        precondition(ECSConnectionDirection.outgoing.sockets(snapshot.sockets!).count == 1)
        precondition(ECSConnectionDirection.outgoing.count(snapshot.socketSummary) == 1000,
                     "The headline must use complete pre-truncation counts")
        precondition(snapshot.primaryInterface == "eth0" && snapshot.socketSummary?.unknown == 3)

        let isolated = try JSONDecoder().decode([ECSSocket].self, from: Data(#"""
        [{"protocolName":"tcp","state":"ESTAB","local":"10.0.0.1:443","peer":"192.0.2.1:50000","direction":"incoming","namespace":"host"},
         {"protocolName":"tcp","state":"ESTAB","local":"10.0.0.1:443","peer":"192.0.2.1:50000","direction":"incoming","namespace":"net:[2]"}]
        """#.utf8))
        precondition(Set(isolated.map(\.id)).count == 2, "Namespace-local socket addresses must retain distinct row identities")

        let listeners = try JSONDecoder().decode([ECSSocket].self, from: Data(#"""
        [{"protocolName":"tcp","state":"LISTEN","local":"*:8080","peer":"*:*","namespace":"net:[1]","process":"headscale"},
         {"protocolName":"tcp","state":"LISTEN","local":"*:8080","peer":"*:*","namespace":"net:[2]","process":"hako-server"},
         {"protocolName":"tcp","state":"LISTEN","local":"0.0.0.0:443","peer":"*:*","namespace":"host","process":"proxy"},
         {"protocolName":"tcp","state":"LISTEN","local":"*:443","peer":"*:*","namespace":"net:[3]","process":"container"}]
        """#.utf8))
        let hostPorts = ECSListeningPort.grouped(listeners)
        precondition(hostPorts.count == 1 && hostPorts[0].port == 443 && hostPorts[0].processes == "proxy")
        precondition(hostPorts[0].sockets.count == 1)

        let legacy = try ECSSnapshot.decode(Data(#"{"version":1,"time":100,"sockets":[]}"#.utf8))
        precondition(legacy.socketSummary == nil && legacy.primaryInterface == nil)
        precondition(ECSConnectionDirection.incoming.count(legacy.socketSummary) == nil)
        precondition(ECSListeningPort.grouped([]).isEmpty)
        precondition(ECSNetworkRate(nil).value == "—" && ECSNetworkRate(-1).unit.isEmpty)
        precondition(ECSNetworkRate(Double.infinity).value == "—")
        precondition(ECSNetworkRate(0).value == "0" && ECSNetworkRate(0).unit == "B/s")
        precondition(ECSNetworkRate(1024).unit == "KiB/s" && ECSNetworkRate(1024 * 1024).value == "1")
        print("ECS network grouping and summary tests passed")
    }
}
