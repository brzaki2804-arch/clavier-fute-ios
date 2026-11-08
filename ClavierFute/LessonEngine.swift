import SwiftUI
import QuartzCore
import Observation

/// Fait avancer la partition, vérifie les notes jouées et calcule le score.
@Observable
final class LessonEngine {
    enum Mode: String, CaseIterable, Identifiable {
        case learn = "Apprendre"
        case rhythm = "En rythme"
        var id: String { rawValue }
    }
    enum NoteState { case pending, hit, miss }
    enum Phase { case ready, countIn, playing, paused, listening, finished }
    enum Tone { case good, bad, hint }

    let lesson: Lesson
    let notes: [Note]
    let window = 0.3   // tolérance en temps pour le mode En rythme

    private(set) var states: [NoteState]
    private(set) var beat: Double = -4
    private(set) var phase: Phase = .ready
    var mode: Mode { didSet { if oldValue != mode { reset() } } }
    private(set) var hits = 0
    private(set) var wrong = 0
    private(set) var perfect = 0
    private(set) var feedback = ""
    private(set) var tone: Tone = .hint
    private(set) var flashes: [Int: Bool] = [:]
    private(set) var stars = 0
    private(set) var finalAccuracy = 0
    private(set) var newRecord = false

    @ObservationIgnored weak var hub: PianoHub?
    @ObservationIgnored var onFinish: ((_ stars: Int, _ accuracy: Int) -> Bool)?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval = 0
    @ObservationIgnored private var nextClick = -4
    @ObservationIgnored private var waiting = false

    private let praise = ["Bien !", "Super", "Parfait", "Continue", "Bravo"]

    init(lesson: Lesson, mode: Mode = .learn) {
        self.lesson = lesson
        self.notes = lesson.notes
        self.states = Array(repeating: .pending, count: lesson.notes.count)
        self.mode = mode
    }

    deinit { timer?.invalidate() }

    // MARK: Lecture d'état

    var endBeat: Double { notes.last.map { $0.beat + $0.duration } ?? 0 }
    var firstPending: Int? { states.firstIndex(of: .pending) }
    var doneCount: Int { states.filter { $0 != .pending }.count }

    var accuracy: Int? {
        let misses = states.filter { $0 == .miss }.count
        let total = hits + wrong + misses
        return total == 0 ? nil : Int((Double(hits) / Double(total) * 100).rounded())
    }

    /// Touche à mettre en surbrillance sur le clavier.
    var hintNote: Int? {
        switch phase {
        case .listening:
            return notes.last { $0.beat <= beat && $0.beat + $0.duration > beat }?.midi
        case .finished:
            return nil
        default:
            if mode == .learn { return firstPending.map { notes[$0].midi } }
            guard let i = states.indices.first(where: { states[$0] == .pending && notes[$0].beat - beat < 1 }) else { return nil }
            return notes[i].midi
        }
    }

    var primaryTitle: String {
        switch phase {
        case .ready, .listening: return "Démarrer"
        case .countIn, .playing: return "Pause"
        case .paused: return "Reprendre"
        case .finished: return "Rejouer"
        }
    }

    // MARK: Commandes

    func togglePlay() {
        switch phase {
        case .ready: begin()
        case .finished, .listening: reset(); begin()
        case .countIn, .playing: pause()
        case .paused: resume()
        }
    }

    func listen() {
        reset()
        phase = .listening
        beat = -0.5
        show("Écoute le morceau", .hint)
        startLink()
    }

    func reset() {
        stopLink()
        states = Array(repeating: .pending, count: notes.count)
        beat = -4
        hits = 0; wrong = 0; perfect = 0
        phase = .ready
        waiting = false
        nextClick = -4
        feedback = ""
        flashes = [:]
        newRecord = false
    }

    func stop() { stopLink() }

    private func begin() {
        phase = .countIn
        beat = -4
        nextClick = -4
        show(mode == .learn ? "Joue la touche en surbrillance" : "Prépare-toi…", .hint)
        startLink()
    }

    private func pause() {
        phase = .paused
        stopLink()
        show("En pause", .hint)
    }

    private func resume() {
        phase = beat < 0 ? .countIn : .playing
        startLink()
    }

    // MARK: Boucle

    /// Horloge à 60 images par seconde sur le fil principal.
    private func startLink() {
        stopLink()
        lastTimestamp = 0
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.tick(CACurrentMediaTime())
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopLink() {
        timer?.invalidate()
        timer = nil
    }

    private func tick(_ timestamp: CFTimeInterval) {
        let dt = lastTimestamp == 0 ? 0 : min(timestamp - lastTimestamp, 0.1)
        lastTimestamp = timestamp
        let secondsPerBeat = 60 / lesson.tempo

        switch phase {
        case .listening:
            let previous = beat
            beat += dt / secondsPerBeat
            for n in notes where n.beat > previous && n.beat <= beat {
                hub?.audio.play(n.midi, velocity: 90)
                let midi = n.midi
                DispatchQueue.main.asyncAfter(deadline: .now() + n.duration * secondsPerBeat * 0.95) { [weak self] in
                    self?.hub?.audio.release(midi)
                }
            }
            if beat > endBeat + 1 { reset() }

        case .countIn, .playing:
            if !waiting { beat += dt / secondsPerBeat }
            while Double(nextClick) <= beat + 0.02 {
                if nextClick < 0 {
                    hub?.audio.click(strong: nextClick == -4)
                    show("\(-nextClick)", .hint)
                } else if mode == .rhythm, hub?.metronome == true {
                    hub?.audio.click(strong: nextClick % 4 == 0)
                }
                if nextClick == 0 && phase == .countIn {
                    show(mode == .learn ? "À toi !" : "C'est parti", .hint)
                }
                nextClick += 1
            }
            if phase == .countIn && beat >= 0 { phase = .playing }

            if mode == .learn {
                if let i = firstPending {
                    if beat >= notes[i].beat {
                        beat = notes[i].beat
                        waiting = true
                    }
                } else {
                    finish()
                }
            } else {
                for i in states.indices where states[i] == .pending && notes[i].beat < beat - window {
                    states[i] = .miss
                    flash(notes[i].midi, ok: false)
                    show("Raté", .bad)
                }
                if beat > endBeat + 1 { finish() }
            }

        default:
            break
        }
    }

    // MARK: Notes jouées

    func input(_ midi: Int) {
        guard phase == .playing || (phase == .countIn && beat > -0.3) else { return }
        if mode == .learn {
            guard let i = firstPending else { return }
            if notes[i].midi == midi {
                states[i] = .hit
                hits += 1
                waiting = false
                flash(midi, ok: true)
                show(praise[hits % praise.count], .good)
            } else {
                wrong += 1
                flash(midi, ok: false)
                show("C'est \(NoteName.name(notes[i].midi)), pas \(NoteName.name(midi))", .bad)
            }
        } else {
            if let i = states.indices.first(where: {
                states[$0] == .pending && notes[$0].midi == midi && abs(notes[$0].beat - beat) <= window
            }) {
                states[i] = .hit
                hits += 1
                let delta = notes[i].beat - beat
                if abs(delta) < 0.12 {
                    perfect += 1
                    show("Parfait !", .good)
                } else {
                    show(delta > 0 ? "Un peu tôt" : "Un peu tard", .good)
                }
                flash(midi, ok: true)
            } else {
                wrong += 1
                flash(midi, ok: false)
            }
        }
    }

    private func finish() {
        stopLink()
        phase = .finished
        let a = accuracy ?? 0
        finalAccuracy = a
        stars = a >= 90 ? 3 : a >= 70 ? 2 : a >= 40 ? 1 : 0
        newRecord = onFinish?(stars, a) ?? false
        show(stars > 0 ? "Leçon validée" : "Il faut 40 % pour valider", stars > 0 ? .good : .bad)
    }

    private func flash(_ midi: Int, ok: Bool) {
        flashes[midi] = ok
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            if self?.flashes[midi] == ok { self?.flashes[midi] = nil }
        }
    }

    private func show(_ text: String, _ tone: Tone) {
        feedback = text
        self.tone = tone
    }
}
