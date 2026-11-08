import SwiftUI
import UniformTypeIdentifiers

/// Document MIDI pour l'enregistrement dans Fichiers.
struct MIDIDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.midi] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Écran « Audio → MIDI » : importe un MP3 (ou autre), le transcrit et l'exporte pour Synthesia.
struct TranscribeView: View {
    @Environment(PianoHub.self) private var hub
    @Binding var path: [Route]

    @State private var showImporter = false
    @State private var showMIDIImporter = false
    @State private var showScoreImporter = false
    @State private var staffMode: SheetMusicReader.StaffMode = .auto
    @State private var infoMessages: [String] = []
    @State private var showExporter = false
    @State private var fileURL: URL?
    @State private var fileName = ""
    @State private var mode: TranscriptionMode = .melody
    @State private var sensitivity = 0.5
    @State private var quantize = true
    @State private var bpm = 120.0
    @State private var splitHands = true
    @State private var isWorking = false
    @State private var progress = 0.0
    @State private var notes: [TranscribedNote] = []
    @State private var audioDuration = 0.0
    @State private var errorMessage: String?
    @State private var midiURL: URL?
    @State private var midiDocument: MIDIDocument?
    @State private var playTask: Task<Void, Never>?
    @State private var playStart: Date?

    private var baseName: String {
        let name = (fileName as NSString).deletingPathExtension
        return name.isEmpty ? "Morceau" : name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Importe un morceau audio : Clavier Futé reconnaît les notes et crée un fichier MIDI que tu peux ouvrir dans Synthesia, GarageBand ou tout logiciel de musique.")
                    .foregroundStyle(Palette.muted)

                scoreCard
                midiCard

                step(1, "Fichier audio") {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform").font(.title2).foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(fileURL == nil ? "Aucun fichier choisi" : fileName).font(.headline).lineLimit(1)
                            Text("MP3, M4A, WAV ou AIFF · jusqu'à 10 minutes").font(.caption).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Button(fileURL == nil ? "Choisir…" : "Changer…") { showImporter = true }
                            .buttonStyle(.bordered)
                    }
                }

                step(2, "Réglages") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("Type de musique", selection: $mode) {
                            ForEach(TranscriptionMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text(mode.help).font(.footnote).foregroundStyle(Palette.muted)

                        HStack {
                            Text("Sensibilité")
                            Slider(value: $sensitivity, in: 0...1)
                            Text(sensitivity < 0.34 ? "Faible" : sensitivity < 0.67 ? "Moyenne" : "Forte")
                                .font(.caption).foregroundStyle(Palette.muted).frame(width: 64)
                        }
                        Stepper(value: $bpm, in: 40...220, step: 1) {
                            Text("Tempo du fichier MIDI : \(Int(bpm)) BPM")
                        }
                        Toggle("Aligner les notes sur le tempo (quantification)", isOn: $quantize)
                        Toggle("Séparer main droite et main gauche (2 pistes)", isOn: $splitHands)
                    }
                }

                step(3, "Transcription") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            transcribe()
                        } label: {
                            Label(isWorking ? "Analyse en cours…" : "Reconnaître les notes", systemImage: "music.note.list")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(fileURL == nil || isWorking)

                        if isWorking {
                            ProgressView(value: progress)
                            Text("\(Int(progress * 100)) %").font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                        }
                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(Palette.bad).font(.subheadline)
                        }
                        ForEach(infoMessages, id: \.self) { message in
                            Label(message, systemImage: "info.circle").foregroundStyle(Palette.muted).font(.footnote)
                        }
                    }
                }

                if !notes.isEmpty { resultSection }
            }
            .padding(Device.isPhone ? 16 : 24)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.bg.ignoresSafeArea())
        .navigationTitle("Audio → MIDI")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): importFile(url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showScoreImporter,
                      allowedContentTypes: [.pdf, .image, .xml] + [UTType(filenameExtension: "musicxml"), UTType(filenameExtension: "mxl")].compactMap { $0 }) { result in
            switch result {
            case .success(let url): importScore(url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showMIDIImporter, allowedContentTypes: [.midi, .data]) { result in
            switch result {
            case .success(let url): importMIDI(url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $showExporter, document: midiDocument, contentType: .midi,
                      defaultFilename: baseName) { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .onDisappear { stopPlayback() }
    }

    // MARK: Résultat

    private var resultSection: some View {
        step(4, "Résultat") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 22) {
                    stat("\(notes.count)", "notes")
                    stat(timeString(audioDuration), "durée")
                    stat("\(notes.filter { $0.midi >= 60 }.count) / \(notes.filter { $0.midi < 60 }.count)", "main droite / gauche")
                }
                PianoRollView(notes: notes, duration: max(audioDuration, notes.map { $0.start + $0.duration }.max() ?? 0),
                              playStart: playStart)
                    .frame(height: Device.isPhone ? 180 : 240)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { resultButtons }
                    VStack(alignment: .leading, spacing: 10) { resultButtons }
                }

                Text("« Notes tombantes » joue le morceau comme dans Synthesia, directement dans l'app, avec un mode qui attend tes touches. Dans Synthesia : touche « Ouvrir dans Synthesia » puis choisis Synthesia dans la liste. Tu peux aussi enregistrer le fichier .mid dans Fichiers et l'ouvrir depuis Synthesia › Ajouter des morceaux.")
                    .font(.footnote).foregroundStyle(Palette.muted)
            }
        }
    }

    @ViewBuilder
    private var resultButtons: some View {
        Button {
            playStart == nil ? startPlayback() : stopPlayback()
        } label: {
            Label(playStart == nil ? "Écouter" : "Arrêter", systemImage: playStart == nil ? "play.fill" : "stop.fill")
        }
        .buttonStyle(.bordered)

        Button {
            stopPlayback()
            path.append(.falling(FallingSong(id: "transcription-\(baseName)", title: baseName, bpm: bpm, notes: notes)))
        } label: {
            Label("Notes tombantes", systemImage: "arrow.down.to.line")
        }
        .buttonStyle(.borderedProminent)

        if let midiURL {
            ShareLink(item: midiURL) {
                Label("Ouvrir dans Synthesia…", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
        }

        Button {
            showExporter = true
        } label: {
            Label("Enregistrer le .mid", systemImage: "folder")
        }
        .buttonStyle(.bordered)
        .disabled(midiDocument == nil)

        Button {
            practice()
        } label: {
            Label("S'entraîner dans l'app", systemImage: "graduationcap")
        }
        .buttonStyle(.bordered)
    }

    private var scoreCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2).foregroundStyle(Palette.accent)
                    .frame(width: 44, height: 44)
                    .background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Partition PDF, photo ou MusicXML").font(.headline)
                    Text("L'app lit la partition et la transforme en notes tombantes et en fichier MIDI pour Synthesia.")
                        .font(.subheadline).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Ouvrir…") { showScoreImporter = true }.buttonStyle(.borderedProminent).disabled(isWorking)
            }
            HStack {
                Text("Portées").font(.subheadline).foregroundStyle(Palette.muted)
                Picker("Portées", selection: $staffMode) {
                    ForEach(SheetMusicReader.StaffMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Text("PDF et photos : reconnaissance simple, fiable sur une partition imprimée nette, à une voix, en noires et blanches. MusicXML : lecture exacte, c'est le format à préférer quand il existe (MuseScore, Flat, etc.).")
                .font(.footnote).foregroundStyle(Palette.muted)
        }
        .padding(16)
        .card()
    }

    private func importScore(_ url: URL) {
        stopPlayback()
        errorMessage = nil
        infoMessages = []
        notes = []
        midiURL = nil
        midiDocument = nil
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            errorMessage = "Impossible d'ouvrir ce fichier : \(error.localizedDescription)"
            return
        }
        fileURL = nil
        fileName = url.lastPathComponent
        isWorking = true
        progress = 0
        let ext = url.pathExtension.lowercased()
        let mode = staffMode, bpm = bpm, splitHands = splitHands, title = baseName
        Task.detached(priority: .userInitiated) {
            do {
                let result: ScoreImportResult
                if ["xml", "musicxml", "mxl"].contains(ext) {
                    result = try MusicXMLReader.read(data: try Data(contentsOf: destination), isCompressed: ext == "mxl")
                } else if ["pdf", "png", "jpg", "jpeg", "heic", "tif", "tiff"].contains(ext) {
                    result = try SheetMusicReader.read(url: destination, mode: mode, bpm: bpm) { value in
                        DispatchQueue.main.async { progress = value }
                    }
                } else {
                    throw ScoreImportError.unsupported
                }
                let data = MIDIFileWriter.data(for: result.notes, bpm: result.bpm, title: result.title ?? title, splitHands: splitHands)
                let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(result.title ?? title).mid")
                try data.write(to: out, options: .atomic)
                await MainActor.run {
                    notes = result.notes
                    audioDuration = result.notes.map { $0.start + $0.duration }.max() ?? 0
                    midiURL = out
                    midiDocument = MIDIDocument(data: data)
                    infoMessages = result.warnings
                    if result.bpm > 0 { self.bpm = result.bpm }
                    isWorking = false
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    errorMessage = message
                    isWorking = false
                }
            }
        }
    }

    private var midiCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.down.to.line")
                .font(.title2).foregroundStyle(Palette.accent)
                .frame(width: 44, height: 44)
                .background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("Tu as déjà un fichier MIDI ?").font(.headline)
                Text("Ouvre un .mid, par exemple un morceau Synthesia, et joue-le en notes tombantes.")
                    .font(.subheadline).foregroundStyle(Palette.muted)
            }
            Spacer()
            Button("Ouvrir un .mid") { showMIDIImporter = true }.buttonStyle(.bordered)
        }
        .padding(16)
        .card()
    }

    private func importMIDI(_ url: URL) {
        errorMessage = nil
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let result = try MIDIFileReader.read(data)
            let name = result.title?.trimmingCharacters(in: .whitespaces).isEmpty == false
                ? result.title! : (url.lastPathComponent as NSString).deletingPathExtension
            path.append(.falling(FallingSong(id: "midi-\(url.lastPathComponent)", title: name, bpm: result.bpm, notes: result.notes)))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Actions

    private func importFile(_ url: URL) {
        stopPlayback()
        errorMessage = nil
        notes = []
        midiURL = nil
        midiDocument = nil
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            fileURL = destination
            fileName = url.lastPathComponent
        } catch {
            errorMessage = "Impossible d'ouvrir ce fichier : \(error.localizedDescription)"
        }
    }

    private func transcribe() {
        guard let url = fileURL else { return }
        stopPlayback()
        isWorking = true
        progress = 0
        errorMessage = nil
        notes = []
        midiURL = nil
        midiDocument = nil
        let mode = mode, sensitivity = sensitivity, quantize = quantize
        let bpm = bpm, splitHands = splitHands, title = baseName

        Task.detached(priority: .userInitiated) {
            do {
                let result = try AudioTranscriber.transcribe(url: url, mode: mode, sensitivity: sensitivity) { value in
                    DispatchQueue.main.async { progress = value }
                }
                let final = quantize ? AudioTranscriber.quantize(result.notes, bpm: bpm) : result.notes
                let data = MIDIFileWriter.data(for: final, bpm: bpm, title: title, splitHands: splitHands)
                let out = FileManager.default.temporaryDirectory.appendingPathComponent("\(title).mid")
                try data.write(to: out, options: .atomic)
                await MainActor.run {
                    notes = final
                    audioDuration = result.duration
                    midiURL = out
                    midiDocument = MIDIDocument(data: data)
                    isWorking = false
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    errorMessage = message
                    isWorking = false
                }
            }
        }
    }

    private func startPlayback() {
        stopPlayback()
        let sorted = notes.sorted { $0.start < $1.start }
        let audio = hub.audio
        let begin = Date()
        playStart = begin
        playTask = Task { @MainActor in
            for n in sorted {
                let wait = n.start - Date().timeIntervalSince(begin)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                if Task.isCancelled { return }
                audio.play(n.midi, velocity: n.velocity)
                let midi = n.midi
                DispatchQueue.main.asyncAfter(deadline: .now() + n.duration) { audio.release(midi) }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled {
                playStart = nil
                playTask = nil
            }
        }
    }

    private func stopPlayback() {
        playTask?.cancel()
        playTask = nil
        playStart = nil
    }

    private func practice() {
        stopPlayback()
        guard let lesson = AudioTranscriber.lesson(from: notes, bpm: bpm, title: baseName, range: Device.lessonRange) else {
            errorMessage = "Pas assez de notes pour créer une leçon."
            return
        }
        path.append(.lesson(lesson))
    }

    // MARK: Mise en page

    private func step<Content: View>(_ number: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Palette.accent, in: Circle())
                Text(title).font(.title3.weight(.bold)).foregroundStyle(Palette.fg)
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(Palette.fg)
            Text(label).font(.caption).foregroundStyle(Palette.muted)
        }
    }

    private func timeString(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Aperçu des notes reconnues : temps à l'horizontale, hauteur à la verticale.
struct PianoRollView: View {
    let notes: [TranscribedNote]
    let duration: Double
    let playStart: Date?

    var body: some View {
        let low = (notes.map(\.midi).min() ?? 60) - 2
        let high = (notes.map(\.midi).max() ?? 72) + 2
        TimelineView(.animation(minimumInterval: 1 / 30, paused: playStart == nil)) { context in
            Canvas { ctx, size in
                guard duration > 0, high > low else { return }
                let rowH = size.height / CGFloat(high - low + 1)
                let labelW: CGFloat = 34
                let plotW = size.width - labelW
                func x(_ t: Double) -> CGFloat { labelW + CGFloat(t / duration) * plotW }

                for m in low...high {
                    let y = CGFloat(high - m) * rowH
                    if NoteName.isBlack(m) {
                        ctx.fill(Path(CGRect(x: labelW, y: y, width: plotW, height: rowH)),
                                 with: .color(Palette.line.opacity(0.35)))
                    }
                    if m % 12 == 0 {
                        var line = Path()
                        line.move(to: CGPoint(x: labelW, y: y + rowH))
                        line.addLine(to: CGPoint(x: size.width, y: y + rowH))
                        ctx.stroke(line, with: .color(Palette.line), lineWidth: 1)
                        ctx.draw(Text(NoteName.full(m)).font(.system(size: 10, weight: .semibold)).foregroundColor(Palette.muted),
                                 at: CGPoint(x: labelW / 2, y: y + rowH / 2))
                    }
                }
                for n in notes {
                    let rect = CGRect(x: x(n.start), y: CGFloat(high - n.midi) * rowH + 0.5,
                                      width: max(2, CGFloat(n.duration / duration) * plotW), height: max(1.5, rowH - 1))
                    let color = n.midi >= 60 ? Palette.accent : Palette.good
                    ctx.fill(Path(roundedRect: rect, cornerRadius: min(2, rowH / 3)),
                             with: .color(color.opacity(0.45 + 0.55 * Double(n.velocity) / 127)))
                }
                if let start = playStart {
                    let t = context.date.timeIntervalSince(start)
                    var head = Path()
                    head.move(to: CGPoint(x: x(t), y: 0))
                    head.addLine(to: CGPoint(x: x(t), y: size.height))
                    ctx.stroke(head, with: .color(Palette.bad), lineWidth: 2)
                }
            }
        }
        .padding(8)
        .background(Palette.bg, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Aperçu des \(notes.count) notes reconnues")
    }
}
