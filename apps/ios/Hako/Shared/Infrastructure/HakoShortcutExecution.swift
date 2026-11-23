enum HakoShortcutExecution {
    static let manual = TaskLocal<Bool>(wrappedValue: false)
    static var isManual: Bool { manual.get() }
    // An in-app trigger is not permission to bypass a child's schedule.
    // Only an explicit, single-task manual action supplies this override.
    static let scheduleOverride = TaskLocal<Bool>(wrappedValue: false)
    static var ignoresSchedule: Bool { scheduleOverride.get() }
}
