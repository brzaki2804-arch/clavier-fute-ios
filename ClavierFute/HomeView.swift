import SwiftUI

struct HomeView: View {
    @Environment(PianoHub.self) private var hub
    @Environment(ProgressStore.self) private var store
    @Binding var path: [Route]
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                hero
                importCard
                ForEach(Catalog.courses) { course in
                    CourseSection(course: course) { path.append(.lesson($0)) }
                }
                Text("Joue sur l'écran, avec un clavier MIDI branché en USB (il est détecté dès le branchement), ou sur ton vrai piano grâce au micro. Active le micro dans les réglages, en haut à droite.")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, Device.isPhone ? 16 : 24)
            .padding(.vertical, 28)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.bg.ignoresSafeArea())
        .navigationTitle("Clavier Futé")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if hub.micEnabled {
                    Image(systemName: "mic.fill").foregroundStyle(Palette.good)
                        .accessibilityLabel("Micro actif")
                }
                if let device = hub.activeMIDIDevices.first {
                    Label(device.name, systemImage: "cable.connector")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline)
                        .foregroundStyle(Palette.good)
                        .accessibilityLabel("Clavier MIDI connecté : \(device.name)")
                }
                Button { path.append(.transcribe) } label: { Label("Audio → MIDI", systemImage: "waveform") }
                Button { path.append(.free) } label: { Label("Piano libre", systemImage: "pianokeys") }
                Button { showSettings = true } label: { Label("Réglages", systemImage: "gearshape") }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environment(hub).environment(store)
        }
    }

    private var hero: some View {
        let next = store.nextLesson
        let pct = Double(store.completedCount) / Double(Catalog.all.count)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 28) {
                heroText(next: next)
                nextCard(next: next, pct: pct).frame(width: 380)
            }
            .frame(minWidth: 820)
            VStack(alignment: .leading, spacing: 20) {
                heroText(next: next)
                nextCard(next: next, pct: pct)
            }
        }
    }

    private func heroText(next: Lesson?) -> some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("Apprends le piano, une note à la fois.")
                    .font(.system(size: Device.isPhone ? 30 : 40, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(Palette.fg)
                Text("La partition t'attend tant que tu n'as pas joué la bonne touche. Ensuite, passe en rythme avec le métronome et vise les trois étoiles.")
                    .font(Device.isPhone ? .body : .title3)
                    .foregroundStyle(Palette.muted)
                Button {
                    if let lesson = next ?? Catalog.all.last { path.append(.lesson(lesson)) }
                } label: {
                    Text(store.completedCount == 0 ? "Commencer" : "Continuer")
                        .font(.headline)
                        .padding(.horizontal, 28).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func nextCard(next: Lesson?, pct: Double) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("PROCHAINE LEÇON").font(.caption.weight(.semibold)).kerning(1).foregroundStyle(Palette.muted)
                Text(next?.title ?? "Parcours terminé !").font(.title2.weight(.bold)).foregroundStyle(Palette.fg)
                Text(next.flatMap { Catalog.course(of: $0)?.title } ?? "Rejoue tes morceaux pour viser 3 étoiles")
                    .foregroundStyle(Palette.muted)
                ProgressView(value: pct).tint(Palette.accent)
                HStack(spacing: 20) {
                    stat("\(store.totalStars)", "étoiles", "star.fill", Palette.gold)
                    stat("\(store.completedCount)/\(Catalog.all.count)", "leçons", "checkmark.circle.fill", Palette.good)
                    stat("\(store.streak)", "jours de suite", "flame.fill", Palette.bad)
                }
                .padding(.top, 4)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
    }

    private var importCard: some View {
        Button { path.append(.transcribe) } label: {
            HStack(spacing: 16) {
                Image(systemName: "waveform.path")
                    .font(.title)
                    .foregroundStyle(Palette.accent)
                    .frame(width: 48, height: 48)
                    .background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Transformer un MP3 en MIDI").font(.headline).foregroundStyle(Palette.fg)
                    Text("Importe un morceau, l'app reconnaît les notes et crée un fichier pour Synthesia.")
                        .font(.subheadline).foregroundStyle(Palette.muted).multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Palette.muted)
            }
            .padding(16)
            .card()
        }
        .buttonStyle(.plain)
    }

    private func stat(_ value: String, _ label: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(value, systemImage: icon).font(.headline.monospacedDigit()).foregroundStyle(Palette.fg)
                .labelStyle(TintedIconLabel(color: color))
            Text(label).font(.caption).foregroundStyle(Palette.muted)
        }
    }
}

private struct TintedIconLabel: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(color)
            configuration.title
        }
    }
}

struct CourseSection: View {
    @Environment(ProgressStore.self) private var store
    let course: Course
    let open: (Lesson) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(course.title).font(.title2.weight(.bold)).foregroundStyle(Palette.fg)
                    Text(course.subtitle).foregroundStyle(Palette.muted)
                }
                Spacer()
                Text("\(course.lessons.filter { store.stars($0) > 0 }.count)/\(course.lessons.count)")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(Palette.muted)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 14) {
                ForEach(Array(course.lessons.enumerated()), id: \.element.id) { index, lesson in
                    LessonCard(lesson: lesson, number: index + 1) { open(lesson) }
                }
            }
        }
    }
}

struct LessonCard: View {
    @Environment(ProgressStore.self) private var store
    let lesson: Lesson
    let number: Int
    let action: () -> Void

    var body: some View {
        let unlocked = store.isUnlocked(lesson)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text("LEÇON \(number)").font(.caption.weight(.semibold)).kerning(1).foregroundStyle(Palette.muted)
                Text(lesson.title).font(.headline).foregroundStyle(Palette.fg).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                HStack {
                    Text("\(lesson.notes.count) notes · ♩ \(Int(lesson.tempo))")
                        .font(.caption).foregroundStyle(Palette.muted)
                    Spacer()
                    if unlocked {
                        StarsView(count: store.stars(lesson))
                    } else {
                        Image(systemName: "lock.fill").foregroundStyle(Palette.muted)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .card()
            .opacity(unlocked ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!unlocked)
        .accessibilityHint(unlocked ? "Ouvre la leçon" : "Termine la leçon précédente pour la débloquer")
    }
}
