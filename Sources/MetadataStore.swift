import Foundation

final class MetadataStore {
    private let fileURL: URL
    private(set) var items: [String: MovieMetadata] = [:]

    init(applicationSupportURL: URL) {
        self.fileURL = applicationSupportURL.appendingPathComponent("metadata.json")
        load()
    }

    func metadata(for id: String) -> MovieMetadata {
        items[id] ?? MovieMetadata()
    }

    func metadata(for id: String, fileIdentity: String?, legacyFileSignature: String?) -> MovieMetadata {
        if var metadata = items[id] {
            if metadata.fileIdentity != fileIdentity {
                metadata.fileIdentity = fileIdentity
                items[id] = metadata
                save()
            }
            return metadata
        }

        guard let adoptedID = adoptableMetadataID(
            fileIdentity: fileIdentity,
            legacyFileSignature: legacyFileSignature
        ) else {
            return MovieMetadata(fileIdentity: fileIdentity)
        }

        var metadata = items[adoptedID] ?? MovieMetadata()
        metadata.fileIdentity = fileIdentity
        items[id] = metadata
        if adoptedID != id {
            items.removeValue(forKey: adoptedID)
        }
        save()
        return metadata
    }

    func update(_ metadata: MovieMetadata, for id: String) {
        items[id] = metadata
        save()
    }

    func markOnlineLookup(for id: String, signature: String, online: OnlineMovieMetadata?, failedAt: Date?) {
        var metadata = items[id] ?? MovieMetadata()
        if let online {
            metadata.online = online
        }
        metadata.onlineLookupSignature = signature
        metadata.onlineLookupFailedAt = failedAt
        items[id] = metadata
        save()
    }

    func markOrganizationAttempt(for id: String, signature: String) {
        var metadata = items[id] ?? MovieMetadata()
        metadata.organizationSignature = signature
        items[id] = metadata
        save()
    }

    @discardableResult
    func pruneMissingFiles(within sources: [LibrarySource]) -> Int {
        let roots = sources
            .filter { $0.isDirectory && $0.exists }
            .map { $0.url.standardizedFileURL.path }

        guard !roots.isEmpty else { return 0 }

        let before = items.count
        items = items.filter { id, _ in
            if FileManager.default.fileExists(atPath: id) {
                return true
            }
            let isInsideMountedSource = roots.contains { root in
                id == root || id.hasPrefix(root + "/")
            }
            return !isInsideMountedSource
        }

        let removed = before - items.count
        if removed > 0 {
            save()
        }
        return removed
    }

    func moveMetadata(
        from oldID: String,
        to newID: String,
        online: OnlineMovieMetadata?,
        genres: [String],
        onlineLookupSignature: String?,
        organizationSignature: String?
    ) {
        var metadata = items[oldID] ?? MovieMetadata()
        if let online {
            metadata.online = online
        }
        if let onlineLookupSignature {
            metadata.onlineLookupSignature = onlineLookupSignature
            metadata.onlineLookupFailedAt = nil
        }
        if let organizationSignature {
            metadata.organizationSignature = organizationSignature
        }
        metadata.genres = Movie.unique(metadata.genres + genres)
        items[newID] = metadata
        if oldID != newID {
            items.removeValue(forKey: oldID)
        }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            items = [:]
            return
        }
        items = (try? JSONDecoder().decode([String: MovieMetadata].self, from: data)) ?? [:]
    }

    private func adoptableMetadataID(fileIdentity: String?, legacyFileSignature: String?) -> String? {
        if let fileIdentity,
           let match = items.first(where: { id, metadata in
               metadata.fileIdentity == fileIdentity && !FileManager.default.fileExists(atPath: id)
           }) {
            return match.key
        }

        guard let legacyPrefix = legacySignaturePrefix(legacyFileSignature) else {
            return nil
        }

        return items.first { id, metadata in
            guard !FileManager.default.fileExists(atPath: id) else { return false }
            return metadata.onlineLookupSignature?.hasPrefix(legacyPrefix) == true ||
                metadata.organizationSignature?.hasPrefix(legacyPrefix) == true
        }?.key
    }

    private func legacySignaturePrefix(_ signature: String?) -> String? {
        guard let signature else { return nil }
        let parts = signature.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        return parts.prefix(3).joined(separator: ":") + ":"
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(items)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("Could not save metadata: \(error.localizedDescription)")
        }
    }
}
