import SwiftUI

struct ECSAccessRecordsView: View {
    private enum Screen: Hashable { case query, results, detail }
    @ObservedObject private var client = ECSAccessAPI.shared
    @StateObject private var store = ECSAccessRecordsStore(client: ECSAccessAPI.shared)
    @State private var draft: ECSAccessRecordFilter
    @State private var screen = Screen.query
    @State private var selectedRecord: ECSAccessRecord?
    @State private var range: String
    @State private var customStatus = false
    @State private var validationError: String?
    private let domains: [String]
    private let timezone: String
    private let commonStatuses = [200, 301, 302, 403, 404, 500]

    init(domain: String = "", domains: [String] = [], from: String? = nil, to: String? = nil,
         hour: String? = nil, timezone: String = "Asia/Shanghai") {
        self.domains = Array(Set(domains + (domain.isEmpty ? [] : [domain]))).sorted()
        self.timezone = timezone
        var start = ECSAccessDate.parse(from) ?? Date().addingTimeInterval(-86400)
        var end = ECSAccessDate.parse(to) ?? Date()
        if let selectedHour = ECSAccessDate.parse(hour) {
            start = max(start, selectedHour); end = min(end, selectedHour.addingTimeInterval(3600))
        }
        _draft = State(initialValue: ECSAccessRecordFilter(domain: domain, from: start, to: end))
        let duration = end.timeIntervalSince(start)
        _range = State(initialValue: abs(duration - 3600) < 2 ? "1" : abs(duration - 86400) < 2 ? "24" : "custom")
    }

    private var resultTimezone: String { store.page?.timezone ?? timezone }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch screen {
                    case .query: queryForm
                    case .results: results
                    case .detail:
                        if let selectedRecord { recordDetails(selectedRecord) }
                    }
                }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
                    .id("records-top")
            }
            .onChange(of: screen) { _, _ in proxy.scrollTo("records-top", anchor: .top) }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(screen == .detail ? "记录详情" : "访问记录")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(screen != .query)
        .toolbar {
            if screen != .query {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        if screen == .detail { screen = .results }
                        else { store.cancel(); screen = .query }
                    } label: { Image(systemName: "chevron.left") }
                    .accessibilityLabel(screen == .detail ? "返回查询结果" : "返回查询条件")
                }
            }
            if screen == .results {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("筛选") { store.cancel(); screen = .query }
                }
            }
        }
        .environment(\.timeZone, TimeZone(identifier: timezone) ?? .current)
        .onDisappear { store.cancel() }
        .onChange(of: client.requestContext) { _, _ in
            store.clear(); draft = ECSAccessRecordFilter(); range = "24"; customStatus = false
            selectedRecord = nil; validationError = nil; screen = .query
        }
    }

    private var queryForm: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("查询访问记录")
            Text("找到某个 IP、路径或状态码对应的请求。")
                .font(.subheadline).foregroundStyle(.secondary).padding(.top, 7).padding(.bottom, 24)
            sectionLabel("查询范围")
            panel {
                HStack(spacing: 12) {
                    Text("域名").font(.subheadline)
                    Spacer(minLength: 8)
                    Picker("域名", selection: $draft.domain) {
                        Text("全部域名").tag("")
                        ForEach(domains, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.menu).labelsHidden().tint(.primary)
                }.padding(.vertical, 8)
                Divider()
                HStack(spacing: 7) {
                    rangeButton("近 1 小时", value: "1")
                    rangeButton("近 24 小时", value: "24")
                    rangeButton("自定义", value: "custom")
                }.padding(.vertical, 12)
                Divider()
                dateField("开始时间", selection: $draft.from)
                Divider()
                dateField("结束时间", selection: $draft.to)
            }
            sectionLabel("筛选条件", trailing: "可组合 · 留空不限").padding(.top, 24)
            panel {
                field("来源 IP", text: $draft.ip, prompt: "例如 203.0.113.24")
                Divider()
                field("URL 路径", text: $draft.path, prompt: "例如 /wordpress/")
                Divider()
                Menu {
                    Button("全部状态码") { draft.status = ""; customStatus = false }
                    ForEach(commonStatuses, id: \.self) { code in
                        Button(String(code)) { draft.status = String(code); customStatus = false }
                    }
                    Button("其他状态码…") { customStatus = true }
                } label: {
                    HStack(spacing: 8) {
                        Text("HTTP 状态码")
                        Spacer(minLength: 8)
                        Text(draft.status.isEmpty ? "全部状态码" : draft.status).foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.tertiary)
                    }.font(.subheadline).padding(.vertical, 17).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if customStatus {
                    Divider()
                    field("HTTP 状态码（100–599）", text: $draft.status, prompt: "例如 429").keyboardType(.numberPad)
                }
            }
            note("按完整 IP、路径和状态码精确匹配。路径不包含 ? 后的参数。")
            if let validationError {
                Text(validationError).font(.footnote).foregroundStyle(.orange).padding(.top, 12)
            }
            Button { search(draft) } label: {
                Label("查询记录", systemImage: "magnifyingglass")
                    .font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 15))
                    .foregroundStyle(Color(uiColor: .systemBackground))
            }.buttonStyle(.plain).padding(.top, 24)
            footer("\(timezone) · 最近 7 天 · 不限 Top 10")
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("查询结果")
            if let page = store.page {
                Text("匹配 \(page.requests.formatted()) 次请求 · \(page.totalRows.formatted()) 条记录")
                    .font(.headline).padding(.top, 18)
                Text("\(timeLabel(page.from, seconds: false)) — \(timeLabel(page.to, seconds: false)) · \(page.timezone)")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 7)
            }
            if let filter = store.filter {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { filterChips(filter) }
                    VStack(alignment: .leading, spacing: 6) { filterChips(filter) }
                }.padding(.top, 13)
            }
            sectionLabel("匹配记录", trailing: "时间倒序").padding(.top, 24)
            if store.rows.isEmpty {
                panel {
                    VStack(spacing: 10) {
                        if store.busy { ProgressView("正在查询…") }
                        else if store.error == nil { Text("没有匹配记录，可调整筛选条件后重试。").foregroundStyle(.secondary) }
                    }.font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 32)
                }
            } else {
                panel {
                    ForEach(Array(store.rows.enumerated()), id: \.offset) { index, row in
                        if index > 0 { Divider() }
                        Button { selectedRecord = row; screen = .detail } label: { recordRow(row) }.buttonStyle(.plain)
                    }
                }
            }
            if let error = store.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                    Button("重试查询") { store.retry() }.disabled(store.busy)
                }.padding(.top, 16)
            }
            if store.page?.hasMore == true {
                Button { store.loadMore() } label: {
                    HStack(spacing: 8) {
                        if store.busy { ProgressView().controlSize(.small) }
                        Text(store.busy ? "正在加载…" : "加载更多")
                    }.font(.subheadline).frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
                }.buttonStyle(.plain).disabled(store.busy).padding(.top, 14)
            }
            if let page = store.page { footer("已显示 \(store.rows.count.formatted()) / \(page.totalRows.formatted()) 条记录") }
            note("同一秒且其余信息相同的请求合并显示次数。点击记录可查看完整信息。")
        }
    }

    private func recordRow(_ row: ECSAccessRecord) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(timeLabel(row.time)).monospacedDigit()
                Spacer(minLength: 6)
                Text("\(row.count.formatted()) 次")
            }.font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 9) {
                Text(String(row.status)).font(.caption.monospaced().weight(.medium))
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .foregroundStyle(statusColor(row.status))
                    .background(statusColor(row.status).opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                Text(row.path).font(.subheadline.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            Text(row.ip + " · " + row.domain).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 15).contentShape(Rectangle())
            .accessibilityElement(children: .combine).accessibilityHint("查看记录详情")
    }

    private func recordDetails(_ row: ECSAccessRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("记录详情")
            sectionLabel("请求信息").padding(.top, 24)
            panel {
                detailField("时间", value: row.time)
                Divider()
                detailField("HTTP 状态码", value: String(row.status))
                Divider()
                detailField("请求次数", value: "\(row.count.formatted()) 次")
                Divider()
                detailField("域名", value: row.domain)
                Divider()
                detailField("来源 IP", value: row.ip)
                Divider()
                detailField("URL 路径", value: row.path)
                Divider()
                detailField("User-Agent", value: row.userAgent)
            }.textSelection(.enabled)
            sectionLabel("继续查询").padding(.top, 24)
            panel {
                continuation("查询此 IP 的全部记录", icon: "network", row: row, kind: .ip)
                Divider()
                continuation("查询此路径的全部记录", icon: "point.topleft.down.to.point.bottomright.curvepath", row: row, kind: .path)
            }
            note("沿用当前域名和时间范围，清除其他筛选条件。")
        }
    }

    private func continuation(_ title: String, icon: String, row: ECSAccessRecord, kind: ECSAccessRecordFilter.Continuation) -> some View {
        Button {
            guard let filter = store.filter else { return }
            let next = filter.continuing(row, by: kind)
            draft = next; range = "custom"; customStatus = false
            search(next)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 18)
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.font(.subheadline).padding(.vertical, 16).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    @ViewBuilder private func filterChips(_ filter: ECSAccessRecordFilter) -> some View {
        ForEach(Array([(name: "域名", value: filter.domain), (name: "IP", value: filter.ip),
                       (name: "路径", value: filter.path), (name: "状态码", value: filter.status)].filter { !$0.value.isEmpty }.enumerated()), id: \.offset) { _, item in
            Text(item.name + "：" + item.value).font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func search(_ filter: ECSAccessRecordFilter) {
        do { try store.search(filter); validationError = nil; screen = .results }
        catch { validationError = error.localizedDescription; screen = .query }
    }

    private func rangeButton(_ label: String, value: String) -> some View {
        Button {
            range = value
            if value != "custom" {
                let end = Date(); draft.to = end
                draft.from = end.addingTimeInterval(value == "1" ? -3600 : -86400)
            }
        } label: {
            Text(label).font(.caption).frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(range == value ? Color.primary : Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(range == value ? Color(uiColor: .systemBackground) : .primary)
        }.buttonStyle(.plain).accessibilityAddTraits(range == value ? .isSelected : [])
    }

    private func dateField(_ label: String, selection: Binding<Date>) -> some View {
        DatePicker(label, selection: Binding(get: { selection.wrappedValue }, set: { selection.wrappedValue = $0; range = "custom" }), displayedComponents: [.date, .hourAndMinute])
            .datePickerStyle(.compact).font(.subheadline).padding(.vertical, 9)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            TextField(prompt, text: text).font(.body.monospaced()).textInputAutocapitalization(.never)
                .autocorrectionDisabled().accessibilityLabel(label)
        }.padding(.vertical, 13)
    }

    private func detailField(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(.vertical, 13)
    }

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(.horizontal, 15).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 19))
    }
    private func heading(_ title: String) -> some View { Text(title).font(.title.bold()) }
    private func sectionLabel(_ title: String, trailing: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 4)
            if let trailing { Text(trailing).font(.caption2) }
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 9)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 10)
    }
    private func footer(_ text: String) -> some View {
        Text(text).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 14)
    }
    private func statusColor(_ code: Int) -> Color {
        switch code {
        case 200..<300: return .green
        case 400..<500: return .orange
        case 500...599: return .red
        default: return .blue
        }
    }
    private func timeLabel(_ text: String, seconds: Bool = true) -> String {
        guard let date = ECSAccessDate.parse(text) else { return text }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: resultTimezone) ?? .current
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = seconds ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
