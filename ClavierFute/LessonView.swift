import SwiftUI

struct LessonView: View {
    @Environment(PianoHub.self) private var hub
    @Environment(ProgressStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var engine: LessonEngine

    init(lesson: Lesson) {
        _engine = State(initialValue: LessonEngine(lesson: lesson))
    }

    var body: some View {
        VStack(spacing: 12) {
            controls
            hud
            ZStack {
                if hub.fallingNotes {
                    FallingNotesView(notes: fallingItems, time: engine.beat * 60 / engine.lesson.tempo,
                                     range: Device.lessonRange, lookahead: Device.isPhone ? 2.5 : 3.5,
                                     showNames: hub.showNames,
                                     countdown: engine.beat < 0 ? -engine.beat * 60 / engine.lesson.tempo : nil)
                } else {
                    StaffView(engine: engine, showNames: hub.showNames)
                }
                if engine.phase == .finished { result }
            }
            .frame(maxHeight: .infinity)
            PianoKeyboard(range: Device.lessonRange,
                          hints: engine.hintNote.map { Set([$0]) } ?? Set<Int>(),
                          pressed: hub.pressed,
                          flashes: engine.flashes,
                          showNames: hub.showNames,
                          onDown: { hub.keyDown($0) },
                          onUp: { hub.keyUp($0) })
                .containerRelativeFrame(.vertical) { height, _ in height * (Device.isPhone ? 0.4 : 0.36) }
        }
        .padding(.horizontal, Device.isPhone ? 10 : 20)
        .padding(.bottom, 8)
        .background(Palette.bg.ignoresSafeArea())
        .navigationTitle(engine.lesson.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: attach)
        .onDisappear {
            engine.stop()
            hub.listener = nil
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                lessonInfo
                Spacer()
                modePicker.frame(width: 260)
                actionButtons
            }
            VStack(alignment: .leading, spacing: 10) {
                lessonInfo
                HStack(spacing: 10) {
                    modePicker
                    actionButtons
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                modePicker
                actionButtons
            }
        }
    }

    private var lessonInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Catalog.course(of: engine.lesson)?.title ?? "").font(.subheadline).foregroundStyle(Palette.muted)
            if let best = store.best(engine.lesson) {
                Text("Meilleur score \(best) %").font(.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    private var modePicker: some View {
        Picker("Mode", selection: Bindable(engine).mode) {
            ForEach(LessonEngine.Mode.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
    }

    /// Les notes de la leçon converties pour l'affichage en notes tombantes.
    private var fallingItems: [FallingNote] {
        let spb = 60 / engine.lesson.tempo
        let pending = engine.mode == .learn ? engine.firstPending : nil
        return engine.notes.enumerated().map { i, n in
            var status: FallingNote.Status
            switch engine.states[i] {
            case .hit: status = .hit
            case .miss: status = .miss
            case .pending: status = (i == pending) ? .active : .pending
            }
            return FallingNote(midi: n.midi, start: n.beat * spb, duration: n.duration * spb, rightHand: true, status: status)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Picker("Affichage", selection: Bindable(hub).fallingNotes) {
                Image(systemName: "music.note.list").tag(false).accessibilityLabel("Partition")
                Image(systemName: "arrow.down.to.line").tag(true).accessibilityLabel("Notes tombantes")
            }
            .pickerStyle(.segmented)
            .frame(width: 90)
            Button { engine.listen() } label: { Label("Écouter", systemImage: "speaker.wave.2.fill") }
                .buttonStyle(.bordered)
            Menu {
                if let url = engine.lesson.midiFileURL() {
                    ShareLink(item: url) { Label("Ouvrir dans Synthesia (.mid)", systemImage: "square.and.arrow.up") }
                }
                NavigationLink(value: Route.falling(FallingSong(id: "lesson-\(engine.lesson.id)", title: engine.lesson.title,
                                                               bpm: engine.lesson.tempo, notes: engine.lesson.transcribedNotes))) {
                    Label("Lecteur notes tombantes", systemImage: "arrow.down.to.line")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Plus d'options")
            Button { engine.togglePlay() } label: {
                Text(engine.primaryTitle).frame(minWidth: 90)
            }
            .buttonStyle(.borderedProminent)
        }
        .fixedSize()
    }

    private var hud: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            hudContent
        }
    }

    private var hudContent: some View {
        HStack(spacing: 22) {
            hudItem("Tempo", "\(Int(engine.lesson.tempo))")
            hudItem("Justesse", engine.accuracy.map { "\($0) %" } ?? "—")
            hudItem("Notes", "\(engine.doneCount)/\(engine.notes.count)")
            Text(engine.feedback)
                .font(.title3.weight(.bold))
                .foregroundStyle(toneColor)
                .animation(.easeOut(duration: 0.15), value: engine.feedback)
                .frame(minWidth: 220, alignment: .leading)
            if hub.micEnabled { Label("Micro", systemImage: "mic.fill").foregroundStyle(Palette.good).font(.subheadline) }
            if let device = hub.activeMIDIDevices.first {
                Label(device.name, systemImage: "cable.connector").foregroundStyle(Palette.good).font(.subheadline).lineLimit(1)
            }
            if hub.sustain {
                Label("Pédale", systemImage: "pedal.accelerator.fill").foregroundStyle(Palette.accent).font(.subheadline)
            }
        }
    }

    private var toneColor: Color {
        switch engine.tone {
        case .good: return Palette.good
        case .bad: return Palette.bad
        case .hint: return Palette.accent
        }
    }

    private func hudItem(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(Palette.muted)
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(Palette.fg)
        }
        .font(.subheadline)
    }

    private var result: some View {
        let next = Catalog.lesson(after: engine.lesson)
        let canGoNext = next.map { store.isUnlocked($0) } ?? false
        let title = ["Encore un essai", "C'est acquis", "Très bien !", "Magnifique !"][engine.stars]
        var detail = "Justesse \(engine.finalAccuracy) %"
        if engine.mode == .rhythm {
            detail += " · \(engine.perfect) notes parfaites"
        } else {
            detail += " · \(engine.wrong) fausse\(engine.wrong > 1 ? "s" : "") note\(engine.wrong > 1 ? "s" : "")"
        }
        if engine.newRecord { detail += " · nouveau record" }

        return VStack(spacing: 12) {
            StarsView(count: engine.stars, size: Device.isPhone ? 28 : 40)
            Text(title).font(.title.weight(.bold)).foregroundStyle(Palette.fg)
            Text(detail).foregroundStyle(Palette.muted)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { resultButtons(next: next, canGoNext: canGoNext) }
                VStack(spacing: 8) { resultButtons(next: next, canGoNext: canGoNext) }
            }
            .padding(.top, 4)
        }
        .padding(Device.isPhone ? 18 : 28)
        .card()
        .shadow(color: .black.opacity(0.12), radius: 20, y: 8)
        .padding(8)
    }

    @ViewBuilder
    private func resultButtons(next: Lesson?, canGoNext: Bool) -> some View {
                Button("Rejouer") { engine.togglePlay() }.buttonStyle(.bordered)
                if engine.mode == .learn {
                    Button("Essayer en rythme") { engine.mode = .rhythm; engine.togglePlay() }.buttonStyle(.bordered)
                }
                if canGoNext, let next {
                    Button("Leçon suivante") { load(next) }.buttonStyle(.borderedProminent)
                } else {
                    Button("Retour au parcours") { dismiss() }.buttonStyle(.borderedProminent)
                }
    }

    private func attach() {
        let current = engine
        current.hub = hub
        let lesson = current.lesson
        current.onFinish = { [store] stars, accuracy in
            store.record(lesson, stars: stars, accuracy: accuracy)
        }
        hub.listener = { [weak current] midi in current?.input(midi) }
    }

    private func load(_ lesson: Lesson) {
        engine.stop()
        engine = LessonEngine(lesson: lesson, mode: engine.mode)
        attach()
    }
}
