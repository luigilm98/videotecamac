import Foundation

struct MovieOrganizationSummary {
    var movedCount: Int = 0
    var skippedCount: Int = 0
    var failedCount: Int = 0
}

enum MovieOrganizer {
    private static let ignoredPathFragments = ["/_extra/", "/Featurettes/", "/featurettes/", "/Extras/", "/extras/"]
    private static let sidecarExtensions: Set<String> = ["srt", "ass", "ssa", "sub", "idx", "vtt", "jpg", "jpeg", "png", "webp", "nfo"]

    static func organize(
        movies: [Movie],
        sources: [LibrarySource],
        metadataStore: MetadataStore,
        coverCacheURL: URL,
        artworkDirectory: URL,
        logURL: URL,
        tmdbToken: String,
        progress: @escaping @Sendable (String) async -> Void
    ) async -> MovieOrganizationSummary {
        var summary = MovieOrganizationSummary()
        let candidates = movies.compactMap { movie -> (Movie, URL)? in
            guard let root = rootURL(for: movie, sources: sources), shouldConsider(movie: movie, rootURL: root) else {
                return nil
            }
            return (movie, root)
        }

        guard !candidates.isEmpty else {
            summary.skippedCount = movies.count
            return summary
        }

        for (index, item) in candidates.enumerated() {
            let movie = item.0
            let root = item.1
            await progress("Catalogo \(index + 1)/\(candidates.count): \(movie.title)")

            do {
                let existingOnline = movie.onlineMetadata.flatMap { online in
                    OnlineMetadataService.hasHardIdentityMismatch(online, with: movie)
                        ? nil
                        : OnlineMetadataService.completedWithLocalCorrections(online, for: movie)
                }
                let online: OnlineMovieMetadata?
                if let existingOnline {
                    online = existingOnline
                } else {
                    online = try? await OnlineMetadataService.fetch(
                        for: movie,
                        artworkDirectory: artworkDirectory,
                        tmdbToken: tmdbToken
                    )
                }
                if let online {
                    metadataStore.markOnlineLookup(for: movie.id, signature: movie.fileSignature, online: online, failedAt: nil)
                }
                guard let destination = destination(for: movie, rootURL: root, online: online) else {
                    metadataStore.markOrganizationAttempt(for: movie.id, signature: movie.fileSignature)
                    summary.skippedCount += 1
                    continue
                }

                if movie.fileURL.standardizedFileURL.path == destination.standardizedFileURL.path {
                    VideoMetadataCleaner.cleanGenericContainerTitleIfPossible(
                        fileURL: movie.fileURL,
                        title: online?.title ?? movie.displayTitle
                    )
                    if let online {
                        metadataStore.moveMetadata(
                            from: movie.id,
                            to: movie.id,
                            online: online,
                            genres: online.genres ?? [],
                            onlineLookupSignature: movie.fileSignature,
                            organizationSignature: movie.fileSignature
                        )
                    } else {
                        metadataStore.markOrganizationAttempt(for: movie.id, signature: movie.fileSignature)
                    }
                    summary.skippedCount += 1
                    continue
                }

                appendLog(
                    oldURL: movie.fileURL,
                    newURL: destination,
                    title: online?.title ?? movie.displayTitle,
                    status: "planned",
                    message: nil,
                    logURL: logURL
                )
                try move(movie: movie, to: destination, rootURL: root, coverCacheURL: coverCacheURL)
                VideoMetadataCleaner.cleanGenericContainerTitleIfPossible(
                    fileURL: destination,
                    title: online?.title ?? movie.displayTitle
                )
                metadataStore.moveMetadata(
                    from: movie.id,
                    to: destination.standardizedFileURL.path,
                    online: online,
                    genres: Movie.unique((online?.genres ?? []) + movie.inferredGenres),
                    onlineLookupSignature: online == nil ? nil : movie.fileSignature,
                    organizationSignature: movie.fileSignature
                )
                appendLog(
                    oldURL: movie.fileURL,
                    newURL: destination,
                    title: online?.title ?? movie.displayTitle,
                    status: "moved",
                    message: nil,
                    logURL: logURL
                )
                summary.movedCount += 1
            } catch {
                appendLog(
                    oldURL: movie.fileURL,
                    newURL: nil,
                    title: movie.displayTitle,
                    status: "failed",
                    message: error.localizedDescription,
                    logURL: logURL
                )
                summary.failedCount += 1
            }
        }

        let updatedMovies = MovieScanner.scan(sources: sources, metadataStore: metadataStore, coverCacheURL: coverCacheURL)
        _ = relocateOrphanReleaseFolders(sources: sources, movies: updatedMovies, logURL: logURL)
        summary.skippedCount += movies.count - candidates.count
        return summary
    }

    private static func rootURL(for movie: Movie, sources: [LibrarySource]) -> URL? {
        let moviePath = movie.fileURL.standardizedFileURL.path
        return sources
            .filter { $0.isDirectory && $0.exists }
            .map(\.url.standardizedFileURL)
            .filter { root in
                let rootPath = root.path
                return moviePath == rootPath || moviePath.hasPrefix(rootPath + "/")
            }
            .max { lhs, rhs in lhs.path.count < rhs.path.count }
    }

    private static func shouldConsider(movie: Movie, rootURL: URL) -> Bool {
        let path = movie.fileURL.standardizedFileURL.path
        guard !ignoredPathFragments.contains(where: { path.contains($0) }) else { return false }
        guard !ManualMovieCorrections.normalized(movie.fileName).contains("sample") else { return false }
        guard !ManualMovieCorrections.normalized(movie.fileName).contains("trailer") else { return false }
        guard SeriesDetector.episodeInfo(for: movie, rootURL: rootURL) == nil else { return false }
        guard !SeriesDetector.folderLooksLikeLooseSeries(for: movie.fileURL, rootURL: rootURL) else { return false }

        let parent = movie.fileURL.deletingLastPathComponent().lastPathComponent
        let parentKey = ManualMovieCorrections.normalized(parent)
        let directorKey = ManualMovieCorrections.normalized(movie.director)
        let titleKey = ManualMovieCorrections.normalized(movie.title)
        let fileKey = ManualMovieCorrections.normalized(movie.fileURL.deletingPathExtension().lastPathComponent)
        let rootKey = ManualMovieCorrections.normalized(rootURL.lastPathComponent)
        let fileBase = movie.fileURL.deletingPathExtension().lastPathComponent

        if let canonicalYear = canonicalYear(in: fileBase),
           let expectedYear = movie.displayYear,
           canonicalYear != expectedYear {
            return true
        }

        if isAlreadyCatalogued(parentKey: parentKey, directorKey: directorKey, titleKey: titleKey, fileKey: fileKey) {
            return false
        }

        if parentKey == rootKey {
            return true
        }

        return true
    }

    private static func isCanonicalFileName(_ value: String) -> Bool {
        firstMatch(in: value, pattern: #"^.+?\s+-\s+.+?\s+\(\d{4}\)\s+-\s+.+$"#) != nil
    }

    private static func canonicalYear(in value: String) -> Int? {
        guard let match = firstMatch(in: value, pattern: #"\((\d{4})\)"#),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return Int(value[range])
    }

    private static func isAlreadyCatalogued(parentKey: String, directorKey: String, titleKey: String, fileKey: String) -> Bool {
        let unknownKey = ManualMovieCorrections.normalized("Sconosciuto")
        guard !directorKey.isEmpty, directorKey != unknownKey, !titleKey.isEmpty else {
            return false
        }

        let parentMatchesDirector = parentKey == directorKey ||
            parentKey.contains(directorKey) ||
            directorKey.contains(parentKey)
        let fileLooksCanonical = fileKey.contains(directorKey) && fileKey.contains(titleKey)
        return parentMatchesDirector && fileLooksCanonical
    }

    private static func destination(for movie: Movie, rootURL: URL, online: OnlineMovieMetadata?) -> URL? {
        let title = (online?.title?.nilIfBlank ?? movie.displayTitle).nilIfBlank
        let localDirector = trustedLocalDirector(for: movie, rootURL: rootURL)
        let directors = Movie.unique((online?.directors ?? []) + [localDirector].compactMap { $0 })
        let director = directors.first { value in
            let key = ManualMovieCorrections.normalized(value)
            return !key.isEmpty && key != ManualMovieCorrections.normalized("Sconosciuto")
        }?.nilIfBlank
        let year = online?.releaseYear ?? movie.displayYear
        let cast = Movie.unique((online?.cast ?? []) + movie.actors)

        guard let title, let director, let year else {
            return nil
        }

        let actors = Array(cast.prefix(2))
        let actorText = actors.isEmpty ? "Unknown" : actors.joined(separator: ", ")
        let directorComponent = safeFileComponent(director)
        let titleComponent = safeFileComponent(title)
        let actorComponent = safeFileComponent(actorText)
        let ext = movie.fileURL.pathExtension.isEmpty ? "mkv" : movie.fileURL.pathExtension
        let folder = rootURL.appendingPathComponent(directorComponent, isDirectory: true)
        let baseName = "\(directorComponent) - \(titleComponent) (\(year)) - \(actorComponent)"
        return uniqueDestination(folder.appendingPathComponent(baseName).appendingPathExtension(ext), original: movie.fileURL)
    }

    private static func trustedLocalDirector(for movie: Movie, rootURL: URL) -> String? {
        let unknownKey = ManualMovieCorrections.normalized("Sconosciuto")
        let director = movie.director.nilIfBlank
        let directorKey = director.map(ManualMovieCorrections.normalized) ?? ""
        guard let director, !directorKey.isEmpty, directorKey != unknownKey else { return nil }

        let fileBase = movie.fileURL.deletingPathExtension().lastPathComponent
        if isCanonicalFileName(fileBase) {
            return director
        }

        let parent = movie.fileURL.deletingLastPathComponent().lastPathComponent
        let parentKey = ManualMovieCorrections.normalized(parent)
        let rootKey = ManualMovieCorrections.normalized(rootURL.lastPathComponent)
        let titleKey = ManualMovieCorrections.normalized(movie.title)

        guard parentKey != rootKey else { return nil }
        if parentKey.contains(titleKey) || titleKey.contains(parentKey) {
            return nil
        }
        if movie.year.map({ parentKey.contains(String($0)) }) == true {
            return nil
        }
        return director
    }

    private static func move(movie: Movie, to destination: URL, rootURL: URL, coverCacheURL: URL) throws {
        let manager = FileManager.default
        let oldURL = movie.fileURL
        let oldFolder = oldURL.deletingLastPathComponent()
        let newFolder = destination.deletingLastPathComponent()
        let oldBase = oldURL.deletingPathExtension().lastPathComponent
        let newBase = destination.deletingPathExtension().lastPathComponent

        try manager.createDirectory(at: newFolder, withIntermediateDirectories: true)
        try manager.moveItem(at: oldURL, to: destination)
        moveSidecars(oldFolder: oldFolder, newFolder: newFolder, oldBase: oldBase, newBase: newBase)
        moveCachedCover(from: oldURL, to: destination, coverCacheURL: coverCacheURL)
        removeFolderIfEmpty(oldFolder, rootURL: rootURL)
    }

    private static func moveSidecars(oldFolder: URL, newFolder: URL, oldBase: String, newBase: String) {
        guard let items = try? FileManager.default.contentsOfDirectory(at: oldFolder, includingPropertiesForKeys: nil) else {
            return
        }

        for item in items {
            let ext = item.pathExtension.lowercased()
            guard sidecarExtensions.contains(ext),
                  item.deletingPathExtension().lastPathComponent == oldBase else {
                continue
            }

            let candidate = newFolder.appendingPathComponent(newBase).appendingPathExtension(item.pathExtension)
            let destination = uniqueDestination(candidate, original: item)
            try? FileManager.default.moveItem(at: item, to: destination)
        }
    }

    private static func moveCachedCover(from oldURL: URL, to newURL: URL, coverCacheURL: URL) {
        let oldCover = CoverGenerator.cachedCoverURL(for: oldURL, cacheDirectory: coverCacheURL)
        let newCover = CoverGenerator.cachedCoverURL(for: newURL, cacheDirectory: coverCacheURL)
        guard FileManager.default.fileExists(atPath: oldCover.path),
              !FileManager.default.fileExists(atPath: newCover.path) else {
            return
        }
        try? FileManager.default.moveItem(at: oldCover, to: newCover)
    }

    private static func removeFolderIfEmpty(_ folder: URL, rootURL: URL) {
        return
    }

    private static func relocateOrphanReleaseFolders(sources: [LibrarySource], movies: [Movie], logURL: URL) -> Int {
        return 0
    }

    private static func shouldRelocateOrphanReleaseFolder(_ folder: URL, rootURL: URL, movies: [Movie]) -> Bool {
        let folderPath = folder.standardizedFileURL.path
        guard folder.deletingLastPathComponent().standardizedFileURL.path == rootURL.path,
              !folder.lastPathComponent.hasPrefix("_"),
              !movies.contains(where: { $0.fileURL.standardizedFileURL.path.hasPrefix(folderPath + "/") }) else {
            return false
        }

        let videos = videoFiles(in: folder)
        guard !videos.isEmpty else { return false }
        return videos.allSatisfy { url in
            let path = url.standardizedFileURL.path
            let nameKey = ManualMovieCorrections.normalized(url.deletingPathExtension().lastPathComponent)
            return ignoredPathFragments.contains(where: { path.contains($0) }) ||
                nameKey == "sample" ||
                nameKey.contains("trailer") ||
                nameKey.contains("interview") ||
                nameKey.contains("featurette")
        }
    }

    private static func matchingMovie(forReleaseFolder folder: URL, movies: [Movie]) -> Movie? {
        guard let parsed = releaseFolderTitleAndYear(folder.lastPathComponent) else { return nil }
        let titleKey = ManualMovieCorrections.normalized(parsed.title)
        return movies.first { movie in
            let movieTitles = [movie.title, movie.displayTitle]
                .map(ManualMovieCorrections.normalized)
            let titleMatches = movieTitles.contains { key in
                key == titleKey || key.contains(titleKey) || titleKey.contains(key)
            }
            let yearMatches = parsed.year == nil || movie.displayYear == nil || parsed.year == movie.displayYear
            return titleMatches && yearMatches
        }
    }

    private static func releaseFolderTitleAndYear(_ value: String) -> (title: String, year: Int?)? {
        var result = value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: #"\[(?!\d{4}\])[^\]]+\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\{(?!\d{4}\})[^\}]+\}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b(?:2160p|1080p|720p|480p|4k|uhd|hdr10\+?|hdr|bluray|blu ray|bdrip|brrip|webdl|web dl|webrip|web rip|dvdrip|hdtv|x264|x265|h264|h265|hevc|aac|ac3|eac3|dts|ita|eng|multi|sub|subs|mux|tigole|mircrew)\b.*$"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[\s]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let year = canonicalYear(in: result)
        result = result
            .replacingOccurrences(of: #"\((?:19|20)\d{2}\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[\s]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.nilIfBlank.map { ($0, year) }
    }

    private static func videoFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  MovieScanner.isVideo(url),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            return url
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func uniqueFolderDestination(_ destination: URL) -> URL {
        if !FileManager.default.fileExists(atPath: destination.path) {
            return destination
        }

        let parent = destination.deletingLastPathComponent()
        let base = destination.lastPathComponent
        var counter = 2
        while true {
            let candidate = parent.appendingPathComponent("\(base) \(counter)", isDirectory: true)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    private static func uniqueDestination(_ destination: URL, original: URL) -> URL {
        let manager = FileManager.default
        let originalPath = original.standardizedFileURL.path
        if !manager.fileExists(atPath: destination.path) || destination.standardizedFileURL.path == originalPath {
            return destination
        }

        let folder = destination.deletingLastPathComponent()
        let base = destination.deletingPathExtension().lastPathComponent
        let ext = destination.pathExtension
        var counter = 2
        while true {
            let candidate = folder.appendingPathComponent("\(base) \(counter)").appendingPathExtension(ext)
            if !manager.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }

    private static func safeFileComponent(_ value: String) -> String {
        let replacements: [Character: Character] = [
            "/": "-",
            ":": "-",
            "\n": " ",
            "\r": " ",
            "\t": " "
        ]
        var result = String(value.map { replacements[$0] ?? $0 })
        result = result
            .replacingOccurrences(of: #"[\s]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if result.count > 150 {
            result = String(result.prefix(150)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result.isEmpty ? "Sconosciuto" : result
    }

    private static func firstMatch(in value: String, pattern: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range)
    }

    private static func appendLog(oldURL: URL, newURL: URL?, title: String, status: String, message: String?, logURL: URL) {
        let entry = OrganizationLogEntry(
            date: ISO8601DateFormatter().string(from: Date()),
            title: title,
            oldPath: oldURL.path,
            newPath: newURL?.path,
            status: status,
            message: message
        )

        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = try JSONEncoder().encode(entry)
            data.append(0x0a)
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: logURL, options: [.atomic])
            }
        } catch {
            NSLog("Could not write organization log: \(error.localizedDescription)")
        }
    }
}

private struct OrganizationLogEntry: Encodable {
    let date: String
    let title: String
    let oldPath: String
    let newPath: String?
    let status: String
    let message: String?
}
