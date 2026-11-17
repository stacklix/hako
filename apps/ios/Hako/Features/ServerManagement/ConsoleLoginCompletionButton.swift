import SwiftUI

struct ConsoleLoginCompletionButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text("完成").font(.body.weight(.medium)).frame(minWidth: 104)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(.secondary)
    }
}
