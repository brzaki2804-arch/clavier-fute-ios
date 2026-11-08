import SwiftUI
import UIKit

/// Clavier multi-touch : plusieurs doigts, glissando, touches guidées.
struct PianoKeyboard: UIViewRepresentable {
    var range: ClosedRange<Int>
    var hints: Set<Int> = []
    var pressed: Set<Int> = []
    var flashes: [Int: Bool] = [:]
    var showNames = true
    var onDown: (Int) -> Void
    var onUp: (Int) -> Void

    func makeUIView(context: Context) -> KeyboardUIView { KeyboardUIView() }

    func updateUIView(_ view: KeyboardUIView, context: Context) {
        view.range = range
        view.hints = hints
        view.pressed = pressed
        view.flashes = flashes
        view.showNames = showNames
        view.onDown = onDown
        view.onUp = onUp
        view.setNeedsDisplay()
    }
}

final class KeyboardUIView: UIView {
    var range: ClosedRange<Int> = 60...84
    var hints: Set<Int> = []
    var pressed: Set<Int> = []
    var flashes: [Int: Bool] = [:]
    var showNames = true
    var onDown: ((Int) -> Void)?
    var onUp: ((Int) -> Void)?

    private var touchNotes: [UITouch: Int] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        contentMode = .redraw
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) non utilisé") }

    private var whites: [Int] { range.filter { !NoteName.isBlack($0) } }
    private var whiteWidth: CGFloat { bounds.width / CGFloat(max(1, whites.count)) }

    private func blackRect(_ midi: Int) -> CGRect? {
        guard let i = whites.firstIndex(of: midi - 1) else { return nil }
        let w = whiteWidth * 0.6
        return CGRect(x: CGFloat(i + 1) * whiteWidth - w / 2, y: 0, width: w, height: bounds.height * 0.6)
    }

    private func note(at p: CGPoint) -> Int? {
        guard bounds.contains(p) else { return nil }
        for m in range where NoteName.isBlack(m) {
            if let r = blackRect(m), r.contains(p) { return m }
        }
        let i = Int(p.x / whiteWidth)
        return i >= 0 && i < whites.count ? whites[i] : nil
    }

    private func fill(for midi: Int, black: Bool) -> UIColor {
        if let ok = flashes[midi] { return ok ? Palette.goodUI : Palette.badUI }
        if pressed.contains(midi) { return Palette.keyDownUI }
        if hints.contains(midi) { return black ? Palette.accentUI : Palette.keyHintUI }
        return black ? Palette.keyBlackUI : Palette.keyWhiteUI
    }

    override func draw(_ rect: CGRect) {
        let h = bounds.height
        let ww = whiteWidth
        Palette.keyBlackUI.setFill()
        UIBezierPath(roundedRect: bounds, byRoundingCorners: [.bottomLeft, .bottomRight],
                     cornerRadii: CGSize(width: 12, height: 12)).fill()

        let nameFont = UIFont.systemFont(ofSize: min(15, ww * 0.3), weight: .semibold)
        for (i, m) in whites.enumerated() {
            let r = CGRect(x: CGFloat(i) * ww + 1, y: 0, width: ww - 2, height: h - 2)
            fill(for: m, black: false).setFill()
            UIBezierPath(roundedRect: r, byRoundingCorners: [.bottomLeft, .bottomRight],
                         cornerRadii: CGSize(width: 8, height: 8)).fill()
            if hints.contains(m) && flashes[m] == nil {
                Palette.accentUI.setFill()
                UIBezierPath(roundedRect: CGRect(x: r.minX + 6, y: r.maxY - 12, width: r.width - 12, height: 6),
                             cornerRadius: 3).fill()
            }
            if showNames {
                let label = NoteName.name(m) + (m % 12 == 0 ? "\(m / 12 - 1)" : "")
                let color: UIColor = flashes[m] != nil ? .white : Palette.mutedUI
                draw(label, font: nameFont, color: color, centerX: r.midX, y: r.maxY - 38)
            }
        }

        let blackFont = UIFont.systemFont(ofSize: min(11, ww * 0.2), weight: .semibold)
        for m in range where NoteName.isBlack(m) {
            guard let r = blackRect(m) else { continue }
            fill(for: m, black: true).setFill()
            UIBezierPath(roundedRect: r, byRoundingCorners: [.bottomLeft, .bottomRight],
                         cornerRadii: CGSize(width: 5, height: 5)).fill()
            if showNames && (hints.contains(m) || flashes[m] != nil) {
                draw(NoteName.name(m), font: blackFont, color: .white, centerX: r.midX, y: r.maxY - 22)
            }
        }
    }

    private func draw(_ text: String, font: UIFont, color: UIColor, centerX: CGFloat, y: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: centerX - size.width / 2, y: y), withAttributes: attrs)
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if let m = note(at: t.location(in: self)) {
                touchNotes[t] = m
                onDown?(m)
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let new = note(at: t.location(in: self))
            let old = touchNotes[t]
            if new != old {
                if let old { onUp?(old) }
                if let new { onDown?(new) }
                touchNotes[t] = new
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lift(touches) }

    private func lift(_ touches: Set<UITouch>) {
        for t in touches {
            if let m = touchNotes[t] { onUp?(m) }
            touchNotes[t] = nil
        }
    }
}
