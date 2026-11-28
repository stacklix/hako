import SwiftUI
import UIKit

/// The single application-icon rendering path for home, ordering and notices.
/// Load transparent PNGs directly, keeping template alpha out of CAR conversion.
/// The surrounding foreground style supplies the light/dark appearance color.
struct HakoApplicationIcon: View {
    let application: HakoApplications.Application?
    var size: CGFloat = 24

    private var image: UIImage? {
        if case .asset(let name) = application?.icon,
           let url = Bundle.main.url(forResource: name + "Template@3x", withExtension: "png") {
            return UIImage(contentsOfFile: url.path)
        }
        return nil
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).renderingMode(.template).resizable().scaledToFit()
            } else {
                Image(systemName: "square.dashed").renderingMode(.template).resizable().scaledToFit().padding(3)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
