import SwiftUI

struct HakoUnderlineTabs<Selection: Hashable>: View {
    let title: String
    let options: [Selection]
    @Binding var selection: Selection
    let label: (Selection) -> String

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(options, id: \.self) { option in
                tab(option)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func tab(_ option: Selection) -> some View {
        let selected = selection == option
        return Button {
            selection = option
        } label: {
            VStack(spacing: 0) {
                Text(label(option))
                    .font(.subheadline)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 12)
                    .frame(minHeight: 44)
                Capsule()
                    .fill(selected ? Color.primary : Color.clear)
                    .frame(width: 28, height: 3)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
