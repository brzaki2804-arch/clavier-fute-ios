import SwiftUI
import UIKit

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }
}

/// Palette : violet « touche guidée », or pour les étoiles, vert/rouge pour juste/faux.
enum Palette {
    static let bgUI = UIColor.dynamic(0xF6F4FB, 0x13111F)
    static let surfaceUI = UIColor.dynamic(0xFFFFFF, 0x1D1A2E)
    static let fgUI = UIColor.dynamic(0x1D1B2E, 0xF1EEFB)
    static let mutedUI = UIColor.dynamic(0x6B6880, 0x9B96B4)
    static let lineUI = UIColor.dynamic(0xDCD8EA, 0x2E2A45)
    static let accentUI = UIColor.dynamic(0x5B47E0, 0x8F7CFF)
    static let goldUI = UIColor.dynamic(0xE8A51C, 0xF3B640)
    static let goodUI = UIColor.dynamic(0x1F9D6A, 0x36C48A)
    static let badUI = UIColor.dynamic(0xD9453D, 0xFF6B63)
    static let keyWhiteUI = UIColor.dynamic(0xFBFAFF, 0xECE9F7)
    static let keyBlackUI = UIColor.dynamic(0x241F3A, 0x0D0B17)
    static let keyHintUI = UIColor.dynamic(0xC9C1FF, 0x6A57E8)
    static let keyDownUI = UIColor.dynamic(0xB4A8FF, 0x7D6CF0)

    static let bg = Color(bgUI)
    static let surface = Color(surfaceUI)
    static let fg = Color(fgUI)
    static let muted = Color(mutedUI)
    static let line = Color(lineUI)
    static let accent = Color(accentUI)
    static let gold = Color(goldUI)
    static let good = Color(goodUI)
    static let bad = Color(badUI)
}

struct StarsView: View {
    let count: Int
    var size: CGFloat = 15
    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...3, id: \.self) { i in
                Image(systemName: "star.fill")
                    .font(.system(size: size))
                    .foregroundStyle(i <= count ? Palette.gold : Palette.line)
            }
        }
        .accessibilityLabel("\(count) étoile\(count > 1 ? "s" : "") sur 3")
    }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line))
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}

enum Device {
    /// Lu une seule fois, depuis le fil principal (UIDevice est réservé au fil principal).
    static let isPhone: Bool = MainActor.assumeIsolated {
        UIDevice.current.userInterfaceIdiom == .phone
    }
    /// Tessiture du clavier des leçons : toutes les leçons tiennent entre Do4 et Fa5.
    static var lessonRange: ClosedRange<Int> { isPhone ? 60...77 : 60...84 }
}
