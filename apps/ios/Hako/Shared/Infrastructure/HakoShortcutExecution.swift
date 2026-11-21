enum HakoShortcutExecution {
    static let manual = TaskLocal<Bool>(wrappedValue: false)
    static var isManual: Bool { manual.get() }
}
