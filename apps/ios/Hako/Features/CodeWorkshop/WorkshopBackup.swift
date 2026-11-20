enum WorkshopBackup {
    static let scopes = [
        HakoBackupScope(root: "CodeWorkshop", includedFileSuffixes: [".draft.json", ".instructions.txt"]),
        HakoBackupScope(root: "WorkshopCommands", includedFileSuffixes: [".prompts.json"])
    ]
}
