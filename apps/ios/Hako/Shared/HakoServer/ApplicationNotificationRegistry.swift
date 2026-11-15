/// Child apps register lazy callbacks; the host owns presentation and navigation.
@MainActor
final class ApplicationNotificationRegistry<Notice, Preview> {
    private struct Handler {
        let isViewing: (Notice) -> Bool
        let preview: (Notice, @escaping () -> Void) -> Preview
    }

    private var handlers: [RemoteNotificationDestination: Handler] = [:]

    func register(for destination: RemoteNotificationDestination,
                  isViewing: @escaping (Notice) -> Bool,
                  preview: @escaping (Notice, @escaping () -> Void) -> Preview) {
        precondition(handlers[destination] == nil, "Notification destination already registered")
        handlers[destination] = Handler(isViewing: isViewing, preview: preview)
    }

    func isViewing(_ notice: Notice, for destination: RemoteNotificationDestination) -> Bool {
        handlers[destination]?.isViewing(notice) ?? false
    }

    func preview(for notice: Notice, destination: RemoteNotificationDestination,
                 onOpen: @escaping () -> Void) -> Preview? {
        handlers[destination]?.preview(notice, onOpen)
    }
}
