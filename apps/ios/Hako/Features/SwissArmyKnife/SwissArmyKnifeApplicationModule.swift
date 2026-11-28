import SwiftUI

enum SwissArmyKnifeApplicationModule {
    static let module = HakoApplicationModule(
        application: .swissArmyKnife, category: .development, subtitle: "实用小工具 · 随机字符串与二维码扫描", icon: .asset("SwissArmyKnifeIcon"),
        destination: { AnyView(SwissArmyKnifeView()) })
}
