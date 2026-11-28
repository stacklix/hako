import SwiftUI

enum SportsApplicationModule {
    static let module = HakoApplicationModule(
        application: .sports, category: .life, subtitle: "运动趋势 · 每次记录 · GitHub 归档", icon: .asset("SportsIcon"),
        destination: { AnyView(SportsView()) })
}
