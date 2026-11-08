import Foundation
import Compression

enum ScoreImportError: LocalizedError {
    case unreadable, noNotes, noStaff, unsupported

    var errorDescription: String? {
        switch self {
        case .unreadable: return "Ce fichier ne peut pas être lu."
        case .noNotes: return "Aucune note trouvée dans cette partition."
        case .noStaff: return "Aucune portée reconnue. Utilise une partition imprimée, nette, bien droite et en noir sur blanc."
        case .unsupported: return "Format non pris en charge. Utilise un PDF, une image, ou un fichier MusicXML (.musicxml, .xml, .mxl)."
        }
    }
}

struct ScoreImportResult {
    var notes: [TranscribedNote]
    var bpm: Double
    var title: String?
    var warnings: [String] = []
}

/// Lit une partition MusicXML (.musicxml, .xml) ou compressée (.mxl) : notes exactes.
enum MusicXMLReader {
    static func read(data: Data, isCompressed: Bool) throws -> ScoreImportResult {
        let xml = isCompressed ? try unzipFirstScore(data) : data
        let parser = XMLParser(data: xml)
        let delegate = Delegate()
        parser.delegate = delegate
        guard parser.parse() || !delegate.notes.isEmpty else { throw ScoreImportError.unreadable }
        guard !delegate.notes.isEmpty else { throw ScoreImportError.noNotes }
        let bpm = delegate.tempo ?? 100
        let spb = 60 / bpm
        let notes = delegate.notes.map {
            TranscribedNote(midi: $0.midi, start: $0.beat * spb, duration: max(0.1, $0.beats * spb), velocity: 90)
        }
        .sorted { $0.start == $1.start ? $0.midi < $1.midi : $0.start < $1.start }
        return ScoreImportResult(notes: AudioTranscriber.cleaned(notes), bpm: bpm, title: delegate.title)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        struct Raw { var midi: Int; var beat: Double; var beats: Double }
        var notes: [Raw] = []
        var tempo: Double?
        var title: String?

        private var text = ""
        private var divisions = 1.0
        private var cursor = 0.0           // en divisions, depuis le début de la partie
        private var measureStart = 0.0
        private var partOffsets: [String: Double] = [:]
        private var inNote = false
        private var isRest = false
        private var isChord = false
        private var isGrace = false
        private var step = "C", alter = 0, octave = 4
        private var duration = 0.0
        private var lastStart = 0.0
        private var inTitle = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            text = ""
            switch name {
            case "part": cursor = 0; measureStart = 0
            case "measure": measureStart = cursor
            case "note": inNote = true; isRest = false; isChord = false; isGrace = false; duration = 0; alter = 0
            case "rest": isRest = true
            case "chord": isChord = true
            case "grace": isGrace = true
            case "sound": if let t = attributes["tempo"], let v = Double(t), tempo == nil { tempo = v }
            case "work-title", "movement-title": inTitle = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "divisions": divisions = max(1, Double(value) ?? 1)
            case "step": if inNote { step = value }
            case "alter": if inNote { alter = Int(Double(value) ?? 0) }
            case "octave": if inNote { octave = Int(value) ?? 4 }
            case "duration": duration = Double(value) ?? 0
            case "per-minute": if tempo == nil, let v = Double(value) { tempo = v }
            case "work-title", "movement-title":
                if inTitle, title == nil, !value.isEmpty { title = value }
                inTitle = false
            case "backup": cursor -= duration; duration = 0
            case "forward": cursor += duration; duration = 0
            case "note":
                inNote = false
                guard !isGrace else { return }
                let start = isChord ? lastStart : cursor
                if !isRest, let base = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11][step] {
                    let midi = (octave + 1) * 12 + base + alter
                    if (21...108).contains(midi) {
                        notes.append(Raw(midi: midi, beat: start / divisions, beats: duration / divisions))
                    }
                }
                if !isChord { lastStart = start; cursor = start + duration }
            default: break
            }
        }
    }

    // MARK: Lecture minimale d'un .mxl (archive ZIP)

    private static func unzipFirstScore(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { i + 1 < b.count ? Int(b[i]) | Int(b[i + 1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { i + 3 < b.count ? Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 : 0 }
        // Fin du répertoire central
        var eocd = -1
        var i = b.count - 22
        while i >= max(0, b.count - 66_000) {
            if u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ScoreImportError.unreadable }
        var p = u32(eocd + 16)
        var candidates: [(name: String, method: Int, csize: Int, usize: Int, offset: Int)] = []
        while p + 46 <= b.count, u32(p) == 0x02014b50 {
            let method = u16(p + 10), csize = u32(p + 20), usize = u32(p + 24)
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            let offset = u32(p + 42)
            let name = String(bytes: b[(p + 46)..<min(b.count, p + 46 + nameLen)], encoding: .utf8) ?? ""
            candidates.append((name, method, csize, usize, offset))
            p += 46 + nameLen + extraLen + commentLen
        }
        guard let entry = candidates.first(where: { !$0.name.hasPrefix("META-INF") && ($0.name.hasSuffix(".xml") || $0.name.hasSuffix(".musicxml")) })
        else { throw ScoreImportError.unreadable }
        let lh = entry.offset
        guard u32(lh) == 0x04034b50 else { throw ScoreImportError.unreadable }
        let dataStart = lh + 30 + u16(lh + 26) + u16(lh + 28)
        guard dataStart + entry.csize <= b.count else { throw ScoreImportError.unreadable }
        let compressed = Array(b[dataStart..<(dataStart + entry.csize)])
        if entry.method == 0 { return Data(compressed) }
        guard entry.method == 8 else { throw ScoreImportError.unreadable }
        var out = [UInt8](repeating: 0, count: max(1, entry.usize))
        let written = compressed.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { throw ScoreImportError.unreadable }
        return Data(out[0..<written])
    }
}
