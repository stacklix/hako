import SwiftUI

struct QinglongScriptRunner: View {
    @ObservedObject var store: QinglongStore
    let item: QinglongItem
    @State private var submitted = false
    @State private var pid: Int?
    @State private var error: String?
    @State private var revision: UUID?
    @State private var stopping = false
    var body: some View {
        QinglongSheet(submitted ? "脚本执行" : "运行脚本", disabled: store.busy) {
            Text(item.title).font(.headline)
            if !submitted {
                Text("立即运行此脚本的已保存版本？").font(.subheadline)
                Text(item.filePath).qinglongCode()
                Button("立即运行") { Task { await run() } }.buttonStyle(QinglongPrimaryButtonStyle()).disabled(store.busy)
            } else {
                QinglongNotice(text: "运行请求已提交\(pid.map { " · PID \($0)" } ?? "")")
                Text("执行输出请在青龙面板查看；请求已提交不表示脚本已执行完成。").font(.footnote).foregroundStyle(.secondary)
                if pid != nil { Button("停止执行") { stopping = true }.buttonStyle(QinglongSecondaryButtonStyle(destructive: true)).disabled(store.busy) }
            }
            if let error { QinglongNotice(text: error, error: true) }
        }
        .onAppear { if revision == nil { revision = store.revision } }
        .confirmationDialog("停止当前脚本执行？", isPresented: $stopping, titleVisibility: .visible) {
            Button("停止", role: .destructive) { Task { await stop() } }
        }
    }
    private func run() async {
        guard revision == store.revision else { error = "连接已改变，请关闭后重新打开。"; return }
        let success = await store.perform(.scripts, success: "脚本运行请求已提交。") { api in
            let content = try await api.file(item)
            let root = try await api.call(["scripts", "run"], method: "PUT", body: .fields(["filename": item.filename, "path": item.directory, "content": content]))
            pid = root["data"].int
        }
        if success { submitted = true } else { error = store.message }
    }
    private func stop() async {
        guard revision == store.revision else { error = "连接已改变，请关闭后重新打开。"; return }
        var body: [String: QinglongJSON] = ["filename": .string(item.filename), "path": .string(item.directory)]
        if let pid { body["pid"] = .number(Double(pid)) }
        let payload = QinglongJSON.object(body)
        if await store.perform(.scripts, success: "停止请求已提交。", operation: { _ = try await $0.call(["scripts", "stop"], method: "PUT", body: payload) }) { pid = nil }
        else { error = store.message }
    }
}
