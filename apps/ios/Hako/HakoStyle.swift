import SwiftUI
import UIKit

// Shared neutral surfaces used by the home screen and sports module.
enum HakoStyle {
    static let background = adaptive(0xf5f5f7, 0x151517)
    static let card = adaptive(0xffffff, 0x242427)
    static let text = adaptive(0x202124, 0xf2f2f4)
    static let muted = adaptive(0x76777d, 0xaaaab0)
    static let line = adaptive(0xe9e9ee, 0x38383c)

    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}
