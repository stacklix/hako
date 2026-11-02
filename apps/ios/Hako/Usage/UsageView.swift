import SwiftUI
import SwiftData
import FamilyControls
import ManagedSettings

struct UsageEntry: View {
    var body: some View {
        switch UsageDatabase.shared {
        case .success(let container): UsageView().modelContainer(container)
        case .failure(let error):
            ContentUnavailableView("使用时间数据库无法打开", systemImage: "externaldrive.badge.exclamationmark",
                                   description: Text(error.localizedDescription))
                .navigationTitle("使用时间")
        }
    }
}

struct UsageView: View {
    @ObservedObject private var authorization = AuthorizationCenter.shared
    @State private var installedApplications: [String: Application] = [:]
    @Query(sort: \DailyUsage.day, order: .reverse) private var records: [DailyUsage]
    @State private var busy = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var selectedDay: String?
    @State private var showDatePicker = false
    @ScaledMetric(relativeTo: .body) private var dateRowHeight = 44
    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private var activeDay: String? { selectedDay ?? records.first?.day }
    private var selectedRecord: DailyUsage? { records.first { $0.day == activeDay } }
    var body: some View {
        List {
            Section {
                Button { execute { try await Recorder.shared.run(collect: true, requestAuthorization: true) } } label: { Label("获取app使用时间并同步", systemImage: "arrow.down.doc") }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                Button { execute { try await Recorder.shared.run(collect: false) } } label: { Label("合并本地与 GitHub 记录", systemImage: "arrow.triangle.2.circlepath") }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                if busy { ProgressView("正在处理…") }
            } footer: {
                Text("合并会补齐双方缺失的日期并保存到本地；同一天内容不一致时，以 GitHub 记录为准。")
            }.disabled(busy)
            if let message {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: messageIsError ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(messageIsError ? .orange : .green)
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button { self.message = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("关闭提示")
                    }
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                }
            }
            if records.isEmpty {
                ContentUnavailableView("还没有记录", systemImage: "clock", description: Text("点击「获取app使用时间并同步」开始，或点击「合并本地与 GitHub 记录」恢复历史记录。GitHub 仓库可在设置中配置。"))
            }
            if let oldest = records.last.flatMap({ Self.dayFormatter.date(from: $0.day) }),
               let newest = records.first.flatMap({ Self.dayFormatter.date(from: $0.day) }) {
                Section {
                    HStack {
                        Text("日期")
                        Spacer()
                        Button { showDatePicker = true } label: {
                            Label(activeDay ?? "选择日期", systemImage: "calendar")
                        }
                        .buttonStyle(.borderless)
                    }
                    .frame(height: dateRowHeight)
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    .popover(isPresented: $showDatePicker) {
                            DatePicker("日期", selection: Binding(
                                get: { activeDay.flatMap { Self.dayFormatter.date(from: $0) } ?? newest },
                                set: {
                                    selectedDay = Self.dayFormatter.string(from: $0)
                                    showDatePicker = false
                                }
                            ), in: oldest...newest, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .environment(\.calendar, Calendar(identifier: .gregorian))
                            .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                            .frame(width: 320)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(8)
                            .presentationCompactAdaptation(.popover)
                    }
                }
            }
            if let record = selectedRecord {
                Section {
                    LabeledContent("总使用时间", value: duration(record.totalSeconds)).font(.headline)
                    ForEach(Array(record.apps.enumerated()), id: \.offset) { index, app in
                        HStack {
                            Text(String(index + 1)).monospacedDigit().foregroundStyle(.secondary)
                            appTitle(app).lineLimit(2)
                            Spacer()
                            Text(duration(app.seconds)).foregroundStyle(.secondary)
                        }
                    }
                    Label(record.syncedAt == nil ? "等待同步" : "已同步", systemImage: record.syncedAt == nil ? "arrow.clockwise" : "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                } header: { Text(record.day) } footer: { Text("时区：\(record.timeZone)") }
            } else if !records.isEmpty {
                ContentUnavailableView("这一天没有记录", systemImage: "calendar", description: Text("请选择其他日期查看。"))
            }
        }.navigationTitle("使用时间")
            .task(id: authorization.authorizationStatus) {
                installedApplications = await ScreenTime.installedApplications()
            }
            .onChange(of: records.first?.day) { _, _ in selectedDay = nil }
    }
    @ViewBuilder private func appTitle(_ app: AppUsage) -> some View {
        let installed = installedApplications[app.bundleID]
        let name = [installed?.localizedDisplayName, app.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != app.bundleID }
        let token = installed?.token ?? app.applicationTokenData.flatMap {
            try? JSONDecoder().decode(ApplicationToken.self, from: $0)
        }
        if let name {
            Text(name)
        } else if let token {
            Label(token).labelStyle(.titleOnly)
        } else {
            Text(app.bundleID)
        }
    }
    private func execute(_ action: @escaping @MainActor () async throws -> String) {
        busy = true
        message = nil
        Task {
            defer { busy = false }
            do {
                let result = try await action()
                messageIsError = false
                message = result
            } catch {
                messageIsError = true
                message = error.localizedDescription
            }
        }
    }
    private func duration(_ seconds: Double) -> String {
        let value = Int(seconds.rounded()); return "\(value / 3600)小时 \((value % 3600) / 60)分"
    }
}
