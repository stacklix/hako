import Foundation

struct InvestmentAgentConversation: Codable {
    static let maximumImageCount = 9

    struct Message: Identifiable, Codable {
        var id = UUID()
        let text: String
        let isUser: Bool
        var images: [Data] = []
        var html: InvestmentAgentHTML? = nil
    }

    let messages: [Message]
    let history: Data
    let modelKey: String?
    let format: LanguageModelFormat?
    let proposal: InvestmentAgentProposal?
    let canExport: Bool
    let commitStarted: Bool
}

struct InvestmentAgentConversationFile {
    let url: URL

    func load() throws -> InvestmentAgentConversation? {
        do { return try PropertyListDecoder().decode(InvestmentAgentConversation.self, from: Data(contentsOf: url)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }

    func save(_ conversation: InvestmentAgentConversation) throws {
        var directory = url.deletingLastPathComponent()
        let files = FileManager.default
        if !files.fileExists(atPath: directory.path) {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        #if os(iOS)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        #else
        let options: Data.WritingOptions = .atomic
        #endif
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(conversation).write(to: url, options: options)
    }

    func remove() throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile {}
    }
}
