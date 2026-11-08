import Foundation

enum MIDIReadError: LocalizedError {
    case notMIDI, truncated, noNotes
    var errorDescription: String? {
        switch self {
        case .notMIDI: return "Ce fichier n'est pas un fichier MIDI (.mid)."
        case .truncated: return "Le fichier MIDI est incomplet ou abîmé."
        case .noNotes: return "Ce fichier MIDI ne contient aucune note."
        }
    }
}

/// Lit un fichier MIDI standard (formats 0 et 1) et renvoie les notes en secondes.
enum MIDIFileReader {
    struct Result {
        var notes: [TranscribedNote]
        var bpm: Double
        var title: String?
    }

    static func read(_ data: Data) throws -> Result {
        let bytes = [UInt8](data)
        var pos = 0
        func u32() throws -> Int {
            guard pos + 4 <= bytes.count else { throw MIDIReadError.truncated }
            let v = (Int(bytes[pos]) << 24) | (Int(bytes[pos + 1]) << 16) | (Int(bytes[pos + 2]) << 8) | Int(bytes[pos + 3])
            pos += 4
            return v
        }
        func u16() throws -> Int {
            guard pos + 2 <= bytes.count else { throw MIDIReadError.truncated }
            let v = (Int(bytes[pos]) << 8) | Int(bytes[pos + 1])
            pos += 2
            return v
        }
        guard bytes.count > 14, String(bytes: bytes[0..<4], encoding: .ascii) == "MThd" else { throw MIDIReadError.notMIDI }
        pos = 4
        let headerLength = try u32()
        _ = try u16() // format
        let trackCount = try u16()
        let division = try u16()
        pos = 8 + headerLength
        guard division & 0x8000 == 0 else { throw MIDIReadError.notMIDI } // SMPTE non géré
        let ticksPerQuarter = max(1, Double(division))

        struct RawNote { var midi: Int; var startTick: Int; var endTick: Int; var velocity: Int }
        struct TempoChange { var tick: Int; var microsecondsPerQuarter: Double }
        var tempos: [TempoChange] = [TempoChange(tick: 0, microsecondsPerQuarter: 500_000)]
        var raw: [RawNote] = []
        var title: String?

        for _ in 0..<trackCount {
            guard pos + 8 <= bytes.count, String(bytes: bytes[pos..<pos + 4], encoding: .ascii) == "MTrk" else { break }
            pos += 4
            let length = try u32()
            let end = min(bytes.count, pos + length)
            var tick = 0
            var status: UInt8 = 0
            var open: [Int: (tick: Int, velocity: Int)] = [:]  // clé : canal * 128 + note

            func vlq() throws -> Int {
                var value = 0
                while true {
                    guard pos < end else { throw MIDIReadError.truncated }
                    let b = bytes[pos]; pos += 1
                    value = (value << 7) | Int(b & 0x7F)
                    if b & 0x80 == 0 { return value }
                }
            }

            while pos < end {
                tick += try vlq()
                guard pos < end else { break }
                var b = bytes[pos]
                if b & 0x80 != 0 { status = b; pos += 1 } else { b = status } // running status
                if status == 0xFF {
                    guard pos < end else { break }
                    let type = bytes[pos]; pos += 1
                    let len = try vlq()
                    let dataEnd = min(end, pos + len)
                    if type == 0x51, len == 3, pos + 3 <= end {
                        let us = (Int(bytes[pos]) << 16) | (Int(bytes[pos + 1]) << 8) | Int(bytes[pos + 2])
                        tempos.append(TempoChange(tick: tick, microsecondsPerQuarter: Double(max(1, us))))
                    } else if type == 0x03, title == nil, len > 0 {
                        title = String(bytes: bytes[pos..<dataEnd], encoding: .utf8) ?? String(bytes: bytes[pos..<dataEnd], encoding: .isoLatin1)
                    }
                    pos = dataEnd
                } else if status == 0xF0 || status == 0xF7 {
                    let len = try vlq()
                    pos = min(end, pos + len)
                } else {
                    let kind = status & 0xF0
                    let channel = Int(status & 0x0F)
                    let dataLength = (kind == 0xC0 || kind == 0xD0) ? 1 : 2
                    guard pos + dataLength <= end else { break }
                    let d1 = Int(bytes[pos] & 0x7F)
                    let d2 = dataLength == 2 ? Int(bytes[pos + 1] & 0x7F) : 0
                    pos += dataLength
                    if channel == 9 { continue } // percussions
                    let key = channel * 128 + d1
                    if kind == 0x90 && d2 > 0 {
                        if let o = open[key] { raw.append(RawNote(midi: d1, startTick: o.tick, endTick: tick, velocity: o.velocity)) }
                        open[key] = (tick, d2)
                    } else if kind == 0x80 || (kind == 0x90 && d2 == 0) {
                        if let o = open[key] {
                            raw.append(RawNote(midi: d1, startTick: o.tick, endTick: tick, velocity: o.velocity))
                            open[key] = nil
                        }
                    }
                }
            }
            for (key, o) in open { raw.append(RawNote(midi: key % 128, startTick: o.tick, endTick: tick, velocity: o.velocity)) }
            pos = end
        }
        guard !raw.isEmpty else { throw MIDIReadError.noNotes }

        // Conversion ticks → secondes avec la carte des tempos
        tempos.sort { $0.tick < $1.tick }
        var segments: [(tick: Int, seconds: Double, us: Double)] = []
        var seconds = 0.0
        var lastTick = 0
        var us = 500_000.0
        for t in tempos {
            seconds += Double(t.tick - lastTick) / ticksPerQuarter * us / 1_000_000
            lastTick = t.tick
            us = t.microsecondsPerQuarter
            segments.append((t.tick, seconds, us))
        }
        func time(_ tick: Int) -> Double {
            var seg = segments[0]
            for s in segments where s.tick <= tick { seg = s }
            return seg.seconds + Double(tick - seg.tick) / ticksPerQuarter * seg.us / 1_000_000
        }
        let notes = raw.map { n -> TranscribedNote in
            let start = time(n.startTick)
            return TranscribedNote(midi: n.midi, start: start, duration: max(0.05, time(n.endTick) - start), velocity: n.velocity)
        }
        .sorted { $0.start == $1.start ? $0.midi < $1.midi : $0.start < $1.start }
        let firstTempo = segments.first?.us ?? 500_000
        return Result(notes: notes, bpm: (60_000_000 / firstTempo).rounded(), title: title)
    }
}

extension Lesson {
    /// La partition de la leçon convertie en notes chronométrées.
    var transcribedNotes: [TranscribedNote] {
        let spb = 60 / tempo
        return notes.map { TranscribedNote(midi: $0.midi, start: $0.beat * spb, duration: $0.duration * spb, velocity: 90) }
    }

    /// Fichier MIDI temporaire de la leçon, à partager vers Synthesia.
    func midiFileURL() -> URL? {
        let data = MIDIFileWriter.data(for: transcribedNotes, bpm: tempo, title: title, splitHands: false)
        let safe = title.folding(options: .diacriticInsensitive, locale: nil).replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe).mid")
        return (try? data.write(to: url, options: .atomic)) == nil ? nil : url
    }
}
