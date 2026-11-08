import SwiftUI

/// Portée en clé de sol qui défile de droite à gauche vers la ligne « maintenant ».
struct StaffView: View {
    let engine: LessonEngine
    let showNames: Bool

    var body: some View {
        // Lire l'état ici pour que SwiftUI redessine à chaque image.
        let beat = engine.beat
        let states = engine.states
        let pending = engine.mode == .learn ? engine.firstPending : nil
        let rhythm = engine.mode == .rhythm
        let notes = engine.notes
        let window = engine.window

        Canvas { ctx, size in
            draw(ctx, size: size, beat: beat, notes: notes, states: states,
                 pending: pending, rhythm: rhythm, window: window)
        }
        .card()
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .accessibilityLabel("Partition")
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, beat: Double, notes: [Note],
                      states: [LessonEngine.NoteState], pending: Int?, rhythm: Bool, window: Double) {
        let gap = min(18, size.height / 13)
        let top = size.height / 2 - 2 * gap - gap * 0.4
        func lineY(_ i: Int) -> CGFloat { top + CGFloat(i) * gap }
        let e4 = NoteName.staffStep(64)
        func y(_ step: Int) -> CGFloat { lineY(4) - CGFloat(step - e4) * gap / 2 }
        let pxPerBeat = gap * 6.5
        let cursorX = gap * 9
        func x(_ b: Double) -> CGFloat { cursorX + CGFloat(b - beat) * pxPerBeat }

        func line(_ a: CGPoint, _ b: CGPoint, _ color: Color, _ width: CGFloat) {
            var p = Path()
            p.move(to: a)
            p.addLine(to: b)
            ctx.stroke(p, with: .color(color), lineWidth: width)
        }

        // zone déjà jouée
        ctx.fill(Path(CGRect(x: 0, y: 0, width: cursorX, height: size.height)),
                 with: .color(Palette.accent.opacity(0.06)))

        // barres de mesure (4 temps)
        var b = max(0, Int((beat - 3).rounded(.down)))
        while x(Double(b)) < size.width {
            if b % 4 == 0 { line(CGPoint(x: x(Double(b)), y: lineY(0)), CGPoint(x: x(Double(b)), y: lineY(4)), Palette.line, 1.5) }
            b += 1
        }

        // portée
        for i in 0..<5 {
            line(CGPoint(x: 0, y: lineY(i)), CGPoint(x: size.width, y: lineY(i)), Palette.muted.opacity(0.7), 1)
        }

        // clé de sol
        ctx.draw(Text("𝄞").font(.system(size: gap * 5.4)).foregroundColor(Palette.fg),
                 at: CGPoint(x: gap * 2.4, y: lineY(2) + gap * 0.25))

        // curseur
        line(CGPoint(x: cursorX, y: lineY(0) - gap * 2), CGPoint(x: cursorX, y: lineY(4) + gap * 2), Palette.accent, 3)

        if beat < 0 {
            ctx.draw(Text("Décompte \(Int((-beat).rounded(.up)))").font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(Palette.muted),
                     at: CGPoint(x: cursorX, y: lineY(0) - gap * 2.8))
        }

        let midStep = NoteName.staffStep(71)
        for (i, n) in notes.enumerated() {
            let nx = x(n.beat)
            if nx < -60 || nx > size.width + 60 { continue }
            let step = NoteName.staffStep(n.midi)
            let ny = y(step)

            var color = Palette.fg
            switch states[i] {
            case .hit: color = Palette.good
            case .miss: color = Palette.bad
            case .pending:
                if i == pending || (rhythm && abs(n.beat - beat) <= window) { color = Palette.accent }
            }

            // lignes supplémentaires
            for ls in stride(from: NoteName.staffStep(60), to: e4, by: 2) where step <= ls {
                line(CGPoint(x: nx - gap * 0.8, y: y(ls)), CGPoint(x: nx + gap * 0.8, y: y(ls)), color, 1.5)
            }
            for ls in stride(from: NoteName.staffStep(81), through: NoteName.staffStep(84), by: 2) where step >= ls {
                line(CGPoint(x: nx - gap * 0.8, y: y(ls)), CGPoint(x: nx + gap * 0.8, y: y(ls)), color, 1.5)
            }

            // durée
            let barW = max(2, CGFloat(n.duration) * pxPerBeat - 8)
            ctx.fill(Path(roundedRect: CGRect(x: nx, y: ny - 3, width: barW, height: 6), cornerRadius: 3),
                     with: .color(color.opacity(0.18)))

            // tête de note
            let head = Path(ellipseIn: CGRect(x: -gap * 0.55, y: -gap * 0.4, width: gap * 1.1, height: gap * 0.8))
                .applying(CGAffineTransform(rotationAngle: -0.35).concatenating(CGAffineTransform(translationX: nx, y: ny)))
            if n.duration >= 2 {
                ctx.stroke(head, with: .color(color), lineWidth: 2.2)
            } else {
                ctx.fill(head, with: .color(color))
            }

            // hampe et crochet
            let up = step < midStep
            let stemX = up ? nx + gap * 0.48 : nx - gap * 0.48
            let stemEnd = up ? ny - gap * 3.3 : ny + gap * 3.3
            if n.duration < 4 {
                line(CGPoint(x: stemX, y: ny), CGPoint(x: stemX, y: stemEnd), color, 1.6)
            }
            if n.duration < 1 {
                var flag = Path()
                flag.move(to: CGPoint(x: stemX, y: stemEnd))
                let dir: CGFloat = up ? 1 : -1
                flag.addQuadCurve(to: CGPoint(x: stemX + gap * 0.5, y: stemEnd + dir * gap * 2.2),
                                  control: CGPoint(x: stemX + gap * 0.9, y: stemEnd + dir * gap * 1.1))
                ctx.stroke(flag, with: .color(color), lineWidth: 1.6)
            }

            if NoteName.isBlack(n.midi) {
                ctx.draw(Text("♯").font(.system(size: gap * 1.1, weight: .semibold)).foregroundColor(color),
                         at: CGPoint(x: nx - gap * 1.3, y: ny))
            }
            if showNames {
                ctx.draw(Text(NoteName.name(n.midi)).font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(color),
                         at: CGPoint(x: nx, y: lineY(4) + gap * 3.6))
            }
        }
    }
}
