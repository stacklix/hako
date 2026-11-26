import Foundation

@main struct WorkshopCollaborationTests {
    static func main() throws {
        precondition(WorkshopDiagramDocument.supports("Mermaid"))
        precondition(!WorkshopDiagramDocument.supports("swift"))
        let source = "flowchart TD\n A[中文] --> B[Done]\n</script><script>alert(1)</script>"
        let html = WorkshopDiagramDocument.build(source: source, library: "window.mermaid={};", dark: true, nonce: "test-nonce")
        precondition(!html.contains(source), "Untrusted source must never be interpolated as HTML or JavaScript")
        precondition(html.contains(Data(source.utf8).base64EncodedString()))
        precondition(html.contains("connect-src 'none'") && html.contains("securityLevel:'strict'"))
        precondition(html.contains("theme:'dark'") && html.contains("script-src 'nonce-test-nonce'"))
        let list = try JSONDecoder().decode(WorkshopSubagentList.self, from: Data("""
        {"agents":[{"id":"a","name":"Darwin","role":"explorer","task":"检查缓存","state":"completed","model":"m","reasoningEffort":"high","updatedAt":1}],"nextCursor":null}
        """.utf8))
        precondition(list.agents.count == 1 && list.agents[0].status == "已完成" && !list.agents[0].active)
        func child(_ id: String, _ state: String, _ time: Int64) -> WorkshopSubagent {
            WorkshopSubagent(id: id, name: id, role: "", task: "", state: state,
                model: "", reasoningEffort: "", updatedAt: time)
        }
        let now = Date(timeIntervalSince1970: 1000)
        let children = [child("read", "completed", 999), child("unread", "completed", 900),
            child("running", "running", 950), child("waiting", "waiting", 940), child("failed", "failed", 980)]
        var reads = WorkshopReadState()
        reads.markRead(threadId: "read", completionId: children[0].readToken, agentId: "computer")
        func sortedChildren() -> [String] {
            WorkshopSubagent.ordered(children, isUnread: { reads.isUnread($0.session, agentId: "computer", now: now) }).map(\.id)
        }
        precondition(sortedChildren() == ["running", "waiting", "unread", "read", "failed"],
            "Running and unread share the workshop attention group; unread must not jump ahead of more recent running work")
        reads.markRead(threadId: "unread", completionId: children[1].readToken, agentId: "computer")
        precondition(sortedChildren() == ["running", "waiting", "read", "failed", "unread"],
            "Read child replies return to ordinary chronological order")
        // Optional output path generates exactly the shipped document for browser tests.
        if CommandLine.arguments.count == 3 {
            let library = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
            try WorkshopDiagramDocument.build(source: "flowchart TD\n A[触发更新账本] --> B[读取缓存]\n B --> C{是否过期}\n C -->|是| D[更新行情]\n C -->|否| E[返回结果]\n D --> E", library: library, dark: false, nonce: "browser-test")
                .write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
        }
        print("PASS: collaboration metadata, Mermaid source isolation, strict rendering and offline CSP")
    }
}
