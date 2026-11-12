import Foundation

@main struct WorkshopCommandTests {
    static func main() throws {
        var command = WorkshopSavedCommand()
        precondition(!command.allowBackgroundProcesses)
        command.name = "Build"
        command.command = "xkode tasks submit --project App.xcodeproj"
        command.allowBackgroundProcesses = true
        let saved = try JSONEncoder().encode(command)
        let restored = try JSONDecoder().decode(WorkshopSavedCommand.self, from: saved)
        precondition(restored == command, "The background option must survive saving and pending-request retries")
        var edited = restored
        edited.allowBackgroundProcesses = false
        precondition(edited != command && command.allowBackgroundProcesses, "Editing must not change the submitted command snapshot")

        var oldCommand = try JSONSerialization.jsonObject(with: saved) as! [String: Any]
        oldCommand.removeValue(forKey: "allowBackgroundProcesses")
        let legacyBytes = try JSONSerialization.data(withJSONObject: oldCommand)
        do {
            _ = try JSONDecoder().decode(WorkshopSavedCommand.self, from: legacyBytes)
            preconditionFailure("Saved commands must include an explicit background option")
        } catch DecodingError.keyNotFound(let key, _) {
            precondition(key.stringValue == "allowBackgroundProcesses")
        }

        let response = #"{"id":"build","applicationId":"app","name":"Build","command":"submit","directory":"project","state":"succeeded","startedAt":1,"canStop":true,"allowBackgroundProcesses":true}"#
        let task = try JSONDecoder().decode(WorkshopCommandTask.self, from: Data(response.utf8))
        precondition(task.allowBackgroundProcesses && !task.active)
        print("PASS: command background defaults, required saved option and immutable request snapshots")
    }
}
