import Foundation

/// Petits réglages et progression, enregistrés en JSON dans Application Support.
enum LocalStore {
    private static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("ClavierFute", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load<T: Decodable>(_ key: String, as type: T.Type = T.self) -> T? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(key + ".json")) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: folder.appendingPathComponent(key + ".json"), options: .atomic)
    }
}
