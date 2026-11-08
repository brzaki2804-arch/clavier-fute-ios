import SwiftUI
import Observation

/// Un morceau à jouer en notes tombantes, issu d'une transcription ou d'un fichier.
struct FallingSong: Hashable {
    var id: String
    var title: String
    var bpm: Double
    var notes: [TranscribedNote]
}

/// Lecteur Synthesia : écoute, ou mode « Jouer » qui attend les bonnes touches.
@Observable
final class FallingPlayer {
    enum Mode: String, CaseIterable, Identifiable {
        case listen = "Écouter"
        case play = "Jouer"
        var id: String { rawValue }
    }

    let song: FallingSong
    private(set) var items: [FallingNote]
    private(set) var time: Double = -3
    private(set) var playing = false
    private(set) var finished = false
    private(set) var hits = 0
    private(set) var wrong = 0
    var mode: Mode = .listen { didSet { if oldValue != mode { restart() } } }
    var speed: Double = 1.0
    var leftHand = true
    var rightHand = true

    @ObservationIgnored weak var hub: PianoHub?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastTick: CFTimeInterval = 0
    @ObservationIgnored private var waiting = false

    var endTime: Double { items.map { $0.start + $0.duration }.max() ?? 0 }
    var progress: Double { endTime > 0 ? min(1, max(0, time / endTime)) : 0 }
    var accuracy: Int? { hits + wrong == 0 ? nil : Int(Double(hits) / Double(hits + wrong) * 100) }

    init(song: FallingSong) {
        self.song = song
        self.items = song.notes.map {
            FallingNote(midi: $0.midi, start: $0.start, duration: max(0.12, $0.duration), rightHand: $0.midi >= 60)
        }
    }

    deinit { timer?.invalidate() }

    /// Notes visibles selon les mains activées.
    var visibleItems: [FallingNote] { items.filter { ($0.rightHand && rightHand) || (!$0.rightHand && leftHand) } }

    /// Touches à mettre en surbrillance : celles attendues maintenant.
    var hintNotes: Set<Int> {
        Set(items.filter { $0.status == .active }.map(\.midi))
    }

    var countdown: Double? { time < 0 ? -time : nil }

    func toggle() {
        if finished { restart() }
        if playing { pause() } else { play() }
    }

    func play() {
        playing = true
        lastTick = 0
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() {
        playing = false
        timer?.invalidate()
        timer = nil
    }

    func restart() {
        pause()
        time = -3
        finished = false
        waiting = false
        hits = 0
        wrong = 0
        for i in items.indices { items[i].status = .pending }
    }

    func seek(_ fraction: Double) {
        let wasPlaying = playing
        pause()
        time = fraction * endTime
        waiting = false
        for i in items.indices { items[i].status = items[i].start < time ? .hit : .pending }
        if wasPlaying { play() }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = lastTick == 0 ? 0 : min(now - lastTick, 0.1)
        lastTick = now
        let previous = time
        if !waiting { time += dt * speed }

        // Sons du mode Écouter, et de la main désactivée en mode Jouer
        for i in items.indices {
            let n = items[i]
            let userPlays = mode == .play && ((n.rightHand && rightHand) || (!n.rightHand && leftHand))
            if !userPlays, n.start > previous, n.start <= time {
                hub?.audio.play(n.midi, velocity: 90)
                let midi = n.midi
                DispatchQueue.main.asyncAfter(deadline: .now() + n.duration / speed) { [weak self] in self?.hub?.audio.release(midi) }
                items[i].status = .hit
            }
        }

        if mode == .play {
            // Prochaine échéance : la première note que l'utilisateur doit jouer.
            if let next = items.filter({ $0.status == .pending && userMustPlay($0) }).min(by: { $0.start < $1.start }) {
                if time >= next.start {
                    time = next.start
                    waiting = true
                    for i in items.indices where items[i].status == .pending && userMustPlay(items[i]) && items[i].start <= time + 0.03 {
                        items[i].status = .active
                    }
                }
            }
        }

        if time > endTime + 1 {
            pause()
            finished = true
        }
    }

    private func userMustPlay(_ n: FallingNote) -> Bool {
        mode == .play && ((n.rightHand && rightHand) || (!n.rightHand && leftHand))
    }

    func input(_ midi: Int) {
        guard mode == .play, playing, waiting else { return }
        if let i = items.firstIndex(where: { $0.status == .active && $0.midi == midi }) {
            items[i].status = .hit
            hits += 1
            if !items.contains(where: { $0.status == .active }) { waiting = false }
        } else {
            wrong += 1
        }
    }
}

struct FallingPlayerView: View {
    @Environment(PianoHub.self) private var hub
    @State private var player: FallingPlayer

    init(song: FallingSong) {
        _player = State(initialValue: FallingPlayer(song: song))
    }

    private var range: ClosedRange<Int> {
        let midis = player.song.notes.map(\.midi)
        guard let lo = midis.min(), let hi = midis.max() else { return Device.lessonRange }
        // Étendre à des octaves entières, au minimum deux.
        var low = (lo / 12) * 12
        var high = ((hi + 11) / 12) * 12
        if Device.isPhone { low = max(low, high - 24); high = min(high, low + 24) }
        if high - low < 24 { high = low + 24 }
        return max(21, low)...min(108, high)
    }

    var body: some View {
        VStack(spacing: 10) {
            controls
            FallingNotesView(notes: player.visibleItems, time: player.time, range: range,
                             lookahead: Device.isPhone ? 2.5 : 3.5,
                             showNames: hub.showNames, countdown: player.countdown)
                .frame(maxHeight: .infinity)
                .overlay { if player.finished { result } }
            PianoKeyboard(range: range, hints: player.hintNotes, pressed: hub.pressed,
                          showNames: hub.showNames,
                          onDown: { hub.keyDown($0) }, onUp: { hub.keyUp($0) })
                .containerRelativeFrame(.vertical) { h, _ in h * (Device.isPhone ? 0.3 : 0.28) }
        }
        .padding(.horizontal, Device.isPhone ? 10 : 20)
        .padding(.bottom, 8)
        .background(Palette.bg.ignoresSafeArea())
        .navigationTitle(player.song.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            player.hub = hub
            let p = player
            hub.listener = { [weak p] midi in p?.input(midi) }
        }
        .onDisappear {
            player.pause()
            hub.listener = nil
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { controlItems }
                VStack(alignment: .leading, spacing: 8) { controlItems }
            }
            HStack(spacing: 10) {
                Button { player.toggle() } label: {
                    Image(systemName: player.playing ? "pause.fill" : "play.fill").frame(width: 24)
                }
                .buttonStyle(.borderedProminent)
                Button { player.restart() } label: { Image(systemName: "backward.end.fill") }
                    .buttonStyle(.bordered)
                Slider(value: Binding(get: { player.progress }, set: { player.seek($0) }), in: 0...1)
                    .tint(Palette.accent)
                Text(timeString(max(0, player.time)) + " / " + timeString(player.endTime))
                    .font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
            }
        }
    }

    @ViewBuilder
    private var controlItems: some View {
        Picker("Mode", selection: Bindable(player).mode) {
            ForEach(FallingPlayer.Mode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 220)
        HStack(spacing: 6) {
            Toggle(isOn: Bindable(player).leftHand) { Text("Gauche") }.toggleStyle(.button).tint(Palette.good)
            Toggle(isOn: Bindable(player).rightHand) { Text("Droite") }.toggleStyle(.button).tint(Palette.accent)
        }
        .font(.subheadline)
        HStack(spacing: 6) {
            Text("Vitesse").font(.subheadline).foregroundStyle(Palette.muted)
            Picker("Vitesse", selection: Bindable(player).speed) {
                Text("50 %").tag(0.5)
                Text("75 %").tag(0.75)
                Text("100 %").tag(1.0)
                Text("125 %").tag(1.25)
            }
            .pickerStyle(.menu)
        }
        if player.mode == .play, let a = player.accuracy {
            Text("Justesse \(a) %").font(.subheadline.monospacedDigit()).foregroundStyle(Palette.fg)
        }
    }

    private var result: some View {
        VStack(spacing: 10) {
            Text(player.mode == .play ? "Morceau terminé" : "Fin du morceau").font(.title2.weight(.bold))
            if player.mode == .play, let a = player.accuracy {
                StarsView(count: a >= 90 ? 3 : a >= 70 ? 2 : a >= 40 ? 1 : 0, size: 30)
                Text("Justesse \(a) % · \(player.wrong) fausse\(player.wrong > 1 ? "s" : "") note\(player.wrong > 1 ? "s" : "")")
                    .foregroundStyle(Palette.muted)
            }
            Button("Rejouer") { player.restart(); player.play() }.buttonStyle(.borderedProminent)
        }
        .padding(24)
        .card()
        .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
    }

    private func timeString(_ s: Double) -> String {
        let v = Int(s.rounded())
        return String(format: "%d:%02d", v / 60, v % 60)
    }
}
