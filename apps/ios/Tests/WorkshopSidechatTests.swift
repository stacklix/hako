import Foundation

@main struct WorkshopSidechatTests {
    static func main() throws {
        let parent = UUID().uuidString.lowercased()
        let child = UUID().uuidString.lowercased()
        var receipt = WorkshopReceipt(id: UUID().uuidString.lowercased(), agentId: "computer", applicationId: "project",
            originalThreadId: nil, threadId: nil, title: "Side question", message: "Why this design?", createdAt: .now,
            state: "pending", parentThreadId: parent)
        precondition(receipt.parameters["parentThreadId"] as? String == parent)
        precondition(receipt.parameters["systemPrompt"] == nil, "Sidechat must inherit the parent's instructions")
        receipt.threadId = child
        let restored = try JSONDecoder().decode(WorkshopReceipt.self, from: JSONEncoder().encode(receipt))
        precondition(restored.parameters["threadId"] == nil && restored.parameters["parentThreadId"] as? String == parent,
            "Retry after receiving the child id must retain the original fork request")
        let next = WorkshopReceipt(id: UUID().uuidString.lowercased(), agentId: "computer", applicationId: "project",
            originalThreadId: child, threadId: child, title: "Side question", message: "Continue", createdAt: .now,
            state: "pending", parentThreadId: parent)
        precondition(next.parameters["threadId"] as? String == child && next.parameters["parentThreadId"] == nil,
            "A subsequent turn must resume the child, never fork the parent again")
        let data = Data("{\"sessions\":[{\"id\":\"\(child)\",\"title\":\"Question\",\"applicationId\":\"p\",\"cwd\":\"/p\",\"preview\":\"Reply\",\"updatedAt\":1,\"lastSentAt\":1,\"state\":\"completed\",\"parentThreadId\":\"\(parent)\"}]}".utf8)
        struct List: Decodable { let sessions: [WorkshopSession] }
        let sessions = try JSONDecoder().decode(List.self, from: data).sessions
        precondition(sessions[0].parentThreadId == parent && sessions[0].id == child)
        print("PASS: sidechat durable request identity, parent inheritance and independent continuation")
    }
}
