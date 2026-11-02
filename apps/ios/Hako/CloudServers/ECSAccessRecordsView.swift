import SwiftUI

struct ECSAccessRecordsView: View {
    @ObservedObject private var client = ECSAccessAPI.shared
    @State private var domain: String
    @State private var ip = ""
    @State private var path = ""
    @State private var status = ""
    @State private var from = Date().addingTimeInterval(-86400)
    @State private var to = Date()
    @State private var page: ECSAccessRecords?
    @State private var rows: [ECSAccessRecord] = []
    @State private var submittedQuery: String?
    @State private var error: String?
    @State private var busy = false
    @State private var ticket = UUID()
    @State private var requestTask: Task<Void, Never>?

    init(domain: String = "", from: String? = nil, to: String? = nil, hour: String? = nil) {
        _domain = State(initialValue: domain)
        var start = ECSAccessDate.parse(from) ?? Date().addingTimeInterval(-86400)
        var end = ECSAccessDate.parse(to) ?? Date()
        if let selectedHour = ECSAccessDate.parse(hour) {
            start = max(start, selectedHour); end = min(end, selectedHour.addingTimeInterval(3600))
        }
        _from = State(initialValue: start); _to = State(initialValue: end)
    }

    var body: some View {
        List {
            Section {
                field("域名（精确匹配）", text: $domain, prompt: "留空查询全部域名")
                field("来源 IP（精确匹配）", text: $ip, prompt: "例如：192.0.2.1")
                field("URL 路径（精确匹配）", text: $path, prompt: "例如：/wordpress/，不含查询参数")
                field("状态码（精确匹配）", text: $status, prompt: "例如：404，留空查询全部")
                DatePicker("开始时间", selection: $from, displayedComponents: [.date, .hourAndMinute])
                DatePicker("结束时间", selection: $to, displayedComponents: [.date, .hourAndMinute])
                Button("查询全部匹配记录") { search() }.disabled(busy)
            } footer: {
                Text("条件可以组合，留空表示不限。仅查询最近 7 天已入库数据；相同秒、域名、状态码、IP、路径及 UA 的请求合并显示次数，不含原始请求参数。")
            }
            if busy { ProgressView("正在查询…") }
            if let error { Section { Text(error).foregroundStyle(.orange) } }
            if let page {
                Section {
                    LabeledContent("匹配请求数", value: page.requests.formatted())
                    LabeledContent("已显示记录", value: "\(rows.count) / \(page.totalRows)")
                    Text("\(page.from) 至 \(page.to) · \(page.timezone)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("查询结果 · 时间倒序") {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("HTTP \(row.status)").font(.subheadline.monospaced())
                                Spacer()
                                Text("\(row.count.formatted()) 次").font(.subheadline)
                            }
                            Text(row.path).font(.subheadline.monospaced())
                            Text(row.domain + " · " + row.ip).font(.caption)
                            Text(row.time).font(.caption).foregroundStyle(.secondary)
                            Text("UA：" + row.userAgent).font(.caption).foregroundStyle(.secondary)
                        }.textSelection(.enabled)
                    }
                    if rows.isEmpty { Text("此范围内没有匹配记录。") }
                    if page.hasMore {
                        Button("加载更多（每页 200 条）") {
                            guard let submittedQuery else { return }
                            requestTask = Task { await load(submittedQuery, append: true) }
                        }.disabled(busy)
                    }
                }
            }
        }
        .navigationTitle("访问记录查询").navigationBarTitleDisplayMode(.inline)
        .onDisappear { requestTask?.cancel() }
        .onChange(of: client.requestContext) { _, _ in
            requestTask?.cancel(); ticket = UUID(); busy = false
            page = nil; rows = []; submittedQuery = nil; error = nil
        }
    }

    private func field(_ name: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.subheadline).foregroundStyle(.secondary)
            TextField(prompt, text: text).textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityLabel(name)
        }
    }

    private func search() {
        do {
            let query = try ECSAccessRecordsQuery.build(domain: domain, ip: ip, path: path, status: status, from: from, to: to)
            requestTask?.cancel(); page = nil; rows = []; submittedQuery = query
            requestTask = Task { await load(query, append: false) }
        } catch { self.error = error.localizedDescription }
    }

    private func load(_ query: String, append: Bool) async {
        guard !busy else { return }
        let id = UUID(); ticket = id; busy = true; error = nil
        defer { if ticket == id { busy = false } }
        do {
            let result = try await client.accessRecords(query: query + "&offset=\(append ? rows.count : 0)")
            try Task.checkCancellation()
            guard ticket == id else { return }
            if append { rows += result.rows } else { rows = result.rows }
            var fixedQuery = URLComponents(string: "?" + query)
            let fixedItems = fixedQuery?.queryItems?.map {
                URLQueryItem(name: $0.name, value: $0.name == "from" ? result.from : $0.name == "to" ? result.to : $0.value)
            }
            fixedQuery?.queryItems = fixedItems
            submittedQuery = fixedQuery?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? query
            page = result
        } catch is CancellationError { }
        catch { if ticket == id { self.error = error.localizedDescription } }
    }
}
