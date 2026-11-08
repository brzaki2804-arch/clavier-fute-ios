import Foundation
import Observation

/// Étoiles, meilleurs scores et série de jours, gardés sur l'appareil.
@Observable
final class ProgressStore {
    struct Record: Codable {
        var stars: Int
        var best: Int
    }

    private struct Saved: Codable {
        var records: [String: Record]
        var streak: Int
        var lastDay: Date?
    }

    private(set) var records: [String: Record] = [:]
    private(set) var streak = 0
    private var lastDay: Date?
    private let key = "progress"

    init() {
        if let saved: Saved = LocalStore.load(key) {
            records = saved.records
            streak = saved.streak
            lastDay = saved.lastDay
        }
        let cal = Calendar.current
        if let day = lastDay, !cal.isDateInToday(day), !cal.isDateInYesterday(day) {
            streak = 0
        }
    }

    func stars(_ lesson: Lesson) -> Int { records[lesson.id]?.stars ?? 0 }
    func best(_ lesson: Lesson) -> Int? { records[lesson.id]?.best }

    func isUnlocked(_ lesson: Lesson) -> Bool {
        guard let i = Catalog.all.firstIndex(of: lesson) else { return false }
        return i == 0 || stars(Catalog.all[i - 1]) > 0
    }

    var totalStars: Int { Catalog.all.reduce(0) { $0 + stars($1) } }
    var completedCount: Int { Catalog.all.filter { stars($0) > 0 }.count }
    var nextLesson: Lesson? { Catalog.all.first { isUnlocked($0) && stars($0) == 0 } }

    /// Enregistre un résultat. Renvoie vrai si c'est un nouveau record d'étoiles.
    @discardableResult
    func record(_ lesson: Lesson, stars: Int, accuracy: Int) -> Bool {
        let previous = records[lesson.id] ?? Record(stars: 0, best: 0)
        records[lesson.id] = Record(stars: max(previous.stars, stars), best: max(previous.best, accuracy))
        let cal = Calendar.current
        if let day = lastDay, cal.isDateInToday(day) {
            // déjà compté aujourd'hui
        } else if let day = lastDay, cal.isDateInYesterday(day) {
            streak += 1
        } else {
            streak = 1
        }
        lastDay = Date()
        save()
        return stars > previous.stars
    }

    func reset() {
        records = [:]
        streak = 0
        lastDay = nil
        save()
    }

    private func save() {
        LocalStore.save(Saved(records: records, streak: streak, lastDay: lastDay), key: key)
    }
}
