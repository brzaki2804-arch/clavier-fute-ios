import AVFoundation
import Accelerate

struct TranscribedNote: Hashable {
    var midi: Int
    var start: Double      // secondes
    var duration: Double   // secondes
    var velocity: Int
}

enum TranscriptionMode: String, CaseIterable, Identifiable {
    case melody = "Mélodie"
    case chords = "Accords (expérimental)"
    var id: String { rawValue }

    var help: String {
        switch self {
        case .melody: return "Une note à la fois : voix, flûte, piano joué à une main. Le plus fiable."
        case .chords: return "Plusieurs notes en même temps. Utile pour un piano seul, moins précis sur une chanson complète."
        }
    }
}

enum TranscriptionError: LocalizedError {
    case unreadable, empty, noNotes

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Ce fichier ne peut pas être lu. Utilise un MP3, M4A, WAV ou AIFF sans protection."
        case .empty: return "Le fichier audio est vide."
        case .noNotes: return "Aucune note reconnue. Essaie un enregistrement plus net, ou augmente la sensibilité."
        }
    }
}

/// Transforme un fichier audio en notes (transcription automatique).
enum AudioTranscriber {
    static let maxSeconds = 600.0

    static func transcribe(url: URL, mode: TranscriptionMode, sensitivity: Double,
                           progress: @escaping (Double) -> Void) throws -> (notes: [TranscribedNote], duration: Double) {
        let (samples, rate) = try loadMono(url: url) { progress($0 * 0.2) }
        let duration = Double(samples.count) / rate
        let raw: [TranscribedNote]
        switch mode {
        case .melody: raw = melody(samples, sampleRate: rate, sensitivity: sensitivity) { progress(0.2 + $0 * 0.8) }
        case .chords: raw = chords(samples, sampleRate: rate, sensitivity: sensitivity) { progress(0.2 + $0 * 0.8) }
        }
        let notes = cleaned(raw)
        guard !notes.isEmpty else { throw TranscriptionError.noNotes }
        progress(1)
        return (notes, duration)
    }

    // MARK: Lecture du fichier

    /// Lit le fichier, le passe en mono et le ramène vers 22 kHz (suffisant pour les hauteurs de piano).
    static func loadMono(url: URL, progress: (Double) -> Void) throws -> ([Float], Double) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw TranscriptionError.unreadable }
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let sampleRate = format.sampleRate
        guard channels > 0, sampleRate > 0 else { throw TranscriptionError.unreadable }
        let factor = max(1, Int((sampleRate / 22_050).rounded()))
        let total = min(file.length, AVAudioFramePosition(maxSeconds * sampleRate))
        guard total > 0 else { throw TranscriptionError.empty }

        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw TranscriptionError.unreadable }
        var out: [Float] = []
        out.reserveCapacity(Int(total) / factor + 1)
        var acc: Float = 0
        var accCount = 0
        var read: AVAudioFramePosition = 0
        let inv = 1 / Float(channels * factor)

        while read < total {
            let want = AVAudioFrameCount(min(AVAudioFramePosition(chunk), total - read))
            do { try file.read(into: buffer, frameCount: want) } catch { throw TranscriptionError.unreadable }
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { throw TranscriptionError.unreadable }
            for i in 0..<n {
                for c in 0..<channels { acc += data[c][i] }
                accCount += 1
                if accCount == factor {
                    out.append(acc * inv)
                    acc = 0
                    accCount = 0
                }
            }
            read += AVAudioFramePosition(n)
            progress(Double(read) / Double(total))
        }
        guard !out.isEmpty else { throw TranscriptionError.empty }
        let peak = vDSP.maximumMagnitude(out)
        if peak > 0 { out = vDSP.multiply(0.9 / peak, out) }
        return (out, sampleRate / Double(factor))
    }

    // MARK: Mélodie (YIN, une note à la fois)

    static func melody(_ x: [Float], sampleRate sr: Double, sensitivity: Double,
                       progress: (Double) -> Void) -> [TranscribedNote] {
        let window = 1024, hop = 256
        guard x.count > window else { return [] }
        let minRMS = Float(0.03 - 0.025 * sensitivity)
        let frameCount = (x.count - window) / hop + 1
        var pitch = [Int](repeating: -1, count: frameCount)
        var level = [Float](repeating: 0, count: frameCount)

        x.withUnsafeBufferPointer { p in
            guard let base = p.baseAddress else { return }
            for f in 0..<frameCount {
                if let r = AudioManager.detectPitch(base + f * hop, count: window, sampleRate: sr, minRMS: minRMS) {
                    let m = 69 + 12 * log2(r.frequency / 440)
                    let rounded = Int(m.rounded())
                    if abs(m - Double(rounded)) < 0.45, (21...108).contains(rounded) { pitch[f] = rounded }
                    level[f] = r.rms
                }
                if f % 256 == 0 { progress(Double(f) / Double(frameCount)) }
            }
        }

        // Lissage : la valeur la plus fréquente sur 5 trames, pour effacer les erreurs ponctuelles.
        var smooth = pitch
        if frameCount > 4 {
            for f in 2..<(frameCount - 2) {
                var counts: [Int: Int] = [:]
                for k in (f - 2)...(f + 2) { counts[pitch[k], default: 0] += 1 }
                smooth[f] = counts.max { $0.value < $1.value }?.key ?? pitch[f]
            }
        }

        let frameSec = Double(hop) / sr
        let offset = Double(window) / 2 / sr
        var notes: [TranscribedNote] = []
        var current: (midi: Int, start: Int, peak: Float)?
        var silence = 0
        var previousLevel: Float = 0

        func close(_ end: Int) {
            guard let c = current else { return }
            if end - c.start >= 4 {
                notes.append(TranscribedNote(midi: c.midi,
                                             start: Double(c.start) * frameSec + offset,
                                             duration: Double(end - c.start) * frameSec,
                                             velocity: velocity(c.peak, reference: 0.35)))
            }
            current = nil
        }

        for f in 0..<frameCount {
            let m = smooth[f]
            let lv = level[f]
            if m >= 0 {
                silence = 0
                let attack = lv > previousLevel * 1.7 && lv > minRMS * 3
                if let c = current, c.midi == m, !(attack && f - c.start > 6) {
                    current?.peak = max(c.peak, lv)
                } else {
                    close(f)
                    current = (m, f, lv)
                }
            } else {
                silence += 1
                if silence > 3, current != nil { close(f - silence + 1) }
            }
            previousLevel = lv
        }
        close(frameCount)
        return notes
    }

    // MARK: Accords (analyse spectrale, plusieurs notes)

    static func chords(_ x: [Float], sampleRate sr: Double, sensitivity: Double,
                       progress: (Double) -> Void) -> [TranscribedNote] {
        let n = 4096, half = n / 2, hop = 512
        guard x.count > n else { return [] }
        let log2n = vDSP_Length(12)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        let low = 45, high = 96   // La2 à Do7
        let pitchCount = high - low + 1
        let binHz = sr / Double(n)
        let frameCount = (x.count - n) / hop + 1

        struct Band { let lo: Int; let hi: Int }
        var bands: [[Band]] = []
        for m in low...high {
            let f0 = 440 * pow(2, Double(m - 69) / 12)
            var harmonics: [Band] = []
            for h in 1...5 {
                let f = f0 * Double(h)
                let lo = min(half - 1, max(1, Int(f * 0.985 / binHz)))
                let hi = min(half - 1, Int((f * 1.015 / binHz).rounded(.up)))
                harmonics.append(Band(lo: lo, hi: max(lo, hi)))
            }
            bands.append(harmonics)
        }
        let weights: [Float] = [1, 0.6, 0.4, 0.3, 0.2]

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var frame = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        var salience = [Float](repeating: 0, count: frameCount * pitchCount)

        x.withUnsafeBufferPointer { xp in
            guard let base = xp.baseAddress else { return }
            for f in 0..<frameCount {
                vDSP_vmul(base + f * hop, 1, window, 1, &frame, 1, vDSP_Length(n))
                real.withUnsafeMutableBufferPointer { rp in
                    imag.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        frame.withUnsafeBufferPointer { fp in
                            fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                                vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                            }
                        }
                        vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
                    }
                }
                for (pi, harmonics) in bands.enumerated() {
                    var sum: Float = 0
                    var fundamental: Float = 0
                    var strongest: Float = 0
                    for (h, band) in harmonics.enumerated() {
                        var e: Float = 0
                        for i in band.lo...band.hi where mags[i] > e { e = mags[i] }
                        if h == 0 { fundamental = e }
                        strongest = max(strongest, e)
                        sum += e * weights[h]
                    }
                    // Une vraie note a une fondamentale bien présente.
                    salience[f * pitchCount + pi] = fundamental >= 0.3 * strongest ? sum : 0
                }
                if f % 64 == 0 { progress(Double(f) / Double(frameCount) * 0.9) }
            }
        }

        let positive = salience.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else { return [] }
        let reference = positive[Int(Double(positive.count - 1) * 0.99)]
        let threshold = reference * Float(0.45 - 0.35 * sensitivity)

        var active = [Bool](repeating: false, count: frameCount * pitchCount)
        let suppress: [(Int, Float)] = [(12, 0.35), (19, 0.5), (24, 0.5), (28, 0.6)]
        for f in 0..<frameCount {
            var candidates = Array(salience[(f * pitchCount)..<((f + 1) * pitchCount)])
            let top = candidates.max() ?? 0
            guard top > threshold else { continue }
            for _ in 0..<4 {
                guard let best = candidates.indices.max(by: { candidates[$0] < candidates[$1] }) else { break }
                let value = candidates[best]
                guard value > threshold, value > top * 0.3 else { break }
                active[f * pitchCount + best] = true
                candidates[best] = 0
                if best > 0 { candidates[best - 1] = 0 }
                if best + 1 < pitchCount { candidates[best + 1] = 0 }
                for (interval, factor) in suppress where best + interval < pitchCount {
                    candidates[best + interval] *= factor
                }
            }
        }
        progress(0.95)

        let frameSec = Double(hop) / sr
        let offset = Double(n) / 2 / sr
        var notes: [TranscribedNote] = []
        for pi in 0..<pitchCount {
            var start = -1
            var gap = 0
            var peak: Float = 0
            for f in 0...frameCount {
                let on = f < frameCount && active[f * pitchCount + pi]
                if on {
                    if start < 0 { start = f; peak = 0 }
                    gap = 0
                    peak = max(peak, salience[f * pitchCount + pi])
                } else if start >= 0 {
                    gap += 1
                    if gap > 1 || f == frameCount {
                        let end = f - gap + 1
                        if end - start >= 3 {
                            notes.append(TranscribedNote(midi: low + pi,
                                                         start: Double(start) * frameSec + offset,
                                                         duration: Double(end - start) * frameSec,
                                                         velocity: velocity(peak, reference: reference)))
                        }
                        start = -1
                        gap = 0
                    }
                }
            }
        }
        return notes
    }

    // MARK: Outils

    private static func velocity(_ value: Float, reference: Float) -> Int {
        guard reference > 0 else { return 80 }
        return Int(40 + 87 * min(1, Double(value / reference)))
    }

    /// Aligne débuts et durées sur une grille de doubles croches.
    static func quantize(_ notes: [TranscribedNote], bpm: Double) -> [TranscribedNote] {
        let grid = 60 / bpm / 4
        let snapped = notes.map { n -> TranscribedNote in
            var q = n
            q.start = (n.start / grid).rounded() * grid
            q.duration = max(grid, (n.duration / grid).rounded() * grid)
            return q
        }
        return cleaned(snapped)
    }

    /// Supprime les doublons et raccourcit les notes de même hauteur qui se chevauchent.
    static func cleaned(_ notes: [TranscribedNote]) -> [TranscribedNote] {
        var byPitch: [Int: [TranscribedNote]] = [:]
        for n in notes { byPitch[n.midi, default: []].append(n) }
        var out: [TranscribedNote] = []
        for (_, list) in byPitch {
            let sorted = list.sorted { $0.start < $1.start }
            for (i, n) in sorted.enumerated() {
                var c = n
                if i + 1 < sorted.count { c.duration = min(c.duration, sorted[i + 1].start - c.start) }
                if c.duration > 0.02 { out.append(c) }
            }
        }
        out.sort { (a: TranscribedNote, b: TranscribedNote) -> Bool in
            if a.start == b.start { return a.midi < b.midi }
            return a.start < b.start
        }
        return out
    }

    /// Construit une leçon jouable dans l'app à partir de la mélodie (note la plus aiguë).
    static func lesson(from notes: [TranscribedNote], bpm: Double, title: String,
                       range: ClosedRange<Int>) -> Lesson? {
        var melodyLine: [TranscribedNote] = []
        for n in notes.sorted(by: { $0.start < $1.start }) {
            if let last = melodyLine.last, abs(last.start - n.start) < 0.05 {
                if n.midi > last.midi { melodyLine[melodyLine.count - 1] = n }
                continue
            }
            melodyLine.append(n)
        }
        guard !melodyLine.isEmpty else { return nil }
        melodyLine = Array(melodyLine.prefix(200))

        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let center = (range.lowerBound + range.upperBound) / 2
        let median = melodyLine.map(\.midi).sorted()[melodyLine.count / 2]
        let shift = Int((Double(center - median) / 12).rounded()) * 12
        func fit(_ m: Int) -> Int {
            var v = m + shift
            while v < range.lowerBound { v += 12 }
            while v > range.upperBound { v -= 12 }
            return v
        }
        let beatsPerSecond = bpm / 60
        func snap(_ beats: Double) -> Double { (beats * 4).rounded() / 4 }
        func fmt(_ v: Double) -> String { String(format: "%g", v) }

        let first = snap(melodyLine[0].start * beatsPerSecond)
        var tokens: [String] = []
        var cursor = 0.0
        for (i, n) in melodyLine.enumerated() {
            let beat = snap(n.start * beatsPerSecond) - first
            if beat < cursor - 0.001 { continue }
            if beat > cursor + 0.001 { tokens.append("R:\(fmt(beat - cursor))") }
            var length = max(0.25, snap(n.duration * beatsPerSecond))
            if i + 1 < melodyLine.count {
                let next = snap(melodyLine[i + 1].start * beatsPerSecond) - first
                if next > beat { length = min(length, next - beat) }
            }
            let m = fit(n.midi)
            tokens.append("\(names[m % 12])\(m / 12 - 1):\(fmt(length))")
            cursor = beat + length
        }
        guard !tokens.isEmpty else { return nil }
        return Lesson(id: "import-\(title)", title: title, tempo: bpm, score: tokens.joined(separator: " "))
    }
}
