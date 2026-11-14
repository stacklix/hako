import Foundation

// Fixtures were written by the feature-specific implementations before extraction.
// Comparing the property lists also catches renamed or newly wrapped Codable fields.
func assertAssistantFileRoundTrip<Conversation: Codable, Tool: Codable>(
    _ original: AssistantConversationFiles<Conversation, Tool>
) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let copy = AssistantConversationFiles<Conversation, Tool>(url: directory.appendingPathComponent("copy.plist"))
    guard let conversation = try original.load() else { preconditionFailure("Missing conversation fixture") }
    let tools = try original.loadToolCalls()
    let draft = try original.loadComposerDraft()
    precondition(tools.count == 2 && draft.text == "Fixture unsent message")
    precondition(draft.attachments.first?.data == Data([4, 5, 6]))
    try copy.save(conversation)
    try copy.saveToolCalls(tools)
    try copy.saveComposerDraft(draft)
    for suffix in ["", "tools", "draft"] {
        let input = suffix.isEmpty ? original.url : original.url.appendingPathExtension(suffix)
        let output = suffix.isEmpty ? copy.url : copy.url.appendingPathExtension(suffix)
        let before = try PropertyListSerialization.propertyList(from: Data(contentsOf: input), options: [], format: nil)
        let after = try PropertyListSerialization.propertyList(from: Data(contentsOf: output), options: [], format: nil)
        precondition(NSDictionary(dictionary: ["value": before]).isEqual(to: ["value": after]),
                     "Extracting shared assistant code must preserve the saved \(suffix) format")
    }
}
