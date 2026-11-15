import Foundation

@main
struct HakoSecureTextBufferTests {
    static func main() {
        masksLoadedCredentialsAndPreservesToggles()
        editsTheCredentialInsteadOfTheMask()
        preservesUnicodeSelection()
        handlesEmptyReloadedAndInvalidInput()
        print("Secure credential masking tests passed")
    }

    static func masksLoadedCredentialsAndPreservesToggles() {
        let token = String(repeating: "a1B9", count: 16)
        var buffer = HakoSecureTextBuffer(text: token, isSecure: true)
        precondition(buffer.displayText == String(repeating: "•", count: 64))
        precondition(buffer.text == token && !buffer.displayText.contains("\n"))
        for _ in 0..<5 {
            buffer.synchronize(text: token, isSecure: false, selection: NSRange(location: 9, length: 7))
            precondition(buffer.displayText == token && buffer.selection == NSRange(location: 9, length: 7))
            buffer.synchronize(text: token, isSecure: true, selection: buffer.selection)
            precondition(buffer.displayText == String(repeating: "•", count: 64))
            precondition(buffer.text == token && buffer.selection == NSRange(location: 9, length: 7))
        }
    }

    static func editsTheCredentialInsteadOfTheMask() {
        var buffer = HakoSecureTextBuffer(text: "abCD", isSecure: true)
        precondition(buffer.replace(NSRange(location: 2, length: 0), with: "12+/="))
        precondition(buffer.text == "ab12+/=CD" && buffer.displayText == "•••••••••")
        precondition(buffer.selection == NSRange(location: 7, length: 0))
        precondition(buffer.replace(NSRange(location: 2, length: 5), with: "xy"))
        precondition(buffer.text == "abxyCD" && buffer.selection == NSRange(location: 4, length: 0))
        precondition(buffer.replace(NSRange(location: 3, length: 1), with: ""))
        precondition(buffer.text == "abxCD" && buffer.displayText == "•••••")
        buffer.synchronize(text: buffer.text, isSecure: false, selection: buffer.selection)
        precondition(buffer.replace(NSRange(location: 2, length: 1), with: "•"))
        precondition(buffer.text == "ab•CD")
        buffer.synchronize(text: buffer.text, isSecure: true, selection: buffer.selection)
        precondition(buffer.replace(NSRange(location: 0, length: 5), with: ""))
        precondition(buffer.text.isEmpty && buffer.displayText.isEmpty)
    }

    static func preservesUnicodeSelection() {
        var buffer = HakoSecureTextBuffer(text: "A🔑e\u{301}Z", isSecure: false)
        buffer.synchronize(text: buffer.text, isSecure: true, selection: NSRange(location: 1, length: 4))
        precondition(buffer.displayText == "••••" && buffer.selection == NSRange(location: 1, length: 2))
        buffer.synchronize(text: buffer.text, isSecure: false, selection: buffer.selection)
        precondition(buffer.selection == NSRange(location: 1, length: 4))
        buffer.synchronize(text: buffer.text, isSecure: true, selection: buffer.selection)
        precondition(buffer.replace(NSRange(location: 1, length: 1), with: ""))
        precondition(buffer.text == "Ae\u{301}Z" && buffer.displayText == "•••")
        precondition(buffer.replace(NSRange(location: 1, length: 1), with: "🧑‍💻"))
        precondition(buffer.text == "A🧑‍💻Z" && buffer.selection == NSRange(location: 2, length: 0))
    }

    static func handlesEmptyReloadedAndInvalidInput() {
        var buffer = HakoSecureTextBuffer(text: "", isSecure: true)
        precondition(buffer.displayText.isEmpty)
        buffer.synchronize(text: "new-key", isSecure: true, selection: buffer.selection)
        precondition(buffer.text == "new-key" && buffer.displayText == "•••••••")
        precondition(!buffer.replace(NSRange(location: NSNotFound, length: 0), with: "ignored"))
        precondition(!buffer.replace(NSRange(location: 6, length: Int.max), with: "ignored"))
        precondition(buffer.text == "new-key")
        precondition(buffer.replace(NSRange(location: 0, length: 7), with: "ab\ncd"))
        precondition(buffer.text == "ab\ncd" && buffer.displayText == "••\n••")
        buffer.synchronize(text: "", isSecure: true, selection: buffer.selection)
        precondition(buffer.displayText.isEmpty && buffer.selection == NSRange(location: 0, length: 0))
    }
}
