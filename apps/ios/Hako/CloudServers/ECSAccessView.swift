import SwiftUI
import Charts

struct ECSAccessMetrics: View {
    let visits: Int64
    let notFound: Int64
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            metric("HTTP 请求", value: visits.formatted())
            metric("404", value: notFound.formatted())
            metric("404 占比", value: String(format: "%.1f%%", visits > 0 ? Double(notFound) / Double(visits) * 100 : 0))
        }.padding(.vertical, 5)
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ECSAccessFreshness: View {
    let status: ECSAccessStatus
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 5) {
                switch status.health(at: context.date) {
                case .failed:
                    Label("日志扫描异常，统计可能不完整", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                case .delayed:
                    Label("日志扫描延迟，数据可能尚未更新", systemImage: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange)
                case .scanning: Text("正在首次扫描日志…")
                case .waiting: Text("等待首次日志扫描")
                case .disabled: Text("日志统计尚未启用")
                case .healthy: EmptyView()
                }
                if let date = status.scanDate {
                    Text("最近扫描结束：\(date.formatted(date: .abbreviated, time: .standard))")
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ECSAccessView: View {
    let connection: ECSConnection
    @StateObject private var store = ECSAccessStore()
    @ObservedObject private var client = ConsoleClient.shared
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("ecs.access.revision") private var revision = ""
    @State private var settings = false
    @State private var visible = false
    @State private var range = ECSAccessRange.day
    @State private var domain = ""
    @State private var selectedDate: Date?
    @State private var hour: String?

    private var binding: ECSAccessBinding? { ECSAccessBinding.load(connection) }
    private var domains: [String] { binding?.domains ?? [] }
    private var selectedDomains: [String] { domain.isEmpty ? domains : [domain] }
    private var validBinding: Bool { binding?.matches(origin: client.serverURL, account: client.username) == true && !domains.isEmpty }
    private var daily: Bool { range.rawValue >= 72 }
    private var taskKey: String {
        "\(visible && scenePhase == .active && !settings)|\(revision)|\(client.serverURL)|\(client.username)|\(client.authenticated)|\(client.logoutPending)|\(range.rawValue)|\(domain)|\(hour ?? "")"
    }
    var body: some View {
        List {
            if !validBinding {
                Section {
                    ContentUnavailableView("关联访问统计", systemImage: "chart.bar.xaxis", description: Text("从 Hako 服务器选择由此 ECS 承载的域名。"))
                    Button("选择数据来源与域名") { settings = true }
                }
            } else {
                Section {
                    Picker("域名", selection: $domain) {
                        Text("全部关联域名").tag("")
                        ForEach(domains, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("时间范围", selection: $range) {
                        ForEach(ECSAccessRange.allCases) { Text($0.label).tag($0) }
                    }
                }
                if store.busy { ProgressView("读取访问统计…") }
                if let error = store.error {
                    Section { Text(error).font(.footnote).foregroundStyle(.orange); Button("重试") { Task { await refresh() } } }
                }
                if let value = store.summary {
                    if value.status.enabled { content(value) }
                    else { Section { Text("Hako 服务端尚未启用 Caddy 访问日志统计。").foregroundStyle(.secondary) } }
                }
            }
        }
        .navigationTitle("访问统计").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { settings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("访问统计来源与域名设置")
            }
        }
        .sheet(isPresented: $settings) { ECSAccessSettingsSheet(connection: connection) }
        .onAppear { visible = true }.onDisappear { visible = false }
        .onChange(of: range) { _, _ in hour = nil; selectedDate = nil }
        .onChange(of: domain) { _, _ in hour = nil; selectedDate = nil }
        .onChange(of: revision) { _, _ in domain = ""; hour = nil; selectedDate = nil; store.clear() }
        .onChange(of: selectedDate) { _, date in
            guard !daily, !domain.isEmpty, let date, let value = store.summary else { return }
            hour = value.buckets(domains: selectedDomains, daily: false).min {
                abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date))
            }?.hour
        }
        .refreshable { await refresh() }
        .task(id: taskKey) {
            guard visible, scenePhase == .active, !settings else { return }
            guard validBinding else { store.clear(); return }
            if !client.authenticated { await client.restore() }
            guard !Task.isCancelled else { return }
            while !Task.isCancelled {
                await refresh()
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
            }
        }
    }

    @ViewBuilder private func content(_ value: ECSAccessSummary) -> some View {
        let totals = value.counts(domains: selectedDomains)
        Section(range.label) {
            ECSAccessMetrics(visits: totals.reduce(0) { $0 + $1.visits }, notFound: totals.reduce(0) { $0 + $1.notFound })
        }
        Section("数据状态") {
            ECSAccessFreshness(status: value.status)
            if let error = value.status.scanError {
                DisclosureGroup("查看扫描错误") {
                    Text(error).font(.footnote.monospaced()).textSelection(.enabled)
                    Text("扫描结束时间也会在失败时更新，不代表所有日志均读取成功。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        Section(daily ? "请求趋势 · 按天" : "请求趋势 · 按小时") {
            if value.truncated == true {
                Text("小时记录过多，趋势暂不展示。请选择单个域名或缩短时间范围；汇总数字仍为完整统计。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                trendChart(value)
                HStack { Label("HTTP 请求", systemImage: "square.fill").foregroundStyle(.blue); Label("404", systemImage: "line.diagonal").foregroundStyle(.orange) }.font(.caption)
                Text(!daily && !domain.isEmpty ? "轻触柱子查看数值；长按拖动可查看其他小时及排行。" : "轻触柱子查看对应时段的数值。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("时区：\(value.status.timezone) · 按日志请求计数，包含爬虫。最多保留 7 天。")
                .font(.caption).foregroundStyle(.secondary)
        }
        if domain.isEmpty {
            Section("域名排行 · \(range.label)") {
                ForEach(totals) { row in
                    Button { domain = row.domain } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.domain).foregroundStyle(.primary)
                                Text("404 \(row.notFound.formatted()) · \(String(format: "%.1f%%", row.missingRate))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Text(row.visits.formatted()).monospacedDigit().foregroundStyle(.primary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
                if totals.isEmpty { Text("所选关联域名在此时间范围内暂无请求。").foregroundStyle(.secondary) }
            }
        } else {
            if let date = ECSAccessDate.parse(hour) {
                Section {
                    LabeledContent("排行时段", value: date.formatted(date: .abbreviated, time: .shortened))
                    if let ranks = store.rankings { ECSAccessMetrics(visits: ranks.visits, notFound: ranks.notFound) }
                    Button("查看整个时间范围") { hour = nil; selectedDate = nil }
                }
            }
            if let ranks = store.rankings { rankings(ranks) }
        }
    }

    private func trendChart(_ value: ECSAccessSummary) -> some View {
        let points = value.buckets(domains: selectedDomains, daily: daily)
        let selectedPoint = selectedDate.flatMap { date in
            points.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
        }
        return Chart {
            ForEach(points) { point in
                BarMark(x: .value("时间", point.time), y: .value("请求", point.visits))
                    .foregroundStyle(.blue)
                    .opacity(selectedPoint == nil || selectedPoint?.time == point.time ? 1 : 0.35)
                    .accessibilityLabel(Text(point.time, format: daily ? .dateTime.year().month().day() : .dateTime.month().day().hour()))
                    .accessibilityValue("HTTP 请求 \(point.visits.formatted())，404 \(point.notFound.formatted())")
                LineMark(x: .value("时间", point.time), y: .value("404", point.notFound))
                    .foregroundStyle(.orange)
            }
            if let point = selectedPoint {
                RuleMark(x: .value("所选时段", point.time))
                    .foregroundStyle(Color.secondary.opacity(0.4))
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(point.time, format: daily ? .dateTime.year().month().day() : .dateTime.month().day().hour())
                                .foregroundStyle(.secondary)
                            Text("HTTP 请求 \(point.visits.formatted())").foregroundStyle(.blue)
                            Text("404 \(point.notFound.formatted())").foregroundStyle(.orange)
                        }
                        .font(.caption).monospacedDigit()
                        .padding(8)
                        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .zIndex(1)
            }
        }
        .chartXSelection(value: Binding(get: { selectedDate }, set: { date in
            guard let date else { return }
            selectedDate = points.min {
                abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date))
            }?.time
        }))
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .simultaneousGesture(SpatialTapGesture().onEnded { tap in
                        guard let anchor = proxy.plotFrame else { return }
                        let plot = geometry[anchor]
                        guard plot.contains(tap.location),
                              let date = proxy.value(atX: tap.location.x - plot.minX, as: Date.self) else { return }
                        selectedDate = points.min {
                            abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date))
                        }?.time
                    })
                    .accessibilityHidden(true)
            }
        }
        .environment(\.timeZone, TimeZone(identifier: value.status.timezone) ?? .current)
        .frame(height: 180)
        .onChange(of: points.map(\.time)) { _, dates in
            if let selectedDate, !dates.contains(selectedDate) { self.selectedDate = nil }
        }
    }

    @ViewBuilder private func rankings(_ ranks: ECSAccessRankings) -> some View {
        Section("404 页面 · Top 10") {
            ForEach(ranks.notFoundPages) { row in
                NavigationLink {
                    ECSAccessRankDetails(title: "404 页面", value: row.value, count: row.count,
                                         domain: ranks.domain, from: ranks.from, to: ranks.to, hour: ranks.hour,
                                         relatedTitle: "来源 IP", related: row.ips, agents: row.userAgents)
                } label: { rankRow(row.value, row.count) }
            }
            if ranks.notFoundPages.isEmpty { emptyRank }
        }
        Section("访问 URL · Top 10") {
            ForEach(ranks.topURLs) { row in rankRow(row.value, row.count) }
            if ranks.topURLs.isEmpty { emptyRank }
        }
        Section("来源 IP · Top 10") {
            ForEach(ranks.topClients) { row in
                NavigationLink {
                    ECSAccessRankDetails(title: "来源 IP", value: row.value, count: row.count,
                                         domain: ranks.domain, from: ranks.from, to: ranks.to, hour: ranks.hour,
                                         relatedTitle: "访问 URL", related: row.urls, agents: row.userAgents)
                } label: { rankRow(row.value, row.count) }
            }
            if ranks.topClients.isEmpty { emptyRank }
        }
    }
    private var emptyRank: some View { Text("此时段暂无记录。").foregroundStyle(.secondary) }
    private func rankRow(_ value: String, _ count: Int64) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(value.isEmpty ? "未知" : value).font(.subheadline.monospaced()).lineLimit(2)
            Spacer(minLength: 8); Text(count.formatted()).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
        }.padding(.vertical, 3)
    }
    private func refresh() async {
        await store.refresh(connection: connection, client: client, range: range, domain: domain, hour: hour)
    }
}

private struct ECSAccessRankDetails: View {
    let title: String
    let value: String
    let count: Int64
    let domain: String
    let from: String
    let to: String
    let hour: String
    let relatedTitle: String
    let related: [ECSAccessRank]
    let agents: [ECSAccessRank]
    var body: some View {
        List {
            Section(title) {
                Text(value.isEmpty ? "未知" : value).font(.body.monospaced())
                LabeledContent("请求数", value: count.formatted())
                LabeledContent("域名", value: domain)
                if let start = ECSAccessDate.parse(from), let end = ECSAccessDate.parse(to) {
                    Text("\(start.formatted()) 至 \(end.formatted())").font(.caption).foregroundStyle(.secondary)
                }
                if let date = ECSAccessDate.parse(hour) { Text("仅查看 \(date.formatted()) 起的一个小时").font(.caption).foregroundStyle(.secondary) }
            }
            rows(relatedTitle + " · Top 10", related)
            rows("User-Agent · Top 10", agents)
        }.navigationTitle(title).textSelection(.enabled)
    }
    private func rows(_ title: String, _ values: [ECSAccessRank]) -> some View {
        Section(title) {
            ForEach(values) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.value.isEmpty ? "未知" : row.value).font(.subheadline.monospaced())
                    Text("\(row.count.formatted()) 次").font(.caption).foregroundStyle(.secondary)
                }
            }
            if values.isEmpty { Text("暂无记录").foregroundStyle(.secondary) }
        }
    }
}
