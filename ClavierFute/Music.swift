import Foundation

/// Une note de la partition, positionnée en temps (beat).
struct Note: Identifiable, Hashable {
    let id: Int
    let midi: Int
    let beat: Double
    let duration: Double
}

enum NoteName {
    static let french = ["Do", "Do♯", "Ré", "Ré♯", "Mi", "Fa", "Fa♯", "Sol", "Sol♯", "La", "La♯", "Si"]
    static func name(_ midi: Int) -> String { french[((midi % 12) + 12) % 12] }
    static func full(_ midi: Int) -> String { name(midi) + String(midi / 12 - 1) }
    static func isBlack(_ midi: Int) -> Bool { [1, 3, 6, 8, 10].contains(((midi % 12) + 12) % 12) }
    /// Position diatonique (Do4 = 28), utilisée pour placer la note sur la portée.
    static func staffStep(_ midi: Int) -> Int {
        let table = [0, 0, 1, 1, 2, 3, 3, 4, 4, 5, 5, 6]
        return (midi / 12 - 1) * 7 + table[((midi % 12) + 12) % 12]
    }
}

/// Lit une partition texte : "C4 D4:2 R:1 Bb4:.5" (note:durée en temps, R = silence).
func parseScore(_ text: String) -> [Note] {
    let letters: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
    var notes: [Note] = []
    var beat = 0.0
    for token in text.split(separator: " ") {
        let parts = token.split(separator: ":")
        let pitch = String(parts[0])
        let duration = parts.count > 1 ? (Double(parts[1]) ?? 1) : 1
        if pitch != "R" {
            var chars = Array(pitch)
            if !chars.isEmpty, let base = letters[chars.removeFirst()] {
                var semitone = base
                if chars.first == "#" { semitone += 1; chars.removeFirst() }
                else if chars.first == "b" { semitone -= 1; chars.removeFirst() }
                if let octave = Int(String(chars)) {
                    notes.append(Note(id: notes.count, midi: (octave + 1) * 12 + semitone, beat: beat, duration: duration))
                }
            }
        }
        beat += duration
    }
    return notes
}

struct Lesson: Identifiable, Hashable {
    let id: String
    let title: String
    let tempo: Double
    let score: String
    var notes: [Note] { parseScore(score) }
}

struct Course: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let lessons: [Lesson]
}

enum Catalog {
    static let courses: [Course] = [
        Course(id: "b1", title: "Piano Basics 1", subtitle: "Les cinq premières notes de la main droite", lessons: [
            Lesson(id: "b1-1", title: "Do, Ré, Mi", tempo: 70,
                   score: "C4 D4 E4:2 E4 D4 C4:2 C4 D4 E4 D4 C4:4 C4 C4 D4 D4 E4 E4 D4:2 C4:4"),
            Lesson(id: "b1-2", title: "Fa et Sol", tempo: 72,
                   score: "C4 D4 E4 F4 G4:2 G4:2 G4 F4 E4 D4 C4:4 E4 F4 G4:2 G4 F4 E4:2 C4 D4 E4 F4 G4:4"),
            Lesson(id: "b1-3", title: "Au clair de la lune", tempo: 84,
                   score: "F4 F4 F4 G4 A4:2 G4:2 F4 A4 G4 G4 F4:4 F4 F4 F4 G4 A4:2 G4:2 F4 A4 G4 G4 F4:4 G4 G4 G4 G4 D4:2 D4:2 G4 F4 E4 D4 C4:4 F4 F4 F4 G4 A4:2 G4:2 F4 A4 G4 G4 F4:4"),
            Lesson(id: "b1-4", title: "Frère Jacques", tempo: 96,
                   score: "F4 G4 A4 F4 F4 G4 A4 F4 A4 Bb4 C5:2 A4 Bb4 C5:2 C5:.5 D5:.5 C5:.5 Bb4:.5 A4 F4 C5:.5 D5:.5 C5:.5 Bb4:.5 A4 F4 F4 C4 F4:2 F4 C4 F4:2"),
        ]),
        Course(id: "b2", title: "Piano Basics 2", subtitle: "La, Si, et les premières vraies mélodies", lessons: [
            Lesson(id: "b2-1", title: "La et Si", tempo: 76,
                   score: "G4 A4 B4 C5:2 C5:2 B4 A4 G4:2 G4:2 E4 F4 G4 A4 B4 C5:4 C5 B4 A4 G4 F4 E4 D4 C4:4"),
            Lesson(id: "b2-2", title: "Ah ! vous dirai-je, maman", tempo: 92,
                   score: "C4 C4 G4 G4 A4 A4 G4:2 F4 F4 E4 E4 D4 D4 C4:2 G4 G4 F4 F4 E4 E4 D4:2 G4 G4 F4 F4 E4 E4 D4:2 C4 C4 G4 G4 A4 A4 G4:2 F4 F4 E4 E4 D4 D4 C4:2"),
            Lesson(id: "b2-3", title: "Hymne à la joie", tempo: 100,
                   score: "E4 E4 F4 G4 G4 F4 E4 D4 C4 C4 D4 E4 E4:1.5 D4:.5 D4:2 E4 E4 F4 G4 G4 F4 E4 D4 C4 C4 D4 E4 D4:1.5 C4:.5 C4:2"),
            Lesson(id: "b2-4", title: "Joyeux anniversaire", tempo: 90,
                   score: "C4:.75 C4:.25 D4 C4 F4 E4:2 C4:.75 C4:.25 D4 C4 G4 F4:2 C4:.75 C4:.25 C5 A4 F4 E4 D4:2 Bb4:.75 Bb4:.25 A4 F4 G4 F4:2"),
        ]),
        Course(id: "e1", title: "Essentials", subtitle: "Croches, sauts et une octave complète", lessons: [
            Lesson(id: "e1-1", title: "Les croches", tempo: 84,
                   score: "C4:.5 D4:.5 E4:.5 F4:.5 G4:2 G4:.5 F4:.5 E4:.5 D4:.5 C4:2 C4:.5 E4:.5 G4:.5 C5:.5 G4:.5 E4:.5 C4:2 C4:.5 D4:.5 E4:.5 F4:.5 G4:.5 A4:.5 B4:.5 C5:.5 C5:2"),
            Lesson(id: "e1-2", title: "Vive le vent", tempo: 110,
                   score: "E4 E4 E4:2 E4 E4 E4:2 E4 G4 C4:1.5 D4:.5 E4:4 F4 F4 F4:1.5 F4:.5 F4 E4 E4 E4:.5 E4:.5 E4 D4 D4 E4 D4:2 G4:2 E4 E4 E4:2 E4 E4 E4:2 E4 G4 C4:1.5 D4:.5 E4:4 F4 F4 F4:1.5 F4:.5 F4 E4 E4 E4:.5 E4:.5 G4 G4 F4 D4 C4:4"),
            Lesson(id: "e1-3", title: "Gamme et arpège de Do", tempo: 96,
                   score: "C4 D4 E4 F4 G4 A4 B4 C5 C5 B4 A4 G4 F4 E4 D4 C4 C4:.5 E4:.5 G4:.5 C5:.5 E5:.5 C5:.5 G4:.5 E4:.5 C4:4"),
            Lesson(id: "e1-4", title: "Greensleeves", tempo: 100,
                   score: "A4 C5:2 D5 E5:1.5 F5:.5 E5 D5:2 B4 G4:1.5 A4:.5 B4 C5:2 A4 A4:1.5 G#4:.5 A4 B4:2 G#4 E4:2 A4 C5:2 D5 E5:1.5 F5:.5 E5 D5:2 B4 G4:1.5 A4:.5 B4 C5:1.5 B4:.5 A4 G#4:1.5 F#4:.5 G#4 A4:3"),
        ]),
    ]

    static let all: [Lesson] = courses.flatMap { $0.lessons }

    static func course(of lesson: Lesson) -> Course? {
        courses.first { $0.lessons.contains(lesson) }
    }

    static func lesson(after lesson: Lesson) -> Lesson? {
        guard let i = all.firstIndex(of: lesson), i + 1 < all.count else { return nil }
        return all[i + 1]
    }
}
