import Foundation

@main struct InvestmentDatabaseVersionTests {
    static func main() throws {
        let current = try InvestmentDatabaseVersion.decode(Data(#"{"version":5,"expectedVersion":5}"#.utf8))
        precondition(current.matchesExpected && current.statusLabel == "已是目标版本")
        precondition(current.versionLabel == "schema 5" && current.expectedVersionLabel == "schema 5")
        let old = try InvestmentDatabaseVersion.decode(Data(#"{"version":4,"expectedVersion":5}"#.utf8))
        precondition(!old.matchesExpected && old.statusLabel == "数据库待升级" && old.versionLabel == "schema 4")
        let newer = try InvestmentDatabaseVersion.decode(Data(#"{"version":6,"expectedVersion":5}"#.utf8))
        precondition(!newer.matchesExpected && newer.statusLabel == "数据库版本高于目标")
        for invalid in [#"{"expectedVersion":5}"#, #"{"version":5}"#, #"{"version":0,"expectedVersion":5}"#,
                        #"{"version":5,"expectedVersion":-1}"#, #"{"version":"5","expectedVersion":5}"#, #"{"error":"storage_error"}"#] {
            do { _ = try InvestmentDatabaseVersion.decode(Data(invalid.utf8)); preconditionFailure("Invalid metadata displayed as completed") }
            catch { }
        }
        print("Investment database version: actual, expected, mismatches and unreadable metadata passed")
    }
}
