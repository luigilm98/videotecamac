import Foundation

struct LibrarySource: Codable, Hashable, Identifiable {
    var path: String
    var isDirectory: Bool

    var id: String { path }

    var url: URL {
        URL(fileURLWithPath: path, isDirectory: isDirectory)
    }

    var displayName: String {
        url.lastPathComponent.isEmpty ? path : url.lastPathComponent
    }

    var kindText: String {
        isDirectory ? "Cartella" : "File"
    }

    var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    init(url: URL) {
        let standardized = url.standardizedFileURL
        self.path = standardized.path
        var directory: ObjCBool = false
        FileManager.default.fileExists(atPath: standardized.path, isDirectory: &directory)
        self.isDirectory = directory.boolValue
    }
}

final class SourceStore {
    private let fileURL: URL
    private let defaultSources: [LibrarySource]
    private(set) var sources: [LibrarySource]

    init(applicationSupportURL: URL, defaultSources: [LibrarySource]) {
        self.fileURL = applicationSupportURL.appendingPathComponent("sources.json")
        self.defaultSources = defaultSources
        self.sources = defaultSources
        load()
    }

    func replace(with sources: [LibrarySource]) {
        self.sources = unique(sources)
        if self.sources.isEmpty {
            self.sources = defaultSources
        }
        save()
    }

    func reset() {
        sources = defaultSources
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([LibrarySource].self, from: data),
              !decoded.isEmpty else {
            sources = defaultSources
            return
        }
        sources = unique(decoded)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(sources).write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("Could not save sources: \(error.localizedDescription)")
        }
    }

    private func unique(_ sources: [LibrarySource]) -> [LibrarySource] {
        var seen = Set<String>()
        return sources.compactMap { source in
            let key = source.path
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return source
        }
    }
}

