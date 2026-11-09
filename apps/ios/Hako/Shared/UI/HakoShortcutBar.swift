import SwiftUI
import UIKit

struct HakoShortcutBar<Content: View>: View {
    private let fullScreen: Binding<Bool>?
    private let content: () -> Content

    init(fullScreen: Binding<Bool>? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.fullScreen = fullScreen
        self.content = content
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                content()
                if let fullScreen {
                    Button { fullScreen.wrappedValue.toggle() } label: {
                        Label(fullScreen.wrappedValue ? "退出全屏" : "全屏",
                              systemImage: fullScreen.wrappedValue
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right")
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .buttonStyle(.bordered).controlSize(.small).tint(.primary)
            .padding(.horizontal, 10)
            .background(HakoShortcutScrollAxisLock().allowsHitTesting(false))
        }
        .fixedSize(horizontal: false, vertical: true)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

// Apply to the shortcut bar's scroll view instead of the terminal or editor.
private struct HakoShortcutScrollAxisLock: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.lockAxis() }

    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            lockAxis()
        }

        func lockAxis() {
            DispatchQueue.main.async { [weak self] in
                var ancestor = self?.superview
                while let view = ancestor {
                    if let scroll = view as? UIScrollView {
                        scroll.alwaysBounceVertical = false
                        scroll.isDirectionalLockEnabled = true
                        return
                    }
                    ancestor = view.superview
                }
            }
        }
    }
}
