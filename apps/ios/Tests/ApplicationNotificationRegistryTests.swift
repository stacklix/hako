@main
struct ApplicationNotificationRegistryTests {
    struct Preview {
        let notice: String
        let onOpen: () -> Void
    }

    @MainActor
    final class Runtime {
        var visibleNotice: String?
    }

    @MainActor
    static func main() {
        let registry = ApplicationNotificationRegistry<String, Preview>()
        var created = 0
        var runtime: Runtime?
        var previews = 0
        var opened = 0

        func resolve() -> Runtime {
            if let runtime { return runtime }
            created += 1
            let value = Runtime()
            runtime = value
            return value
        }

        precondition(!registry.isViewing("notice", for: .codeWorkshop))
        precondition(registry.preview(for: "notice", destination: .codeWorkshop, onOpen: {}) == nil)
        registry.register(for: .codeWorkshop,
            isViewing: { resolve().visibleNotice == $0 },
            preview: { notice, onOpen in
                previews += 1
                return Preview(notice: notice, onOpen: onOpen)
            })
        precondition(created == 0 && previews == 0, "Registration must not create runtime or preview objects")
        precondition(!registry.isViewing("notice", for: .settings))
        precondition(registry.preview(for: "notice", destination: .settings, onOpen: {}) == nil)
        precondition(created == 0 && previews == 0, "An unrelated destination must not invoke child callbacks")

        precondition(!registry.isViewing("notice", for: .codeWorkshop))
        precondition(created == 1)
        runtime?.visibleNotice = "notice"
        precondition(registry.isViewing("notice", for: .codeWorkshop))
        precondition(!registry.isViewing("other-notice", for: .codeWorkshop))
        runtime?.visibleNotice = nil
        precondition(!registry.isViewing("notice", for: .codeWorkshop), "Visibility must be read for every notification")
        precondition(created == 1 && previews == 0, "Visibility checks must not construct a preview")

        let preview = registry.preview(for: "notice", destination: .codeWorkshop, onOpen: { opened += 1 })!
        precondition(preview.notice == "notice" && previews == 1)
        precondition(opened == 0, "Constructing a preview must not navigate")
        preview.onOpen()
        precondition(opened == 1, "The child preview must retain the host navigation callback")
        print("PASS: lazy notification registration, live visibility, destination isolation and deferred preview navigation")
    }
}
