import SwiftUI

/// Une note affichée en « note tombante » (style Synthesia).
struct FallingNote: Hashable {
    enum Status { case pending, active, hit, miss }
    var midi: Int
    var start: Double      // secondes
    var duration: Double   // secondes
    var rightHand: Bool
    var status: Status = .pending
    var label: String? = nil
}

/// Les notes descendent du haut vers le clavier. La ligne du bas est l'instant présent.
/// Les colonnes sont alignées sur les touches de `PianoKeyboard` pour la même tessiture.
struct FallingNotesView: View {
    let notes: [FallingNote]
    let time: Double
    let range: ClosedRange<Int>
    var lookahead: Double = 3.0
    var showNames = true
    var countdown: Double? = nil

    var body: some View {
        Canvas { ctx, size in
            draw(ctx, size: size)
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Palette.line))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityLabel("Notes tombantes, \(notes.count) notes")
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize) {
        let whites = range.filter { !NoteName.isBlack($0) }
        guard !whites.isEmpty else { return }
        let ww = size.width / CGFloat(whites.count)
        let pxPerSec = size.height / CGFloat(lookahead)
        let hitLine = size.height - 2

        func column(_ midi: Int) -> (x: CGFloat, w: CGFloat, black: Bool)? {
            if NoteName.isBlack(midi) {
                guard let i = whites.firstIndex(of: midi - 1) else { return nil }
                let w = ww * 0.6
                return (CGFloat(i + 1) * ww - w / 2, w, true)
            }
            guard let i = whites.firstIndex(of: midi) else { return nil }
            return (CGFloat(i) * ww, ww, false)
        }

        // Colonnes : touches noires grisées, séparations aux Do.
        for m in range where NoteName.isBlack(m) {
            if let c = column(m) {
                ctx.fill(Path(CGRect(x: c.x, y: 0, width: c.w, height: size.height)),
                         with: .color(Palette.line.opacity(0.25)))
            }
        }
        for (i, m) in whites.enumerated() where m % 12 == 0 {
            var p = Path()
            p.move(to: CGPoint(x: CGFloat(i) * ww, y: 0))
            p.addLine(to: CGPoint(x: CGFloat(i) * ww, y: size.height))
            ctx.stroke(p, with: .color(Palette.line), lineWidth: 1)
            ctx.draw(Text(NoteName.full(m)).font(.system(size: 10, weight: .semibold)).foregroundColor(Palette.muted),
                     at: CGPoint(x: CGFloat(i) * ww + 14, y: size.height - 12))
        }

        // Repères de temps toutes les secondes
        let firstMark = ceil(time)
        var t = firstMark
        while t < time + lookahead {
            let y = hitLine - CGFloat(t - time) * pxPerSec
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(Palette.line.opacity(0.6)), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
            t += 1
        }

        // Notes, main gauche d'abord pour que la main droite passe devant
        for n in notes.sorted(by: { !$0.rightHand && $1.rightHand }) {
            let top = n.start + n.duration
            if top < time - 0.3 || n.start > time + lookahead { continue }
            guard let c = column(n.midi) else { continue }
            let yBottom = hitLine - CGFloat(n.start - time) * pxPerSec
            let yTop = hitLine - CGFloat(top - time) * pxPerSec
            let rect = CGRect(x: c.x + 2, y: min(yTop, hitLine), width: c.w - 4,
                              height: max(6, min(yBottom, hitLine + 8) - min(yTop, hitLine)))
            var color = n.rightHand ? Palette.accent : Palette.good
            var alpha = 1.0
            switch n.status {
            case .pending: alpha = n.start < time ? 0.35 : 0.95
            case .active: color = Palette.gold
            case .hit: alpha = 0.55
            case .miss: color = Palette.bad; alpha = 0.6
            }
            let path = Path(roundedRect: rect, cornerRadius: min(6, rect.width / 3))
            ctx.fill(path, with: .color(color.opacity(alpha)))
            ctx.stroke(path, with: .color(color), lineWidth: n.status == .active ? 2.5 : 1)
            if n.status == .hit {
                ctx.draw(Text("✓").font(.system(size: 11, weight: .bold)).foregroundColor(.white),
                         at: CGPoint(x: rect.midX, y: rect.maxY - 9))
            }
            if showNames, rect.height > 22, rect.width > 16 {
                let label = n.label ?? NoteName.name(n.midi)
                ctx.draw(Text(label).font(.system(size: min(12, rect.width * 0.45), weight: .bold)).foregroundColor(.white),
                         at: CGPoint(x: rect.midX, y: rect.minY + 12))
            }
        }

        // Ligne de frappe
        var line = Path()
        line.move(to: CGPoint(x: 0, y: hitLine))
        line.addLine(to: CGPoint(x: size.width, y: hitLine))
        ctx.stroke(line, with: .color(Palette.accent), lineWidth: 3)

        if let countdown, countdown > 0 {
            ctx.draw(Text("\(Int(countdown.rounded(.up)))")
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundColor(Palette.accent.opacity(0.8)),
                     at: CGPoint(x: size.width / 2, y: size.height / 2))
        }
    }
}
