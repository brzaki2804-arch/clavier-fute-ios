import SwiftUI
import Observation

/// Point central : réunit écran tactile, MIDI et micro, et joue le son.
@Observable
final class PianoHub {
    @ObservationIgnored let audio = AudioManager()
    @ObservationIgnored let midi = MIDIInput()
    /// L'écran actif (leçon, piano libre) s'abonne ici pour recevoir les notes jouées.
    @ObservationIgnored var listener: ((Int) -> Void)?

    var pressed: Set<Int> = []
    var lastNote: Int?
    var micEnabled = false
    var micMessage: String?
    var volume: Double = 0.7 { didSet { audio.volume = Float(volume) } }
    var showNames = true
    var metronome = true
    /// Affichage des leçons : partition classique ou notes tombantes.
    var fallingNotes: Bool = LocalStore.load("fallingNotes") ?? false {
        didSet { LocalStore.save(fallingNotes, key: "fallingNotes") }
    }

    // MARK: MIDI
    var midiDevices: [MIDIDevice] = []
    var midiError: String?
    var midiToast: String?
    var midiActivity: [Int32: Date] = [:]
    var lastMIDINote: Int?
    var lastMIDIVelocity = 0
    var sustain = false
    var midiPlaysSound: Bool = LocalStore.load("midiPlaysSound") ?? true {
        didSet { LocalStore.save(midiPlaysSound, key: "midiPlaysSound") }
    }
    var disabledMIDI: Set<Int32> = Set(LocalStore.load("disabledMIDI", as: [Int32].self) ?? []) {
        didSet {
            midi.setDisabled(disabledMIDI)
            LocalStore.save(Array(disabledMIDI), key: "disabledMIDI")
        }
    }

    /// Claviers MIDI branchés et autorisés.
    var activeMIDIDevices: [MIDIDevice] { midiDevices.filter { !disabledMIDI.contains($0.id) } }

    @ObservationIgnored private var started = false
    @ObservationIgnored private var sustained: Set<Int> = []
    @ObservationIgnored private var toastToken = 0

    func start() {
        guard !started else { return }
        started = true
        audio.start()
        audio.onPitch = { [weak self] m in self?.heardFromMic(m) }

        midi.setDisabled(disabledMIDI)
        midi.onNoteOn = { [weak self] m, v in
            self?.lastMIDINote = m
            self?.lastMIDIVelocity = v
            self?.keyDown(m, velocity: v, fromMIDI: true)
        }
        midi.onNoteOff = { [weak self] m in self?.keyUp(m, fromMIDI: true) }
        midi.onSustain = { [weak self] down in self?.setSustain(down) }
        midi.onActivity = { [weak self] id in self?.midiActivity[id] = Date() }
        midi.onDevicesChanged = { [weak self] all, added, removed in
            self?.midiDevices = all
            if let d = added.first {
                self?.showToast("Clavier connecté : \(d.name) (\(d.transport.rawValue))")
            } else if let d = removed.first {
                self?.showToast("Clavier débranché : \(d.name)")
                self?.releaseAll()
            }
        }
        midi.start()
        midiError = midi.errorMessage
    }

    func keyDown(_ midi: Int, velocity: Int = 100, fromMIDI: Bool = false) {
        pressed.insert(midi)
        sustained.remove(midi)
        if !fromMIDI || midiPlaysSound { audio.play(midi, velocity: velocity) }
        lastNote = midi
        listener?(midi)
    }

    func keyUp(_ midi: Int, fromMIDI: Bool = false) {
        pressed.remove(midi)
        if sustain && fromMIDI {
            sustained.insert(midi)
        } else {
            audio.release(midi)
        }
    }

    func setSustain(_ down: Bool) {
        sustain = down
        guard !down else { return }
        for m in sustained where !pressed.contains(m) { audio.release(m) }
        sustained.removeAll()
    }

    func toggleMIDIDevice(_ device: MIDIDevice, enabled: Bool) {
        if enabled { disabledMIDI.remove(device.id) } else { disabledMIDI.insert(device.id) }
    }

    func rescanMIDI() { midi.refresh() }

    private func releaseAll() {
        for m in pressed { audio.release(m) }
        pressed.removeAll()
        setSustain(false)
    }

    private func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        midiToast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.toastToken == token else { return }
            self.midiToast = nil
        }
    }

    private func heardFromMic(_ midi: Int) {
        pressed.insert(midi)
        lastNote = midi
        listener?(midi)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.pressed.remove(midi)
        }
    }

    func setMic(_ on: Bool) {
        if on {
            audio.enableMic { [weak self] ok, message in
                self?.micEnabled = ok
                self?.micMessage = message
            }
        } else {
            audio.disableMic()
            micEnabled = false
            micMessage = nil
        }
    }

}
