import SwiftUI

struct FreePlayView: View {
    @Environment(PianoHub.self) private var hub
    @State private var low = Device.isPhone ? 60 : 48
    @State private var history: [Int] = []

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Picker("Tessiture", selection: $low) {
                    if Device.isPhone {
                        Text("Do3").tag(48)
                        Text("Do4").tag(60)
                        Text("Do5").tag(72)
                    } else {
                        Text("Do2 – Do5").tag(36)
                        Text("Do3 – Do6").tag(48)
                        Text("Do4 – Do7").tag(60)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 400)
                Spacer()
                Button("Effacer") { history.removeAll() }.disabled(history.isEmpty)
            }
            Spacer()
            Text(hub.lastNote.map(NoteName.full) ?? "Joue une note")
                .font(.system(size: 96, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .foregroundStyle(hub.lastNote == nil ? Palette.muted : Palette.accent)
                .contentTransition(.numericText())
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(history.enumerated()), id: \.offset) { index, midi in
                            Text(NoteName.full(midi))
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Palette.surface, in: Capsule())
                                .overlay(Capsule().stroke(Palette.line))
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: history.count) { _, count in
                    withAnimation { proxy.scrollTo(count - 1, anchor: .trailing) }
                }
            }
            .frame(height: 40)
            Spacer()
            PianoKeyboard(range: low...(low + (Device.isPhone ? 17 : 36)),
                          pressed: hub.pressed,
                          showNames: hub.showNames,
                          onDown: { hub.keyDown($0) },
                          onUp: { hub.keyUp($0) })
                .containerRelativeFrame(.vertical) { height, _ in height * 0.4 }
        }
        .padding(.horizontal, Device.isPhone ? 10 : 20)
        .padding(.bottom, 8)
        .background(Palette.bg.ignoresSafeArea())
        .navigationTitle("Piano libre")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            hub.listener = { midi in
                history.append(midi)
                if history.count > 60 { history.removeFirst() }
            }
        }
        .onDisappear { hub.listener = nil }
    }
}
