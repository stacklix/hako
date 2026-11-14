import SwiftUI

struct HakoLabeledValue: View {
    let label: String
    let value: String
    var monospaced = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(monospaced ? .footnote.monospaced() : .body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
