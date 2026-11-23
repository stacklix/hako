import Foundation

extension InvestmentBackup {
    static let applicationID = "investment"
    static let shortcutName = "记账投资数据备份"
    private static let dataKey = "investment.data-backup.file"

    static func backupFile() -> HakoBackupFile {
        guard let data = UserDefaults.standard.data(forKey: dataKey),
              let value = try? JSONDecoder().decode(HakoBackupFile.self, from: data) else {
            return HakoBackupFile(subdirectory: "投资记账", fileName: "投资记账-{date}-{time}.zip")
        }
        return value
    }

    static func saveBackupFile(_ destination: HakoBackupFile) throws {
        let resolved = try destination.resolved()
        guard resolved.fileName.lowercased().hasSuffix(".zip") else {
            throw HakoBackupError(message: "投资账本备份是 ZIP 压缩包，请使用 .zip 扩展名。")
        }
        UserDefaults.standard.set(try JSONEncoder().encode(destination), forKey: dataKey)
    }

    @MainActor static func backupData(at date: Date = Date()) async throws -> String {
        guard (HakoShortcutExecution.isManual && HakoShortcutExecution.ignoresSchedule) || InvestmentBackupSchedule.isDue(at: date) else {
            throw HakoShortcutSkip(reason: "当前不是北京时间周日，不执行记账投资数据备份。")
        }
        let destination = backupFile()
        _ = try destination.resolved()
        let data = try await HakoExecutionDiagnostics.measure("导出服务端投资账本", success: { "已取得账本 ZIP，\($0.count) 字节。" }) {
            try await InvestmentStore.shared.exportLedger()
        }
        let receipt = try await HakoExecutionDiagnostics.measure("提交主应用备份并校验各目的地", success: { $0.message }) {
            try await AppServices.dataBackup().backup(data: data, applicationID: applicationID,
                file: destination, mimeType: "application/zip", at: date)
        }
        return receipt.message
    }
}
