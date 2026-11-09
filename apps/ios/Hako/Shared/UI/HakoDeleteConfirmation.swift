import SwiftUI

struct HakoDeleteConfirmation: View {
    let title: Text
    var message: Text? = nil
    let confirmTitle: Text
    var disabled = false
    var busy = false
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Image(systemName: "trash")
                    .font(.title2)
                    .foregroundStyle(.red)
                    .frame(width: 42, height: 42)
                    .background(.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                title.font(.headline).accessibilityAddTraits(.isHeader)
                if let message { message.font(.subheadline).foregroundStyle(.secondary) }

                VStack(spacing: 9) {
                    Button(role: .destructive, action: confirm) {
                        (busy ? Text("正在处理…") : confirmTitle).frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(disabled || busy)

                    Button(role: .cancel) { dismiss() } label: {
                        Text("取消").frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .buttonStyle(.bordered)
                    .tint(.gray)
                    .disabled(busy)
                }
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .padding(.top, 6)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20)
            .padding(.top, 28)
            .padding(.bottom, 12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.height(280)])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(busy)
    }
}

extension View {
    func hakoDeleteConfirmation(
        _ title: Text, isPresented: Binding<Bool>, message: Text? = nil, confirmTitle: Text,
        disabled: Bool = false, onDismiss: (() -> Void)? = nil, confirm: @escaping () -> Void
    ) -> some View {
        modifier(HakoDeleteConfirmationModifier(title: title, isPresented: isPresented, message: message,
            confirmTitle: confirmTitle, disabled: disabled, onDismiss: onDismiss, confirm: confirm))
    }
}

private struct HakoDeleteConfirmationModifier: ViewModifier {
    let title: Text
    @Binding var isPresented: Bool
    let message: Text?
    let confirmTitle: Text
    let disabled: Bool
    let onDismiss: (() -> Void)?
    let confirm: () -> Void
    @State private var confirmed = false

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            // Finish dismissing the confirmation before the action can close its presenter.
            if confirmed {
                confirmed = false
                confirm()
            }
            onDismiss?()
        }) {
            HakoDeleteConfirmation(title: title, message: message, confirmTitle: confirmTitle,
                                   disabled: disabled || confirmed) {
                confirmed = true
                isPresented = false
            }
        }
    }
}
