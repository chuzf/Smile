import SwiftUI
import UIKit

enum AppColors {
    /// 暖橙 — 微笑罐主色 / 主 CTA
    static let warmOrange = Color(hex: "#E08A4A")
    /// 草绿 — 优势罐主色
    static let leafGreen = Color(hex: "#7AA350")
    /// 米色 — 主背景
    static let cream = Color(hex: "#FFF4E4")
    /// 浅暖橙 — 渐变底
    static let creamPeach = Color(hex: "#FFE9D0")
    /// 文字主色
    static let textPrimary = Color(hex: "#5A3A1F")
    /// 文字次要色
    static let textSecondary = Color(hex: "#937154")
    /// 卡片背景半透层
    static let cardSurface = Color.white.opacity(0.6)

    /// 主屏背景渐变
    static let backgroundGradient = LinearGradient(
        colors: [cream, creamPeach],
        startPoint: .top, endPoint: .bottom
    )

    static let customGroupPalette: [Color] = [
        Color(hex: "#D8A3C4"), Color(hex: "#A3C9E8"), Color(hex: "#E8C39E"),
        Color(hex: "#B8D8A8"), Color(hex: "#E89E9E"), Color(hex: "#B4A8D8"),
    ]
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit) else {
            self.init(red: 0.5, green: 0.5, blue: 0.5)
            return
        }
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    func toHexString() -> String {
        let uic = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uic.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int(r * 255), Int(g * 255), Int(b * 255))
    }
}
