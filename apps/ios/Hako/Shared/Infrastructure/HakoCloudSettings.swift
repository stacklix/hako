import Foundation
import Combine
import CryptoKit
import UIKit

@MainActor final class HakoCloudSettings: ObservableObject {
    static let shared = HakoCloudSettings()
    private static let metadataKey = "hako.icloud.preferenceState"
    private static let enabledKey = "hako.icloud.settingsEnabled"
    private static let backupVersionKey = "hako.icloud.backupPolicyVersion"
    private static let prefix = "hako.preference."
    private let defaults = UserDefaults.standard
    private let cloud = NSUbiquitousKeyValueStore.default
    private var writer: String
    private var state = CloudPreferenceState()
    private var ready = false
    private var started = false
    private var applying = false
    private var observers: [NSObjectProtocol] = []
    private var pending: Task<Void, Never>?
    private var settingsSyncTask: Task<Void, Never>?
    private let backupPreparation = HakoBackupPreparation()
    private var backupRevision = 0
    private var backupScopes = [HakoBackupScope(root: "HakoLogs", requiresHistory: true), HakoBackupScope(root: "ShortcutHistory", requiresHistory: true)]
    @Published private(set) var enabled: Bool
    @Published private(set) var includesHistory: Bool
    @Published private(set) var settingsStatus = "等待 iCloud 设置同步。"
    @Published private(set) var credentialStatus = "将在解锁后为已有凭据准备同步。"
    @Published private(set) var backupIssue: String?
    @Published private(set) var preparing = false
    @Published private(set) var lastReceivedAt: Date?

    private init() {
        let storage = UserDefaults.standard
        let installation = storage.string(forKey: "hako.icloud.installation") ?? UUID().uuidString
        storage.set(installation, forKey: "hako.icloud.installation")
        let device = UIDevice.current.identifierForVendor?.uuidString ?? "unavailable"
        writer = SHA256.hash(data: Data((installation + device).utf8)).map { String(format: "%02x", $0) }.joined()
        enabled = storage.object(forKey: Self.enabledKey) as? Bool ?? true
        includesHistory = storage.bool(forKey: HakoBackupPolicy.historyKey)
        if !enabled { settingsStatus = "此设备已暂停设置同步，已有云端数据保留。" }
        if let data = defaults.data(forKey: Self.metadataKey), let saved = try? JSONDecoder().decode(CloudPreferenceState.self, from: data) {
            state.records = saved.records.filter { $0.key == $0.value.key && CloudPreferenceState.valid($0.value) }
            state.pending = saved.pending.filter { state.records[$0] != nil }
            for key in state.pending {
                if let record = state.records[key], record.writer != writer {
                    state.records[key] = CloudPreferenceRecord(key: key, value: record.value, modifiedAt: record.modifiedAt, writer: writer)
                }
            }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        observers.append(NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int
            Task { @MainActor [weak self] in self?.received(reason) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.schedule() }
        })
        reconcile(publish: false, seedMissing: true)
        requestSettingsSync()
    }

    func registerBackupScopes(_ scopes: [HakoBackupScope]) {
        for scope in scopes where !backupScopes.contains(where: { $0.root == scope.root }) { backupScopes.append(scope) }
    }

    func setEnabled(_ value: Bool) {
        enabled = value; defaults.set(value, forKey: Self.enabledKey)
        if value { requestSettingsSync() }
        else { pending?.cancel(); settingsStatus = "此设备已暂停设置同步，已有云端数据保留。" }
    }

    func setIncludesHistory(_ value: Bool) {
        includesHistory = value; defaults.set(value, forKey: HakoBackupPolicy.historyKey)
        backupRevision += 1
        defaults.removeObject(forKey: Self.backupVersionKey)
        Task { await prepareBackup(force: true) }
    }

    func requestSettingsSync() {
        guard enabled, settingsSyncTask == nil else { return }
        settingsSyncTask = Task {
            defer { settingsSyncTask = nil }
            let synchronized = await Task.detached(priority: .utility) {
                NSUbiquitousKeyValueStore.default.synchronize()
            }.value
            guard enabled else { return }
            if synchronized { reconcile(publish: true) }
            else { settingsStatus = "暂时无法请求 iCloud 同步，请检查系统 iCloud 设置。" }
        }
    }

    func prepareForRecovery(recheckBackup: Bool = false) async {
        guard !preparing else { return }
        preparing = true
        defer { preparing = false }
        await prepareBackup(force: recheckBackup)
        let result = await Task.detached(priority: .utility) { SecureStorage.prepareCloudCredentials() }.value
        if result.failures.isEmpty {
            credentialStatus = "本次已为 \(result.prepared) 项原有凭据准备同步。新保存的密钥与连接配置会自动使用 iCloud 钥匙串。"
        } else {
            credentialStatus = "部分原有凭据暂未准备完成（OSStatus：\(result.failures.map(String.init).joined(separator: "、"))）。本机原值保留，请解锁后重试。"
        }
        requestSettingsSync()
    }

    private func prepareBackup(force: Bool = false) async {
        guard force || defaults.integer(forKey: Self.backupVersionKey) != 1 else { return }
        let revision = backupRevision, history = includesHistory, scopes = backupScopes
        defaults.removeObject(forKey: Self.backupVersionKey)
        do {
            guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
                throw CocoaError(.fileNoSuchFile)
            }
            try await backupPreparation.run {
                try HakoBackupPolicy.prepareExistingFiles(at: base, history: history, scopes: scopes)
            }
            guard revision == backupRevision else { return }
            defaults.set(1, forKey: Self.backupVersionKey)
            backupIssue = nil
        } catch {
            guard revision == backupRevision else { return }
            backupIssue = "部分本地文件的备份标记未能更新，请解锁后重试。"
        }
    }

    private func schedule() {
        guard enabled, !applying else { return }
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.reconcile(publish: true)
        }
    }

    private func received(_ reason: Int?) {
        if reason == NSUbiquitousKeyValueStoreAccountChange {
            ready = false; state = CloudPreferenceState()
            let installation = UUID().uuidString
            defaults.set(installation, forKey: "hako.icloud.installation")
            let device = UIDevice.current.identifierForVendor?.uuidString ?? "unavailable"
            writer = SHA256.hash(data: Data((installation + device).utf8)).map { String(format: "%02x", $0) }.joined()
            defaults.removeObject(forKey: Self.metadataKey)
            setEnabled(false)
            settingsStatus = "iCloud 账户已变更，设置同步已暂停。确认当前 Apple 账户后可重新开启。"
            return
        }
        guard enabled else { return }
        if reason == NSUbiquitousKeyValueStoreQuotaViolationChange {
            settingsStatus = "iCloud 设置空间不足，本机设置已保留，请减少大型配置后重试。"
            return
        }
        if reason == NSUbiquitousKeyValueStoreInitialSyncChange {
            reconcile(publish: false)
            pending?.cancel()
            pending = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.ready = true
                self?.reconcile(publish: true)
            }
            return
        }
        ready = true
        reconcile(publish: true)
    }

    private func reconcile(publish: Bool, seedMissing: Bool = false) {
        guard enabled else { return }
        applying = true
        defer { applying = false }
        let saved = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "me.stackli.hako") ?? [:]
        let local = CloudPreferenceState.allowedKeys.reduce(into: [String: CloudPreferenceValue]()) { result, key in
            if let object = saved[key], let value = CloudPreferenceState.value(object, key: key) { result[key] = value }
        }
        state.observe(local, now: .now, writer: writer, seedMissing: seedMissing)
        var remote: [String: CloudPreferenceRecord] = [:]
        var malformed = false
        for (slot, object) in cloud.dictionaryRepresentation where slot.hasPrefix(Self.prefix) {
            guard let data = object as? Data else { malformed = true; continue }
            guard data.count <= CloudPreferenceState.maximumRecordBytes,
                  let record = try? JSONDecoder().decode(CloudPreferenceRecord.self, from: data),
                  CloudPreferenceState.valid(record), slot == Self.slot(record) else { malformed = true; continue }
            if let previous = remote[record.key], previous.modifiedAt > record.modifiedAt
                || (previous.modifiedAt == record.modifiedAt && previous.writer >= record.writer) { continue }
            remote[record.key] = record
        }
        let changes = state.merge(remote)
        for change in changes {
            if let value = change.value { defaults.set(value.object, forKey: change.key) }
            else { defaults.removeObject(forKey: change.key) }
        }
        if !changes.isEmpty { lastReceivedAt = .now }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        persistState(encoder)
        guard publish else { return }
        if malformed { settingsStatus = "部分云端设置格式无效，已保留原数据并停止上传，请稍后重试。"; return }
        do {
            // Each installation owns separate seed/edit slots. Publishing an old
            // local seed cannot overwrite another device's not-yet-downloaded edits.
            let candidates = state.records.values.filter { $0.writer == writer && (state.pending.contains($0.key) || $0.isSeed || ready) }
            let encoded = try Dictionary(uniqueKeysWithValues: candidates.map { (Self.slot($0), try encoder.encode($0)) })
            var projected = cloud.dictionaryRepresentation.compactMapValues { $0 as? Data }
            for (slot, data) in encoded { projected[slot] = data }
            guard encoded.values.allSatisfy({ $0.count <= CloudPreferenceState.maximumRecordBytes }),
                  projected.count <= 900, projected.values.reduce(0, { $0 + $1.count }) <= CloudPreferenceState.maximumTotalBytes else {
                settingsStatus = "设置数据超过同步限额，本机修改已保留，未覆盖云端设置。"; return
            }
            for (slot, data) in encoded where cloud.data(forKey: slot) != data { cloud.set(data, forKey: slot) }
            state.pending.removeAll { key in candidates.contains { $0.key == key } }
            persistState(encoder)
            settingsStatus = "设置已交给 iCloud 管理。其他设备的接收时间由系统决定；部分连接设置下次启动生效。"
        } catch { settingsStatus = "设置暂时无法编码，本机修改已保留。" }
    }

    private static func slot(_ record: CloudPreferenceRecord) -> String {
        prefix + (record.isSeed ? "seed." : "edit.") + record.key + "." + record.writer
    }

    private func persistState(_ encoder: JSONEncoder) {
        if let data = try? encoder.encode(state), data != defaults.data(forKey: Self.metadataKey) {
            defaults.set(data, forKey: Self.metadataKey)
        }
    }
}
