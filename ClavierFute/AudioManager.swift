import AVFoundation
import Accelerate

/// Synthé de piano (additif) + écoute du micro avec détection de hauteur (YIN).
final class AudioManager {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private let lock = NSLock()
    private var voices: [Voice] = []
    private var sampleRate: Double = 48_000
    private var started = false

    var volume: Float = 0.7 {
        didSet { engine.mainMixerNode.outputVolume = volume }
    }

    // MARK: Micro
    var onPitch: ((Int) -> Void)?
    private(set) var micRunning = false
    private var micBuffer: [Float] = []
    private var micSampleRate: Double = 48_000
    private var lastSynthTime: CFAbsoluteTime = 0
    private var candidate: Int?
    private var candidateCount = 0
    private var lastEmitted: Int?
    private var lastRMS: Float = 0
    private var silentCount = 0

    private struct Voice {
        var midi: Int
        var freq: Double
        var phase: Double = 0
        var gain: Double = 0
        var attacking = true
        var amp: Double
        var decayFactor: Double
        var isClick: Bool
    }

    // MARK: Démarrage

    func start() {
        guard !started else { return }
        configureSession(record: false)
        let outFormat = engine.outputNode.outputFormat(forBus: 0)
        sampleRate = outFormat.sampleRate > 0 ? outFormat.sampleRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        voices.reserveCapacity(64)
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList in
            self.render(frameCount: Int(frameCount), bufferList: bufferList)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
        sourceNode = node

        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.restartEngine()
        }
        nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restartEngine()
        }
        do {
            try engine.start()
            started = true
        } catch {
            print("Audio : \(error)")
        }
    }

    private func restartEngine() {
        if !engine.isRunning { try? engine.start() }
    }

    private func configureSession(record: Bool) {
        let session = AVAudioSession.sharedInstance()
        if record {
            try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        } else {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setActive(true)
    }

    // MARK: Synthé

    func play(_ midi: Int, velocity: Int = 100) {
        start()
        let freq = 440 * pow(2, Double(midi - 69) / 12)
        let decay = 1.1 + freq / 350
        let voice = Voice(midi: midi, freq: freq,
                          amp: 0.32 * Double(max(20, min(127, velocity))) / 127,
                          decayFactor: exp(-decay / sampleRate), isClick: false)
        lock.lock()
        if voices.count > 32 { voices.removeFirst() }
        voices.append(voice)
        lastSynthTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    func release(_ midi: Int) {
        let factor = exp(-7 / sampleRate)
        lock.lock()
        for i in voices.indices where voices[i].midi == midi && !voices[i].isClick {
            voices[i].decayFactor = min(voices[i].decayFactor, factor)
        }
        lock.unlock()
    }

    func click(strong: Bool) {
        start()
        let voice = Voice(midi: -1, freq: strong ? 1600 : 1100, amp: strong ? 0.35 : 0.22,
                          decayFactor: exp(-70 / sampleRate), isClick: true)
        lock.lock()
        voices.append(voice)
        lastSynthTime = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    private func render(frameCount: Int, bufferList: UnsafeMutablePointer<AudioBufferList>) {
        // Format mono non entrelacé : un seul tampon.
        guard let first = bufferList.pointee.mBuffers.mData?.assumingMemoryBound(to: Float.self) else { return }
        let twoPi = 2 * Double.pi
        let attackStep = 1 / (0.004 * sampleRate)
        let dt = 1 / sampleRate
        lock.lock()
        for f in 0..<frameCount {
            var sample = 0.0
            var i = 0
            while i < voices.count {
                var v = voices[i]
                if v.attacking {
                    v.gain += attackStep
                    if v.gain >= 1 { v.gain = 1; v.attacking = false }
                } else {
                    v.gain *= v.decayFactor
                }
                let p = v.phase
                if v.isClick {
                    sample += v.gain * v.amp * sin(p)
                } else {
                    sample += v.gain * v.amp * (sin(p) + 0.4 * sin(2 * p) + 0.15 * sin(3 * p) + 0.06 * sin(4 * p))
                }
                v.phase = p + twoPi * v.freq * dt
                if v.phase >= twoPi { v.phase -= twoPi }
                if !v.attacking && v.gain < 0.0003 {
                    voices.remove(at: i)
                } else {
                    voices[i] = v
                    i += 1
                }
            }
            first[f] = Float(tanh(sample * 0.9))
        }
        lock.unlock()
    }

    // MARK: Micro

    func enableMic(_ done: @escaping (Bool, String?) -> Void) {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else {
            done(false, "Le projet Xcode doit déclarer l'usage du micro : cible › Info › « Privacy - Microphone Usage Description ».")
            return
        }
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async {
                guard granted else {
                    done(false, "Autorise le micro dans Réglages › Clavier Futé.")
                    return
                }
                let ok = self.startMic()
                done(ok, ok ? nil : "Le micro n'est pas disponible sur cet appareil.")
            }
        }
    }

    private func startMic() -> Bool {
        start()
        engine.stop()
        configureSession(record: true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            try? engine.start()
            return false
        }
        micSampleRate = format.sampleRate
        micBuffer.removeAll()
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        do {
            try engine.start()
            micRunning = true
            return true
        } catch {
            input.removeTap(onBus: 0)
            return false
        }
    }

    func disableMic() {
        guard micRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        micRunning = false
        engine.stop()
        configureSession(record: false)
        try? engine.start()
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        micBuffer.append(contentsOf: UnsafeBufferPointer(start: channel, count: count))
        let size = 2048, hop = 1024
        let rate = micSampleRate
        while micBuffer.count >= size {
            let result = micBuffer.withUnsafeBufferPointer { ptr in
                AudioManager.detectPitch(ptr.baseAddress!, count: size, sampleRate: rate)
            }
            micBuffer.removeFirst(hop)
            track(result)
        }
    }

    /// Transforme une suite de hauteurs en événements « note jouée ».
    private func track(_ result: (frequency: Double, rms: Float)?) {
        guard let result else {
            silentCount += 1
            if silentCount >= 3 { lastEmitted = nil }
            candidate = nil
            candidateCount = 0
            lastRMS = 0
            return
        }
        silentCount = 0
        let midiFloat = 69 + 12 * log2(result.frequency / 440)
        let midi = Int(midiFloat.rounded())
        let isAttack = result.rms > lastRMS * 1.8 && result.rms > 0.02
        lastRMS = result.rms
        guard abs(midiFloat - Double(midi)) < 0.4, (36...96).contains(midi) else { return }

        if midi == candidate { candidateCount += 1 } else { candidate = midi; candidateCount = 1 }
        if isAttack {
            candidateCount = 1
            if midi == lastEmitted { lastEmitted = nil }
        }

        lock.lock()
        let sinceSynth = CFAbsoluteTimeGetCurrent() - lastSynthTime
        lock.unlock()
        // Ignore le son que l'app vient elle-même de jouer.
        guard sinceSynth > 0.35 else { return }

        if candidateCount >= 2 && midi != lastEmitted {
            lastEmitted = midi
            DispatchQueue.main.async { [weak self] in self?.onPitch?(midi) }
        }
    }

    /// Détection de fréquence fondamentale par l'algorithme YIN.
    static func detectPitch(_ x: UnsafePointer<Float>, count: Int, sampleRate: Double,
                            minRMS: Float = 0.008) -> (frequency: Double, rms: Float)? {
        var meanSquare: Float = 0
        vDSP_measqv(x, 1, &meanSquare, vDSP_Length(count))
        let rms = sqrt(meanSquare)
        guard rms > minRMS else { return nil }

        let maxTau = min(Int(sampleRate / 55), count / 2)
        let minTau = max(2, Int(sampleRate / 1400))
        let window = count - maxTau
        var cmnd = [Float](repeating: 1, count: maxTau + 1)
        var running: Float = 0
        for tau in 1...maxTau {
            var d: Float = 0
            vDSP_distancesq(x, 1, x + tau, 1, &d, vDSP_Length(window))
            running += d
            cmnd[tau] = running > 0 ? d * Float(tau) / running : 1
        }

        var tau = minTau
        var estimate = -1
        while tau < maxTau {
            if cmnd[tau] < 0.18 {
                while tau + 1 < maxTau && cmnd[tau + 1] < cmnd[tau] { tau += 1 }
                estimate = tau
                break
            }
            tau += 1
        }
        guard estimate > 1 else { return nil }

        let s0 = cmnd[estimate - 1], s1 = cmnd[estimate], s2 = cmnd[estimate + 1]
        let denom = s0 - 2 * s1 + s2
        let refined = abs(denom) > 1e-6 ? Double(estimate) + 0.5 * Double(s0 - s2) / Double(denom) : Double(estimate)
        return (sampleRate / refined, rms)
    }
}
