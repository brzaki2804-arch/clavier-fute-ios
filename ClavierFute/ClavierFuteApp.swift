import SwiftUI

@main
struct ClavierFuteApp: App {
    @State private var hub = PianoHub()
    @State private var store = ProgressStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(hub)
                .environment(store)
                .onAppear { hub.start() }
        }
    }
}

enum Route: Hashable {
    case lesson(Lesson)
    case free
    case transcribe
    case falling(FallingSong)
}

struct RootView: View {
    @Environment(PianoHub.self) private var hub
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .lesson(let lesson): LessonView(lesson: lesson)
                    case .free: FreePlayView()
                    case .transcribe: TranscribeView(path: $path)
                    case .falling(let song): FallingPlayerView(song: song)
                    }
                }
        }
        .tint(Palette.accent)
        .overlay(alignment: .top) {
            if let toast = hub.midiToast {
                MIDIToast(text: toast)
            }
        }
        .animation(.spring(duration: 0.35), value: hub.midiToast)
    }
}
