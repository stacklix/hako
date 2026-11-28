import SwiftUI
import UIKit

struct HakoHangDiagnosticsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var entries: [HakoLogEntry] = []
    @State private var breadcrumbs: [HakoDiagnosticBreadcrumb] = []
    @State private var updatedAt: [Date] = []
    @State private var storageIssue: String?
    @State private var copied = false
    @State private var confirmingClear = false
    @State private var clearing = false
    @State private var report = ""
    @State private var reloadRequest = UUID()

    nonisolated private static func export(entries: [HakoLogEntry], breadcrumbs: [HakoDiagnosticBreadcrumb], version: String) -> String {
        let header = "Hako 卡顿与崩溃诊断\n导出版本：\(version)\n导出时间：\(Date())\n诊断独立保留最近 \(HakoDiagnosticStore.capacity) 条，上限 8 MiB；操作轨迹保留最近 \(HakoDiagnosticStore.breadcrumbCapacity) 条。\n系统报告时间为接收时间，实际报告区间见正文。\n\n"
        let events = "\n\n最近操作轨迹（不保证与系统报告属于同一次故障）：\n" + breadcrumbs.map(\.text).joined(separator: "\n")
        return HakoLog.sanitize(header + entries.reversed().map(\.text).joined(separator: "\n\n") + events, limit: Int.max)
    }

    var body: some View {
        List {
            Section {
                Button {
                    UIPasteboard.general.setItems([["public.utf8-plain-text": report]], options: [.localOnly: true])
                    copied = true
                } label: {
                    Label(copied ? "已复制诊断记录" : "复制全部诊断记录", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .disabled(entries.isEmpty && breadcrumbs.isEmpty || clearing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
            } footer: {
                Text("前台主线程超过 2 秒未响应时自动记录，恢复后更新时长；另接收 iOS 卡顿与崩溃报告。按钮失效但主线程正常时可查看操作轨迹。本机诊断独立保留最近 \(HakoDiagnosticStore.capacity) 条，上限 8 MiB，不被普通日志挤掉。系统未提供的报告和调用栈不会补造。")
            }
            if let storageIssue { Section { Text(storageIssue).foregroundStyle(.orange) } }
            Section("\(entries.count) 条诊断记录 · 最新在前") {
                if entries.isEmpty {
                    ContentUnavailableView("暂无异常记录", systemImage: "waveform.path.ecg",
                        description: Text("检测到主线程阻塞、弹层切换超时或收到系统诊断时记录；没有异常记录不代表没有发生问题。"))
                }
                ForEach(entries) { entry in
                    NavigationLink { HakoLogDetailView(entry: entry, title: "诊断详情") } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.message).font(.subheadline.weight(.medium))
                            Text(entry.time, format: .dateTime.year().month().day().hour().minute().second())
                                .font(.caption).foregroundStyle(.secondary)
                            if let duration = entry.detail.split(separator: "\n", maxSplits: 1).first {
                                Text(String(duration)).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
            }
            Section("最近操作轨迹 · \(breadcrumbs.count) 条") {
                ForEach(Array(breadcrumbs.reversed().enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.event).font(.subheadline)
                        Text(item.time, format: .dateTime.hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                        if !item.detail.isEmpty { Text(item.detail).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                    .alignmentGuide(.listRowSeparatorTrailing) { $0.width }
                }
            }
        }
        .navigationTitle("卡顿诊断")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: report) { Label("分享诊断记录", systemImage: "square.and.arrow.up") }
                        .disabled(entries.isEmpty && breadcrumbs.isEmpty)
                    Button("清空诊断记录", systemImage: "trash", role: .destructive) { confirmingClear = true }
                        .disabled(entries.isEmpty && breadcrumbs.isEmpty || clearing)
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("卡顿诊断操作")
            }
        }
        .hakoDeleteConfirmation(Text("清空本机全部诊断报告和操作轨迹？"), isPresented: $confirmingClear) {
            clearing = true
            Task {
                await HakoDiagnosticStore.shared.clear()
                await reload()
                clearing = false
            }
        }
        .refreshable { await reload() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await reload()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                await reload()
            }
        }
        .privacySensitive()
    }

    private func reload() async {
        let request = UUID(); reloadRequest = request
        let snapshot = await HakoDiagnosticStore.shared.snapshot()
        guard !Task.isCancelled, reloadRequest == request else { return }
        storageIssue = snapshot.issue
        guard snapshot.reports.map(\.id) != entries.map(\.id) || snapshot.reports.map(\.updatedAt) != updatedAt ||
            snapshot.breadcrumbs.last?.time != breadcrumbs.last?.time else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        // Formatting retained system stacks and exporting several MiB must not
        // block the very main queue this page is intended to diagnose.
        let prepared = await Task.detached(priority: .utility) {
            let entries = snapshot.reports.map(\.entry)
            return (entries, Self.export(entries: entries, breadcrumbs: snapshot.breadcrumbs, version: version))
        }.value
        guard !Task.isCancelled, reloadRequest == request else { return }
        copied = false
        entries = prepared.0
        report = prepared.1
        updatedAt = snapshot.reports.map(\.updatedAt)
        breadcrumbs = snapshot.breadcrumbs
    }
}
