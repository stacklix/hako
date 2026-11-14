import SwiftUI
import UIKit

struct AssistantPhotoPreview: View {
    let images: [Data]
    @State private var selection: Int

    init(images: [Data], selection: Int) {
        self.images = images
        _selection = State(initialValue: selection)
    }

    var body: some View {
        SettingsSheet(title: "图片 \(selection + 1)/\(images.count)") {
            TabView(selection: $selection) {
                ForEach(images.indices, id: \.self) { index in
                    Group {
                        if let image = UIImage(data: images[index]) {
                            AssistantImageZoom(image: image)
                                .accessibilityLabel("第 \(index + 1) 张图片，可双指缩放")
                        } else {
                            ContentUnavailableView("无法预览图片", systemImage: "photo")
                        }
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .background(HakoStyle.background)
        }
    }
}

private struct AssistantImageZoom: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = AssistantZoomScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.delegate = context.coordinator
        let picture = context.coordinator.picture
        scroll.picture = picture
        picture.contentMode = .scaleAspectFit
        picture.image = image
        scroll.addSubview(picture)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.picture.image = image
        scroll.setNeedsLayout()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let picture = UIImageView()

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            picture.center = CGPoint(x: max(scrollView.bounds.width, scrollView.contentSize.width) / 2,
                                     y: max(scrollView.bounds.height, scrollView.contentSize.height) / 2)
        }
    }
}

private final class AssistantZoomScrollView: UIScrollView {
    weak var picture: UIImageView?

    override func layoutSubviews() {
        super.layoutSubviews()
        if zoomScale == 1, picture?.frame != bounds {
            picture?.frame = bounds
            contentSize = bounds.size
        }
    }
}
