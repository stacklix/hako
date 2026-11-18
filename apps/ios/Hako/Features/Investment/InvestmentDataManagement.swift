import SwiftUI

@MainActor
final class InvestmentDataManagementModel: ObservableObject {
    let store: InvestmentStore
    @Published var server = false
    @Published var state: InvestmentServerState? {
        didSet { inventory = Dictionary(uniqueKeysWithValues: InvestmentDataCategory.allCases.map { ($0, state.map($0.rows(in:)) ?? []) }) }
    }
    @Published var diskBytes: Int64 = 0
    private var inventory: [InvestmentDataCategory: [InvestmentCachedRow]] = [:]
    @Published var error: String?
    @Published var busy = false
    private var request = UUID()
    init(store: InvestmentStore) { self.store = store }
    func read() async {
        let token = UUID(); request = token
        let scope = store.dataCacheScope, server = server
        busy = true; error = nil; state = nil
        defer { if request == token { busy = false } }
        do {
            let value = try await store.managedData(fromServer: server)
            let bytes = server ? 0 : (try await store.localCacheBytes())
            guard request == token, scope == store.dataCacheScope, !Task.isCancelled else { return }
            state = value
            diskBytes = bytes
        } catch is CancellationError {} catch {
            if request == token { self.error = error.localizedDescription }
        }
    }
    func rows(_ category: InvestmentDataCategory) -> [InvestmentCachedRow] { inventory[category] ?? [] }
    func remove(_ category: InvestmentDataCategory?, rows: [InvestmentCachedRow]? = nil) async {
        guard !server, !busy else { return }
        let token = UUID(); request = token
        let scope = store.dataCacheScope
        busy = true
        defer { if request == token { busy = false } }
        do {
            try await store.deleteLocalData(category: category, rows: rows)
            let value = try await store.managedData(fromServer: false)
            let bytes = try await store.localCacheBytes()
            guard request == token, !server, scope == store.dataCacheScope else { return }
            state = value
            diskBytes = bytes
            error = nil
        } catch { if request == token { self.error = error.localizedDescription } }
    }
    static func size(_ rows: [InvestmentCachedRow]) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(rows.reduce(0) { $0 + $1.bytes }), countStyle: .file)
    }
}

struct InvestmentDataManagement: View {
    @ObservedObject var store: InvestmentStore
    @StateObject private var model: InvestmentDataManagementModel
    @State private var deleting = false
    init(store: InvestmentStore) {
        self.store = store
        _model = StateObject(wrappedValue: InvestmentDataManagementModel(store: store))
    }
    private var categories: [InvestmentDataCategory] {
        InvestmentDataCategory.allCases.filter { model.server || $0 != .ledger }
    }
    var body: some View {
        Form {
            Section {
                Picker("数据位置", selection: $model.server) {
                    Text("本机").tag(false); Text("服务端").tag(true)
                }.pickerStyle(.segmented)
                let rows = categories.flatMap(model.rows)
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.server ? "服务端已保存" : "本机磁盘缓存").font(.subheadline).foregroundStyle(.secondary)
                    Text(model.server ? InvestmentDataManagementModel.size(rows) : ByteCountFormatter.string(fromByteCount: model.diskBytes, countStyle: .file))
                        .font(.largeTitle.weight(.semibold))
                    Text("\(rows.count) 条记录").font(.caption).foregroundStyle(.secondary)
                    if !model.server {
                        Divider()
                        Text("本机磁盘 → 服务端 → 行情 API").font(.caption)
                    }
                }.padding(.vertical, 8).investmentListRow()
            } footer: {
                Text(model.server ? "查看当前登录账本在服务端实际保存的数据。" : "优先读取本机磁盘；缺失时从服务端补取，服务端缺失的行情再从 API 获取并保存。")
            }
            if model.busy { Section { ProgressView("正在读取数据…") } }
            if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
            if let error = store.cacheError { Section { Text(error).foregroundStyle(.red) } }
            ForEach(["账本记录", "行情与汇率", "快照"], id: \.self) { section in
                let members = categories.filter { $0.section == section }
                if !members.isEmpty {
                    Section(section) {
                        ForEach(members) { category in
                            NavigationLink {
                                InvestmentDataCategoryPage(model: model, category: category)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(category.title)
                                        Text("\(model.rows(category).count) 条记录").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(InvestmentDataManagementModel.size(model.rows(category)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.investmentListRow()
                        }
                    }
                }
            }
            if !model.server {
                Section {
                    HakoDeleteButton(title: "删除全部本机缓存") { deleting = true }
                        .disabled(model.busy || model.state == nil)
                        .listRowBackground(Color.clear)
                } footer: { Text("服务端数据及交易记录保留。后续读取时自动补取本机缺失的数据。") }
            }
        }
        .navigationTitle("数据管理")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(model.server)-\(store.dataCacheScope)") { await model.read() }
        .refreshable { await model.read() }
        .hakoDeleteConfirmation(Text("删除全部本机缓存？"), isPresented: $deleting,
            message: Text("只删除当前账号的本机缓存。服务端数据和交易记录保留，下次读取时自动重新获取。")) {
                Task { await model.remove(nil) }
            }
    }
}

private struct InvestmentDataCategoryPage: View {
    @ObservedObject var model: InvestmentDataManagementModel
    let category: InvestmentDataCategory
    @State private var deleting = false
    var body: some View {
        let rows = model.rows(category)
        let groups = Dictionary(grouping: rows, by: \.group)
        Form {
            Section {
                LabeledContent("数据位置", value: model.server ? "服务端" : "本机磁盘")
                LabeledContent("记录数", value: "\(rows.count) 条")
                LabeledContent("数据大小", value: InvestmentDataManagementModel.size(rows))
                if let first = rows.map(\.day).filter({ !$0.isEmpty }).min(), let last = rows.map(\.day).max() {
                    LabeledContent("数据范围", value: first + " 至 " + last)
                }
            }
            Section("数据明细") {
                if groups.isEmpty { Text("暂无数据").foregroundStyle(.secondary) }
                ForEach(groups.keys.sorted(), id: \.self) { group in
                    NavigationLink {
                        InvestmentDataRowsPage(model: model, category: category, group: group)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group)
                            Text("\(groups[group]?.count ?? 0) 条记录").font(.caption).foregroundStyle(.secondary)
                        }
                    }.investmentListRow()
                }
            }
            if !model.server {
                Section {
                    HakoDeleteButton(title: "删除此类本机缓存") { deleting = true }
                        .disabled(rows.isEmpty || model.busy).listRowBackground(Color.clear)
                }
            }
            if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
        }
        .navigationTitle(category.title).navigationBarTitleDisplayMode(.inline)
        .hakoDeleteConfirmation(Text("删除此类本机缓存？"), isPresented: $deleting,
            message: Text(category.title + "的本机副本将被清理；服务端数据保留。")) {
                Task { await model.remove(category) }
            }
    }
}

private struct InvestmentDataRowsPage: View {
    @ObservedObject var model: InvestmentDataManagementModel
    let category: InvestmentDataCategory
    let group: String
    @State private var limit = 60
    @State private var deleting = false
    var body: some View {
        let rows = model.rows(category).filter { $0.group == group }
        List {
            Section {
                if rows.isEmpty { Text("暂无数据").foregroundStyle(.secondary) }
                ForEach(rows.prefix(limit)) { row in
                    NavigationLink { InvestmentDataRecordPage(model: model, category: category, row: row) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(row.day.isEmpty ? row.fields["name"] ?? row.table : row.day); Spacer(); Text(row.value).monospacedDigit() }
                            Text(row.fields["source"] ?? "已保存记录").font(.caption).foregroundStyle(.secondary)
                        }
                    }.investmentListRow()
                }
                if rows.count > limit { Button("显示更多（剩余 \(rows.count - limit) 条）") { limit += 60 } }
            } footer: {
                Text(category.section == "行情与汇率" ? "展示实际取得的数据。缺失日期估值时沿用此前最近一次有效值。" : "按日期保存的投资账本记录。")
            }
            if !model.server {
                HakoDeleteButton(title: "删除此项本机缓存") { deleting = true }
                    .disabled(rows.isEmpty || model.busy).listRowBackground(Color.clear)
            }
        }
        .navigationTitle(group).navigationBarTitleDisplayMode(.inline)
        .hakoDeleteConfirmation(Text("删除此项本机缓存？"), isPresented: $deleting,
            message: Text("仅清理「\(group)」的本机缓存，服务端数据保留。")) {
                Task { await model.remove(category, rows: rows) }
            }
    }
}

private struct InvestmentDataRecordPage: View {
    @ObservedObject var model: InvestmentDataManagementModel
    let category: InvestmentDataCategory
    let row: InvestmentCachedRow
    @State private var deleting = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Form {
            Section {
                LabeledContent("数据位置", value: model.server ? "服务端" : "本机磁盘")
                ForEach(row.fields.keys.sorted(), id: \.self) { key in
                    LabeledContent(InvestmentAgentProposal.labels[key] ?? key, value: row.displayValue(for: key))
                        .textSelection(.enabled).investmentListRow()
                }
            }
            if !model.server {
                HakoDeleteButton(title: "删除这条本机缓存") { deleting = true }
                    .disabled(model.busy).listRowBackground(Color.clear)
            }
            if let error = model.error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle("数据详情").navigationBarTitleDisplayMode(.inline)
        .hakoDeleteConfirmation(Text("删除这条本机缓存？"), isPresented: $deleting,
            message: Text("服务端记录保留，下次访问时会自动补取。")) {
                Task { await model.remove(category, rows: [row]); if model.error == nil { dismiss() } }
            }
    }
}
