import SwiftUI

struct HakoLogsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var entries: [HakoLogEntry] = []
    @State private var storageIssue: String?
    @State private var source: HakoLogSource?
    @State private var level: HakoLogLevel?
    @State private var search = ""
    @State private var confirmingClear = false

    private var filtered: [HakoLogEntry] {
        entries.filter { entry in
            (source == nil || entry.source == source) && (level == nil || entry.level == level)
                && (search.isEmpty || (entry.message + "\n" + entry.detail).localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        List {
            Section {
                Picker("子应用", selection: $source) {
                    Text("全部").tag(Optional<HakoLogSource>.none)
                    ForEach(HakoLogSource.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }
                Picker("级别", selection: $level) {
                    Text("全部").tag(Optional<HakoLogLevel>.none)
                    ForEach(HakoLogLevel.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                }
            } footer: { Text("仅保存在本机，保留最近 \(HakoLogStore.capacity) 条。连接凭据已隐藏，不记录请求正文和终端输入输出。") }
            if let storageIssue { Section { Text(storageIssue).foregroundStyle(.orange).font(.footnote) } }
            Section("\(filtered.count) 条日志 · 最新在前") {
                if filtered.isEmpty {
                    ContentUnavailableView("暂无日志", systemImage: "doc.text.magnifyingglass", description: Text("操作子应用后返回查看，或调整筛选条件。"))
                }
                ForEach(filtered) { entry in
                    NavigationLink { HakoLogDetailView(entry: entry) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(entry.source.rawValue)
                                Text(entry.level.rawValue).foregroundStyle(entry.level == .error ? .red : entry.level == .warning ? .orange : .secondary)
                                Spacer()
                                Text(entry.time, format: .dateTime.hour().minute().second())
                            }.font(.caption).foregroundStyle(.secondary)
                            Text(entry.message).font(.subheadline).lineLimit(2)
                            if !entry.detail.isEmpty { Text(entry.detail).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2) }
                        }.padding(.vertical, 3)
                    }
                }
            }
        }
        .navigationTitle("日志")
        .searchable(text: $search, prompt: "搜索日志内容")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: filtered.map(\.text).joined(separator: "\n\n")) { Label("分享当前筛选的日志", systemImage: "square.and.arrow.up") }
                        .disabled(filtered.isEmpty)
                    Button("清空全部日志", systemImage: "trash", role: .destructive) { confirmingClear = true }
                        .disabled(entries.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("日志操作")
            }
        }
        .confirmationDialog("清空本机全部日志？", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("清空全部日志", role: .destructive) { HakoLogStore.shared.clear(); reload() }
        }
        .refreshable { reload() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            reload()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                reload()
            }
        }
        .privacySensitive()
    }
    private func reload() { let snapshot = HakoLogStore.shared.snapshot(); entries = snapshot.entries; storageIssue = snapshot.issue }
}

private struct HakoLogDetailView: View {
    let entry: HakoLogEntry
    var body: some View {
        List {
            Section {
                LabeledContent("子应用", value: entry.source.rawValue)
                LabeledContent("级别", value: entry.level.rawValue)
                LabeledContent("时间", value: entry.time.formatted(date: .complete, time: .standard))
            }
            Section("事件") { Text(entry.message).textSelection(.enabled) }
            if !entry.detail.isEmpty {
                Section("详情") { Text(entry.detail).font(.footnote.monospaced()).textSelection(.enabled) }
            }
        }
        .navigationTitle("日志详情")
        .toolbar { ShareLink(item: entry.text) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("分享此条日志") }
        .privacySensitive()
    }
}
