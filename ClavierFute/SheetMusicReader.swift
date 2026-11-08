import UIKit
import PDFKit

/// Reconnaissance optique de partition, version simple :
/// portées, têtes de notes pleines (noires) et creuses (blanches), hauteur d'après la position sur la portée.
enum SheetMusicReader {
    enum StaffMode: String, CaseIterable, Identifiable {
        case auto = "Automatique"
        case treble = "Clé de sol seule"
        case grand = "Piano (sol + fa)"
        var id: String { rawValue }
    }

    static func read(url: URL, mode: StaffMode, bpm: Double, progress: @escaping (Double) -> Void) throws -> ScoreImportResult {
        let images = try renderPages(url: url, progress: progress)
        guard !images.isEmpty else { throw ScoreImportError.unreadable }
        var all: [TranscribedNote] = []
        var offsetBeats = 0.0
        var staffCount = 0
        for (i, image) in images.enumerated() {
            let page = try analyze(image: image, mode: mode)
            staffCount += page.staffCount
            for n in page.notes {
                all.append(TranscribedNote(midi: n.midi, start: (n.beat + offsetBeats) * 60 / bpm,
                                           duration: n.beats * 60 / bpm, velocity: 90))
            }
            offsetBeats += page.totalBeats
            progress(0.3 + 0.7 * Double(i + 1) / Double(images.count))
        }
        guard staffCount > 0 else { throw ScoreImportError.noStaff }
        guard !all.isEmpty else { throw ScoreImportError.noNotes }
        return ScoreImportResult(notes: AudioTranscriber.cleaned(all), bpm: bpm, title: nil, warnings: [
            "Rythmes approximatifs : noires (1 temps) et blanches (2 temps) seulement. Ajuste le tempo si besoin.",
            "Altérations, armure, liaisons et silences ne sont pas encore lus.",
            "Vérifie le résultat en notes tombantes avant de l'envoyer à Synthesia.",
        ])
    }

    // MARK: Rendu

    private static func renderPages(url: URL, progress: (Double) -> Void) throws -> [CGImage] {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else { throw ScoreImportError.unreadable }
            var out: [CGImage] = []
            let count = min(doc.pageCount, 12)
            for i in 0..<count {
                guard let page = doc.page(at: i) else { continue }
                let box = page.bounds(for: .mediaBox)
                let scale = 1700 / max(1, box.width)
                let size = CGSize(width: box.width * scale, height: box.height * scale)
                if let cg = page.thumbnail(of: size, for: .mediaBox).cgImage { out.append(cg) }
                progress(0.3 * Double(i + 1) / Double(count))
            }
            return out
        }
        guard let image = UIImage(contentsOfFile: url.path)?.cgImage else { throw ScoreImportError.unreadable }
        return [image]
    }

    // MARK: Analyse d'une page

    private struct PageResult { var notes: [(midi: Int, beat: Double, beats: Double)]; var totalBeats: Double; var staffCount: Int }
    private struct Staff { var lines: [Int]; var spacing: Double; var left: Int; var right: Int }
    private struct Head { var x: Double; var y: Double; var hollow: Bool }

    private static func analyze(image: CGImage, mode: StaffMode) throws -> PageResult {
        let w = image.width, h = image.height
        var gray = [UInt8](repeating: 255, count: w * h)
        let drawn: Bool = gray.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress,
                  let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw ScoreImportError.unreadable }

        // Binarisation (seuil sur l'histogramme)
        var hist = [Int](repeating: 0, count: 256)
        for v in gray { hist[Int(v)] += 1 }
        var lo = 0, hi = 255
        while lo < 255 && hist[lo] < w * h / 2000 { lo += 1 }
        while hi > 0 && hist[hi] < w * h / 2000 { hi -= 1 }
        let threshold = UInt8(max(40, min(200, lo + (hi - lo) * 55 / 100)))
        var dark = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) { dark[i] = gray[i] < threshold }

        // Lignes de portée : rangées très sombres
        var rowCount = [Int](repeating: 0, count: h)
        var colAny = [Bool](repeating: false, count: w)
        for y in 0..<h {
            var c = 0
            for x in 0..<w where dark[y * w + x] { c += 1; colAny[x] = true }
            rowCount[y] = c
        }
        guard let contentLeft = colAny.firstIndex(of: true), let contentRight = colAny.lastIndex(of: true), contentRight > contentLeft + 100
        else { throw ScoreImportError.noStaff }
        let minRow = Int(Double(contentRight - contentLeft) * 0.45)
        var lineRows: [(center: Int, thickness: Int)] = []
        var y = 0
        while y < h {
            if rowCount[y] >= minRow {
                var y2 = y
                while y2 + 1 < h && rowCount[y2 + 1] >= minRow { y2 += 1 }
                lineRows.append(((y + y2) / 2, y2 - y + 1))
                y = y2 + 1
            } else { y += 1 }
        }
        // Groupes de 5 lignes équidistantes
        var staves: [Staff] = []
        var i = 0
        while i + 4 < lineRows.count {
            let c = (0..<5).map { lineRows[i + $0].center }
            let gaps = (0..<4).map { Double(c[$0 + 1] - c[$0]) }
            let mean = gaps.reduce(0, +) / 4
            if mean > 4, gaps.allSatisfy({ abs($0 - mean) < mean * 0.25 }) {
                // Étendue horizontale de la portée : colonnes sombres sur la ligne centrale
                let mid = c[2]
                var left = contentLeft, right = contentRight
                while left < right && !dark[mid * w + left] { left += 1 }
                while right > left && !dark[mid * w + right] { right -= 1 }
                staves.append(Staff(lines: c, spacing: mean, left: left, right: right))
                i += 5
            } else { i += 1 }
        }
        guard !staves.isEmpty else { throw ScoreImportError.noStaff }

        // Effacement des lignes de portée (là où rien ne les traverse)
        var clean = dark
        for s in staves {
            for ly in s.lines {
                let t = max(1, lineRows.first(where: { $0.center == ly })?.thickness ?? 1)
                let y0 = max(0, ly - t / 2 - 1), y1 = min(h - 1, ly + t / 2 + 1)
                for x in 0..<w {
                    let above = y0 > 0 ? dark[(y0 - 1) * w + x] : false
                    let below = y1 < h - 1 ? dark[(y1 + 1) * w + x] : false
                    if !above && !below { for yy in y0...y1 { clean[yy * w + x] = false } }
                }
            }
        }

        // Mode de clé
        var grand = mode == .grand
        if mode == .auto, staves.count >= 2 {
            let gaps = (1..<staves.count).map { Double(staves[$0].lines[0] - staves[$0 - 1].lines[4]) }
            if staves.count == 2 { grand = gaps[0] < staves[0].spacing * 8 }
            else {
                var alternating = true
                for g in 0..<(gaps.count - 1) where (gaps[g] < gaps[g + 1]) != (g % 2 == 0) { alternating = false }
                grand = alternating && gaps[0] < gaps[1]
            }
        }

        // Têtes de notes par portée
        var notes: [(midi: Int, beat: Double, beats: Double)] = []
        var beatCursor = 0.0
        var systemHeads: [(head: Head, staff: Int)] = []

        func flushSystem() {
            guard !systemHeads.isEmpty else { return }
            let sorted = systemHeads.sorted { $0.head.x < $1.head.x }
            let s0 = staves[sorted[0].staff].spacing
            var groupStart = 0
            var k = 1
            func emit(_ group: ArraySlice<(head: Head, staff: Int)>) {
                var minBeats = 4.0
                for g in group {
                    let st = staves[g.staff]
                    let isBass = grand && (g.staff % 2 == 1)
                    let bottom = Double(st.lines[4])
                    let step = Int(((bottom - g.head.y) / (st.spacing / 2)).rounded())
                    let baseStep = isBass ? NoteName.staffStep(43) : NoteName.staffStep(64)
                    let midi = midiFromStep(baseStep + step)
                    let beats = g.head.hollow ? 2.0 : 1.0
                    minBeats = min(minBeats, beats)
                    if (21...108).contains(midi) { notes.append((midi, beatCursor, beats)) }
                }
                beatCursor += minBeats
            }
            while k <= sorted.count {
                if k == sorted.count || sorted[k].head.x - sorted[k - 1].head.x > s0 * 0.7 {
                    emit(sorted[groupStart..<k])
                    groupStart = k
                }
                k += 1
            }
            systemHeads.removeAll()
        }

        for (si, s) in staves.enumerated() {
            let heads = detectHeads(clean, w: w, h: h, staff: s)
            systemHeads.append(contentsOf: heads.map { ($0, si) })
            let lastOfSystem = !grand || si % 2 == 1 || si == staves.count - 1
            if lastOfSystem { flushSystem() }
        }
        return PageResult(notes: notes, totalBeats: beatCursor, staffCount: staves.count)
    }

    /// Hauteur MIDI (gamme de do majeur) depuis une position diatonique.
    private static func midiFromStep(_ step: Int) -> Int {
        let octave = Int(floor(Double(step) / 7))
        let degree = ((step % 7) + 7) % 7
        return (octave + 1) * 12 + [0, 2, 4, 5, 7, 9, 11][degree]
    }

    /// Cherche les têtes de notes : rangées de pixels sombres larges d'environ une tête, empilées sur la hauteur d'une tête.
    private static func detectHeads(_ dark: [Bool], w: Int, h: Int, staff: Staff) -> [Head] {
        let s = staff.spacing
        let top = max(0, staff.lines[0] - Int(s * 4)), bottom = min(h - 1, staff.lines[4] + Int(s * 4))
        let xStart = min(staff.right, staff.left + Int(s * 3.5))   // saute la clé
        let xEnd = staff.right
        guard bottom > top, xEnd > xStart else { return [] }
        let minRun = Int(s * 0.8), maxRun = Int(s * 2.0)
        struct Seg { var y: Int; var cx: Double; var hollow: Bool }
        var segs: [Seg] = []
        for y in top...bottom {
            var x = xStart
            var runs: [(a: Int, b: Int)] = []
            while x <= xEnd {
                if dark[y * w + x] {
                    var x2 = x
                    while x2 + 1 <= xEnd && dark[y * w + x2 + 1] { x2 += 1 }
                    runs.append((x, x2))
                    x = x2 + 1
                } else { x += 1 }
            }
            for (ri, r) in runs.enumerated() {
                let len = r.b - r.a + 1
                if len >= minRun && len <= maxRun {
                    segs.append(Seg(y: y, cx: Double(r.a + r.b) / 2, hollow: false))
                } else if len >= Int(s * 0.12) && len < minRun, ri + 1 < runs.count {
                    // Deux arcs d'une tête creuse
                    let n = runs[ri + 1]
                    let gap = n.a - r.b - 1
                    let span = n.b - r.a + 1
                    if gap >= Int(s * 0.2) && gap <= Int(s * 0.9) && span >= minRun && span <= maxRun && (n.b - n.a + 1) < minRun {
                        segs.append(Seg(y: y, cx: Double(r.a + n.b) / 2, hollow: true))
                    }
                }
            }
        }
        // Regroupement vertical
        var heads: [Head] = []
        var used = [Bool](repeating: false, count: segs.count)
        let order = segs.indices.sorted { segs[$0].y < segs[$1].y }
        for idx in order where !used[idx] {
            var members = [idx]
            used[idx] = true
            var lastY = segs[idx].y
            var cx = segs[idx].cx
            for j in order where !used[j] && segs[j].y > lastY && segs[j].y - lastY <= 2 && abs(segs[j].cx - cx) < s * 0.45 {
                members.append(j); used[j] = true; lastY = segs[j].y
                cx = (cx * Double(members.count - 1) + segs[j].cx) / Double(members.count)
            }
            let height = Double(segs[members.last!].y - segs[members.first!].y + 1)
            let hollowCount = members.filter { segs[$0].hollow }.count
            let hollow = hollowCount > members.count / 3
            let minHeight = hollow ? s * 0.6 : s * 0.65
            if height >= minHeight && height <= s * 1.5 {
                let ys = members.map { Double(segs[$0].y) }
                heads.append(Head(x: cx, y: (ys.min()! + ys.max()!) / 2, hollow: hollow))
            }
        }
        // Fusion de doublons proches (même tête détectée deux fois)
        var merged: [Head] = []
        for hd in heads.sorted(by: { $0.x < $1.x }) {
            if let last = merged.last, abs(last.x - hd.x) < s * 0.5, abs(last.y - hd.y) < s * 0.5 { continue }
            merged.append(hd)
        }
        return merged
    }
}
