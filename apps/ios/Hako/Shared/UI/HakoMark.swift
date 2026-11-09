import SwiftUI

/// A theme-aware vector version of the Hako cube for use inside the app.
struct HakoMark: Shape {
    func path(in rect: CGRect) -> Path {
        let top = CGPoint(x: rect.midX, y: rect.minY)
        let left = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.25)
        let right = CGPoint(x: rect.maxX, y: left.y)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let bottomLeft = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.75)
        let bottomRight = CGPoint(x: rect.maxX, y: bottomLeft.y)
        let bottom = CGPoint(x: rect.midX, y: rect.maxY)

        return Path { path in
            path.move(to: top)
            for point in [right, bottomRight, bottom, bottomLeft, left] {
                path.addLine(to: point)
            }
            path.closeSubpath()
            path.move(to: left)
            path.addLine(to: center)
            path.addLine(to: right)
            path.move(to: center)
            path.addLine(to: bottom)
        }
    }
}

#Preview("Light") {
    HomeView().preferredColorScheme(.light)
}

#Preview("Dark") {
    HomeView().preferredColorScheme(.dark)
}
