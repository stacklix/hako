import Foundation

@main struct HakoServerCompatibilityTests {
    static func main() {
        func warning(server: String, minimumIOS: String, installed: String) -> String? {
            HakoServerCompatibility.evaluate(Data("""
                {"serverVersion":"\(server)","minimumIosVersion":"\(minimumIOS)","minimumAgentVersion":"1.0.0"}
                """.utf8), iosVersion: installed).warning
        }

        precondition(warning(server: "0.8.16", minimumIOS: "0.8.0", installed: "0.8.0") == nil)
        precondition(warning(server: "0.8.15", minimumIOS: "0.8.0", installed: "0.8.0")?.hasSuffix("请升级 服务端。") == true)
        precondition(warning(server: "0.7.1", minimumIOS: "0.7.0", installed: "0.7.2")?.hasSuffix("请升级 服务端。") == true)
        precondition(warning(server: "0.7.0", minimumIOS: "0.7.0", installed: "0.7.1")?.hasSuffix("请升级 服务端。") == true)
        precondition(warning(server: "0.3.9", minimumIOS: "0.7.1", installed: "0.7.1")?.hasSuffix("请升级 服务端。") == true)
        precondition(warning(server: "0.2.4", minimumIOS: "0.7.0", installed: "0.7.13")?.hasSuffix("请升级 服务端。") == true)
        precondition(warning(server: "0.8.110", minimumIOS: "0.7.9", installed: "0.7.10") == nil)
        precondition(warning(server: "0.2.99", minimumIOS: "0.7.0", installed: "0.7.0")?.hasSuffix("请升级 服务端。") == true)
        precondition(warning(server: "0.8.16", minimumIOS: "0.7.2", installed: "0.7.1")?.hasSuffix("请升级 Hako iOS。") == true)
        precondition(warning(server: "0.8.16", minimumIOS: "0.7.0", installed: "0.2.4")?.hasSuffix("请升级 Hako iOS。") == true)
        precondition(warning(server: "0.8.16", minimumIOS: "0.8.0", installed: "0.7.0")?.hasSuffix("请升级 Hako iOS。") == true)
        precondition(warning(server: "0.0.9", minimumIOS: "0.7.0", installed: "0.7.0")?.hasSuffix("请升级 服务端。") == true)
        precondition(warning(server: "0.3.9", minimumIOS: "0.9.0", installed: "0.10.0")?.hasSuffix("请升级 服务端。") == true)
        precondition(warning(server: "0.9.0", minimumIOS: "0.7.0", installed: "0.7.0")?.hasSuffix("请升级 Hako iOS。") == true)
        precondition(warning(server: "1.1.0", minimumIOS: "0.7.0", installed: "0.7.0")?.hasSuffix("请升级 Hako iOS。") == true)
        let both = warning(server: "0.0.9", minimumIOS: "0.8.0", installed: "0.7.0")
        precondition(both?.contains("请升级 Hako iOS。\n\n服务端 当前为 0.0.9") == true)
        precondition(warning(server: "0.7.0-beta", minimumIOS: "0.7.0", installed: "0.7.0")?.contains("版本信息无效") == true)
        let incompatible = HakoServerCompatibility.evaluate(Data(
            #"{"serverVersion":"0.7.0","minimumIosVersion":"0.7.0"}"#.utf8), iosVersion: "0.2.2")
        precondition(incompatible.serverVersion == "0.7.0" && incompatible.warning != nil)
        let partial = HakoServerCompatibility.evaluate(Data(
            #"{"serverVersion":"0.2.1"}"#.utf8), iosVersion: "0.2.2")
        precondition(partial.serverVersion == "0.2.1" && partial.warning != nil)
        print("Hako server compatibility: both version floors and invalid metadata passed")
    }
}
