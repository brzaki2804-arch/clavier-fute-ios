import SwiftUI

struct SettingsView: View {
    @Environment(PianoHub.self) private var hub
    @Environment(ProgressStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var confirmReset = false

    var body: some View {
        @Bindable var hub = hub
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: Binding(get: { hub.micEnabled }, set: { hub.setMic($0) })) {
                        Label("Écouter mon piano (micro)", systemImage: "mic")
                    }
                    if let message = hub.micMessage {
                        Text(message).font(.footnote).foregroundStyle(Palette.bad)
                    }
                } header: {
                    Text("Piano acoustique")
                } footer: {
                    Text("Pose l'iPad sur le pupitre. Joue une note à la fois, dans une pièce calme, pour une détection fiable.")
                }

                Section("Clavier MIDI") {
                    NavigationLink {
                        MIDISettingsView()
                    } label: {
                        HStack {
                            Label("Connexion MIDI (USB)", systemImage: "cable.connector")
                            Spacer()
                            Text(hub.activeMIDIDevices.isEmpty ? "Aucun clavier"
                                 : hub.activeMIDIDevices.map(\.name).joined(separator: ", "))
                                .foregroundStyle(hub.activeMIDIDevices.isEmpty ? Palette.muted : Palette.good)
                                .lineLimit(1)
                        }
                    }
                }

                Section("Son et affichage") {
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(Palette.muted)
                        Slider(value: $hub.volume, in: 0...1)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(Palette.muted)
                    }
                    Toggle("Noms des notes", isOn: $hub.showNames)
                    Toggle("Métronome en mode En rythme", isOn: $hub.metronome)
                }

                Section("Progression") {
                    LabeledContent("Étoiles", value: "\(store.totalStars)")
                    LabeledContent("Leçons validées", value: "\(store.completedCount) sur \(Catalog.all.count)")
                    Button("Remettre la progression à zéro", role: .destructive) { confirmReset = true }
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
            .confirmationDialog("Effacer toutes les étoiles et la série ?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Tout effacer", role: .destructive) { store.reset() }
            }
        }
    }
}
