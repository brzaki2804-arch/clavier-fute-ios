import Foundation

/// Écrit un fichier MIDI standard (format 1), lisible par Synthesia, GarageBand, etc.
/// Piste 1 : tempo et mesure. Piste 2 : main droite (Do4 et au-dessus). Piste 3 : main gauche.
enum MIDIFileWriter {
    static let ticksPerQuarter = 480

    static func data(for notes: [TranscribedNote], bpm: Double, title: String, splitHands: Bool = true) -> Data {
        let tempo = max(20, min(300, bpm))
        func ticks(_ seconds: Double) -> Int {
            Int((seconds * tempo / 60 * Double(ticksPerQuarter)).rounded())
        }

        var tracks: [[UInt8]] = []

        // Piste de tempo
        let microsecondsPerQuarter = Int((60_000_000 / tempo).rounded())
        var tempoTrack: [UInt8] = []
        tempoTrack += metaText(0x03, title)
        tempoTrack += vlq(0) + [0xFF, 0x51, 0x03,
                                UInt8((microsecondsPerQuarter >> 16) & 0xFF),
                                UInt8((microsecondsPerQuarter >> 8) & 0xFF),
                                UInt8(microsecondsPerQuarter & 0xFF)]
        tempoTrack += vlq(0) + [0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08] // 4/4
        tempoTrack += vlq(0) + [0xFF, 0x2F, 0x00]
        tracks.append(tempoTrack)

        let groups: [(name: String, channel: UInt8, notes: [TranscribedNote])] = splitHands
            ? [("Main droite", 0, notes.filter { $0.midi >= 60 }),
               ("Main gauche", 1, notes.filter { $0.midi < 60 })]
            : [("Piano", 0, notes)]

        for group in groups where !group.notes.isEmpty {
            var events: [(tick: Int, order: Int, bytes: [UInt8])] = []
            for n in group.notes {
                let start = ticks(n.start)
                let end = max(start + 1, ticks(n.start + n.duration))
                let pitch = UInt8(max(0, min(127, n.midi)))
                let velocity = UInt8(max(1, min(127, n.velocity)))
                events.append((start, 1, [0x90 | group.channel, pitch, velocity]))
                events.append((end, 0, [0x80 | group.channel, pitch, 0x40]))
            }
            // À tick égal, les fins de note passent avant les débuts.
            events.sort { $0.tick != $1.tick ? $0.tick < $1.tick : $0.order < $1.order }

            var track: [UInt8] = []
            track += metaText(0x03, group.name)
            track += vlq(0) + [0xC0 | group.channel, 0x00] // piano acoustique
            var last = 0
            for e in events {
                track += vlq(e.tick - last) + e.bytes
                last = e.tick
            }
            track += vlq(0) + [0xFF, 0x2F, 0x00]
            tracks.append(track)
        }

        var out = Data("MThd".utf8)
        out += be32(6) + be16(1) + be16(tracks.count) + be16(ticksPerQuarter)
        for track in tracks {
            out += Data("MTrk".utf8)
            out += be32(track.count)
            out += Data(track)
        }
        return out
    }

    private static func metaText(_ type: UInt8, _ text: String) -> [UInt8] {
        // Les textes MIDI sont lus en ASCII par la plupart des logiciels : on retire les accents.
        let plain = text.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "fr_FR"))
        let bytes = Array(plain.unicodeScalars.filter { $0.isASCII }.map { UInt8($0.value) }.prefix(120))
        return vlq(0) + [0xFF, type] + vlq(bytes.count) + bytes
    }

    /// Quantité à longueur variable du format MIDI.
    static func vlq(_ value: Int) -> [UInt8] {
        var v = max(0, value)
        var bytes: [UInt8] = [UInt8(v & 0x7F)]
        v >>= 7
        while v > 0 {
            bytes.insert(UInt8(v & 0x7F) | 0x80, at: 0)
            v >>= 7
        }
        return bytes
    }

    private static func be32(_ v: Int) -> Data {
        Data([UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }

    private static func be16(_ v: Int) -> Data {
        Data([UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)])
    }
}
