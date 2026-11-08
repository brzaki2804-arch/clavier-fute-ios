import SwiftUI

/// Écran de connexion MIDI : appareils branchés, activation, test des touches et de la pédale.
struct MIDISettingsView: View {
    @Environment(PianoHub.self) private var hub

    var body: some View {
        @Bindable var hub = hub
        Form {
            if let error = hub.midiError {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.bad) }
            }

            Section {
                if hub.midiDevices.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Aucun clavier détecté", systemImage: "cable.connector.slash")
                            .foregroundStyle(Palette.muted)
                        Text("Branche ton clavier : il apparaîtra ici automatiquement.")
                            .font(.footnote).foregroundStyle(Palette.muted)
                    }
                    .padding(.vertical, 4)
                } else {
                    ForEach(hub.midiDevices) { device in
                        MIDIDeviceRow(device: device)
                    }
                }
                Button { hub.rescanMIDI() } label: { Label("Rechercher à nouveau", systemImage: "arrow.clockwise") }
            } header: {
                Text("Appareils connectés")
            } footer: {
                Text("Désactive un appareil pour ignorer ses notes sans le débrancher.")
            }

            Section("Tester") {
                MIDITestPanel()
            }

            Section {
                Toggle("Jouer le son de l'app", isOn: $hub.midiPlaysSound)
            } header: {
                Text("Son")
            } footer: {
                Text("Désactive cette option si ton piano numérique a ses propres haut-parleurs. Laisse-la active pour un clavier maître sans son.")
            }

            Section("Brancher un clavier en USB") {
                HelpRow(icon: "1.circle.fill", title: "Vérifie la prise du piano",
                        text: "Elle s'appelle souvent « USB to Host » (prise carrée USB-B, ou USB-C). La prise « USB to Device » sert aux clés USB et ne convient pas.")
                HelpRow(icon: "2.circle.fill", title: "iPad avec prise USB-C",
                        text: "Un câble USB-B vers USB-C (ou USB-C vers USB-C) suffit. Aucun pilote n'est nécessaire pour les claviers « class compliant », comme la plupart des Yamaha, Roland, Casio, Kawai, Korg, Arturia ou M-Audio.")
                HelpRow(icon: "3.circle.fill", title: "iPad avec prise Lightning",
                        text: "Utilise l'adaptateur Apple Lightning vers USB 3 pour appareil photo, branché sur secteur, puis le câble USB du piano.")
                HelpRow(icon: "4.circle.fill", title: "Si rien n'apparaît",
                        text: "Allume le piano avant de brancher le câble, essaie un autre câble (certains ne font que la charge), puis touche « Rechercher à nouveau ».")
            }
        }
        .navigationTitle("Clavier MIDI")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MIDIDeviceRow: View {
    @Environment(PianoHub.self) private var hub
    let device: MIDIDevice

    var body: some View {
        let enabled = !hub.disabledMIDI.contains(device.id)
        HStack(spacing: 14) {
            Image(systemName: device.transport.symbol)
                .font(.title3)
                .frame(width: 32)
                .foregroundStyle(enabled ? Palette.accent : Palette.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.body.weight(.semibold))
                Text([device.manufacturer, device.transport.rawValue].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(Palette.muted)
            }
            Spacer()
            ActivityLight(date: hub.midiActivity[device.id], enabled: enabled)
            Toggle("Activer \(device.name)", isOn: Binding(
                get: { enabled },
                set: { hub.toggleMIDIDevice(device, enabled: $0) }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }
}

/// Voyant qui s'allume quand l'appareil envoie des messages.
struct ActivityLight: View {
    let date: Date?
    let enabled: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let active = enabled && (date.map { context.date.timeIntervalSince($0) < 0.25 } ?? false)
            Circle()
                .fill(active ? Palette.good : Palette.line)
                .frame(width: 10, height: 10)
                .shadow(color: active ? Palette.good.opacity(0.8) : .clear, radius: 4)
        }
        .accessibilityHidden(true)
    }
}

struct MIDITestPanel: View {
    @Environment(PianoHub.self) private var hub

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Dernière note").font(.caption).foregroundStyle(Palette.muted)
                    Text(hub.lastMIDINote.map(NoteName.full) ?? "—")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(hub.lastMIDINote == nil ? Palette.muted : Palette.accent)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Vélocité \(hub.lastMIDIVelocity)").font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                    ProgressView(value: Double(hub.lastMIDIVelocity), total: 127).tint(Palette.accent)
                        .frame(maxWidth: 160)
                }
                Spacer()
                Label(hub.sustain ? "Pédale enfoncée" : "Pédale relâchée",
                      systemImage: hub.sustain ? "pedal.accelerator.fill" : "pedal.accelerator")
                    .foregroundStyle(hub.sustain ? Palette.good : Palette.muted)
                    .font(.subheadline)
            }
            Text(hub.activeMIDIDevices.isEmpty
                 ? "Branche un clavier pour tester les touches et la pédale."
                 : "Joue quelques notes : elles doivent s'afficher ici.")
                .font(.footnote).foregroundStyle(Palette.muted)
        }
        .padding(.vertical, 4)
    }
}

private struct HelpRow: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Palette.accent).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.footnote).foregroundStyle(Palette.muted)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Bandeau affiché quand un clavier est branché ou débranché.
struct MIDIToast: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "cable.connector")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.fg)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Palette.line))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityAddTraits(.isStaticText)
    }
}
