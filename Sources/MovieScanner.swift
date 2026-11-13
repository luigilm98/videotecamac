import Foundation

enum MovieScanner {
    static let videoExtensions: Set<String> = ["mkv", "mp4", "avi", "mov", "m4v", "mpg", "mpeg"]
    private static let extraDirectoryNames: Set<String> = [
        "_extra", "featurettes", "extras", "extra", "sample", "samples",
        "trailer", "trailers"
    ]

    static func scan(sources: [LibrarySource], metadataStore: MetadataStore, coverCacheURL: URL) -> [Movie] {
        var movies: [Movie] = []
        var seenPaths = Set<String>()

        for source in sources where source.exists {
            let root = source.url.resolvingSymlinksInPath()
            if source.isDirectory {
                movies.append(contentsOf: scanDirectory(
                    rootURL: root,
                    metadataStore: metadataStore,
                    coverCacheURL: coverCacheURL,
                    seenPaths: &seenPaths
                ))
            } else if isVideo(root), let movie = movie(
                fileURL: root,
                rootURL: root.deletingLastPathComponent(),
                metadataStore: metadataStore,
                coverCacheURL: coverCacheURL,
                seenPaths: &seenPaths
            ) {
                movies.append(movie)
            }
        }

        let roots = sources.filter(\.isDirectory).map { $0.url.resolvingSymlinksInPath() }
        let extras = movies.compactMap { movie -> MovieExtra? in
            guard let root = rootURL(containing: movie.fileURL, from: roots),
                  isExtraPath(movie.fileURL, rootURL: root) else { return nil }
            return MovieExtra(
                id: movie.id, fileURL: movie.fileURL,
                title: extraTitle(for: movie.fileURL, rootURL: root),
                kind: extraKind(for: movie.fileURL, rootURL: root, fileSize: movie.fileSize),
                fileSize: movie.fileSize, modifiedDate: movie.modifiedDate
            )
        }
        let moviesWithExtras = attach(extras: extras, to: movies, rootURLs: roots)
        return moviesWithExtras.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    static func scan(rootURL: URL, metadataStore: MetadataStore, coverCacheURL: URL) -> [Movie] {
        scan(sources: [LibrarySource(url: rootURL)], metadataStore: metadataStore, coverCacheURL: coverCacheURL)
    }

    private static func scanDirectory(
        rootURL: URL,
        metadataStore: MetadataStore,
        coverCacheURL: URL,
        seenPaths: inout Set<String>
    ) -> [Movie] {
        var movies: [Movie] = []
        var pendingDirectories: [URL] = [rootURL]
        let rootPath = rootURL.standardizedFileURL.path

        while let directory = pendingDirectories.popLast() {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            let subtitleCandidates = VideoProbe.subtitleCandidates(from: items)
            for item in items {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true {
                    continue
                }

                if values?.isDirectory == true {
                    if shouldDescend(into: item, rootPath: rootPath) {
                        pendingDirectories.append(item)
                    }
                    continue
                }

                guard values?.isRegularFile == true else { continue }
                if let movie = movie(
                    fileURL: item,
                    rootURL: rootURL,
                    metadataStore: metadataStore,
                    coverCacheURL: coverCacheURL,
                    seenPaths: &seenPaths,
                    subtitleCandidates: subtitleCandidates
                ) {
                    movies.append(movie)
                }
            }
        }

        return movies
    }

    private static func shouldDescend(into directory: URL, rootPath: String) -> Bool {
        let standardizedPath = directory.standardizedFileURL.path
        guard standardizedPath.hasPrefix(rootPath + "/") else { return false }

        return true
    }

    private static func attach(extras: [MovieExtra], to movies: [Movie], rootURLs: [URL]) -> [Movie] {
        guard !extras.isEmpty, !movies.isEmpty else { return movies }
        var result = movies
        let extraIDs = Set(extras.map(\.id))
        var attachedIDs = Set<String>()

        for extra in extras.sorted(by: { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) {
            guard let root = rootURL(containing: extra.fileURL, from: rootURLs),
                  SeriesDetector.episodeInfo(for: extra.fileURL, rootURL: root) == nil,
                  let matchIndex = bestMovieIndex(for: extra, in: result, rootURL: root, extraIDs: extraIDs) else { continue }
            if !result[matchIndex].extras.contains(where: { $0.id == extra.id }) {
                result[matchIndex].extras.append(extra)
            }
            attachedIDs.insert(extra.id)
        }

        for index in result.indices {
            result[index].extras.sort {
                if $0.kind != $1.kind {
                    return $0.kind.localizedCaseInsensitiveCompare($1.kind) == .orderedAscending
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }

        return result.filter { !attachedIDs.contains($0.id) }
    }

    private static func bestMovieIndex(for extra: MovieExtra, in movies: [Movie], rootURL: URL, extraIDs: Set<String>) -> Int? {
        var components = relativeComponents(of: extra.fileURL, rootURL: rootURL)
        if !components.isEmpty {
            components[components.count - 1] = extra.fileURL.deletingPathExtension().lastPathComponent
        }
        let extraPathKey = ManualMovieCorrections.normalized(components.joined(separator: " "))
        let extraDirector = components.first
        let isLegacyExtra = components.dropLast().contains { $0 == "_extra" }
        if isLegacyExtra {
            let kind = ManualMovieCorrections.normalized(components.last ?? "")
            let markers = ["trailer", "featurette", "intervista", "interview", "making of", "sample", "deleted scene", "dietro le quinte"]
            guard markers.contains(where: { (" " + kind + " ").contains(" " + $0 + " ") }) else { return nil }
        } else if let bonusDirectoryIndex = components.dropLast().firstIndex(where: {
            extraDirectoryNames.contains(ManualMovieCorrections.normalized($0))
        }), bonusDirectoryIndex > 0 {
            let parentComponents = Array(components.prefix(bonusDirectoryIndex))
            let siblings = movies.indices.filter { index in
                let movie = movies[index]
                return !extraIDs.contains(movie.id)
                    && Array(relativeComponents(of: movie.fileURL, rootURL: rootURL).dropLast()) == parentComponents
            }
            if siblings.count == 1 { return siblings.first }
        }

        var best: (index: Int, score: Int)?
        var runnerUp = 0

        for (index, movie) in movies.enumerated() {
            guard !extraIDs.contains(movie.id),
                  let director = firstRelativeComponent(of: movie.fileURL, rootURL: rootURL) else { continue }
            var score = 0

            if director == extraDirector {
                score += 25
            }

            if let year = movie.displayYear, extraPathKey.contains(String(year)) {
                score += 18
            }

            let titles = Movie.unique([
                movie.title,
                movie.displayTitle,
                movie.onlineMetadata?.originalTitle
            ].compactMap { $0 })

            var titleScore = 0
            for title in titles {
                let titleKey = ManualMovieCorrections.normalized(title)
                guard titleKey.count > 3 else { continue }
                if (" " + extraPathKey + " ").contains(" " + titleKey + " ") {
                    titleScore = max(titleScore, 95 + min(25, titleKey.count / 2))
                }
            }
            guard titleScore > 0 else { continue }
            score += titleScore

            if best == nil || score > best!.score {
                runnerUp = best?.score ?? 0
                best = (index, score)
            } else {
                runnerUp = max(runnerUp, score)
            }
        }

        guard let best, best.score >= 95, best.score - runnerUp >= 20 else { return nil }
        return best.index
    }

    private static func isExtraPath(_ url: URL, rootURL: URL) -> Bool {
        let components = relativeComponents(of: url, rootURL: rootURL).dropLast()
        return components.contains { extraDirectoryNames.contains(ManualMovieCorrections.normalized($0)) }
    }

    private static func extraTitle(for url: URL, rootURL: URL) -> String {
        let fileTitle = releaseCleanedTitle(url.deletingPathExtension().lastPathComponent)
        if !isGenericContainerName(fileTitle) {
            return fileTitle
        }

        let candidates = relativeComponents(of: url, rootURL: rootURL)
            .dropLast()
            .reversed()
            .map(releaseCleanedTitle)
            .filter { !$0.isEmpty && !isGenericContainerName($0) }

        if let candidate = candidates.first {
            return "\(fileTitle.isEmpty ? "Extra" : fileTitle) - \(candidate)"
        }

        return url.deletingPathExtension().lastPathComponent
    }

    private static func extraKind(for url: URL, rootURL: URL, fileSize: Int64) -> String {
        let keys = relativeComponents(of: url, rootURL: rootURL)
            .map { ManualMovieCorrections.normalized(URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent) }
        let pathKey = ManualMovieCorrections.normalized(url.path)

        if keys.contains("featurettes") || keys.contains("featurette") { return "Featurette" }
        if keys.contains("trailer") || keys.contains("trailers") { return "Trailer" }
        if keys.contains("sample") || keys.contains("samples") { return "Sample" }
        if fileSize > 300_000_000 ||
            pathKey.contains("release originale") ||
            pathKey.contains("versione") ||
            pathKey.contains("alternate") ||
            pathKey.contains("director cut") ||
            pathKey.contains("final cut") ||
            pathKey.contains("rm4k") ||
            pathKey.contains("remux") {
            return "Versione"
        }
        return "Extra"
    }

    private static func rootURL(containing url: URL, from rootURLs: [URL]) -> URL? {
        let path = url.standardizedFileURL.path
        return rootURLs
            .filter { path.hasPrefix($0.standardizedFileURL.path + "/") || path == $0.standardizedFileURL.path }
            .max { $0.standardizedFileURL.path.count < $1.standardizedFileURL.path.count }
    }

    private static func firstRelativeComponent(of url: URL, rootURL: URL) -> String? {
        relativeComponents(of: url, rootURL: rootURL).first
    }

    private static func relativeComponents(of url: URL, rootURL: URL) -> [String] {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return [] }
        let relative = String(path.dropFirst(rootPath.count + 1))
        return relative.split(separator: "/").map(String.init)
    }

    private static func movie(
        fileURL: URL,
        rootURL: URL,
        metadataStore: MetadataStore,
        coverCacheURL: URL,
        seenPaths: inout Set<String>,
        subtitleCandidates: [URL]? = nil
    ) -> Movie? {
        let standardizedPath = fileURL.standardizedFileURL.path
        guard isVideo(fileURL),
              !seenPaths.contains(standardizedPath) else { return nil }
        guard !fileURL.lastPathComponent.hasPrefix("._") else { return nil }

        let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values?.isRegularFile == true else { return nil }
        seenPaths.insert(standardizedPath)

        let fileSize = Int64(values?.fileSize ?? 0)
        guard fileSize > 0 else { return nil }
        let modifiedDate = values?.contentModificationDate ?? Date.distantPast
        let identity = fileIdentity(fileSize: fileSize, modifiedDate: modifiedDate)
        guard let parsed = parse(fileURL: fileURL, rootURL: rootURL) else { return nil }
        let metadata = metadataStore.metadata(
            for: standardizedPath,
            fileIdentity: identity,
            legacyFileSignature: legacyFileSignature(
                fileURL: fileURL,
                fileSize: fileSize,
                modifiedDate: modifiedDate
            )
        )
        let coverURL = CoverGenerator.existingCover(for: fileURL, cacheDirectory: coverCacheURL)
        let technicalIdentity: String
        if let subtitleCandidates {
            technicalIdentity = VideoProbe.technicalSignature(
                for: fileURL, fileIdentity: identity, subtitleCandidates: subtitleCandidates
            )
        } else {
            technicalIdentity = VideoProbe.technicalSignature(for: fileURL, fileIdentity: identity)
        }
        let technicalInfo = metadata.technicalSignature == technicalIdentity ? metadata.technicalInfo : nil

        return Movie(
            id: standardizedPath,
            fileURL: fileURL,
            title: parsed.title,
            director: parsed.director,
            year: parsed.year,
            actors: parsed.actors,
            inferredGenres: parsed.inferredGenres,
            userGenres: metadata.genres,
            favorite: metadata.favorite,
            watched: metadata.watched,
            notes: metadata.notes,
            onlineMetadata: metadata.online,
            onlineLookupSignature: metadata.onlineLookupSignature,
            onlineLookupFailedAt: metadata.onlineLookupFailedAt,
            organizationSignature: metadata.organizationSignature,
            technicalInfo: technicalInfo,
            technicalSignature: metadata.technicalSignature,
            fileSize: fileSize,
            modifiedDate: modifiedDate,
            coverURL: coverURL
        )
    }

    private static func fileIdentity(fileSize: Int64, modifiedDate: Date) -> String {
        "v2:\(fileSize):\(Int(modifiedDate.timeIntervalSince1970))"
    }

    private static func legacyFileSignature(fileURL: URL, fileSize: Int64, modifiedDate: Date) -> String {
        "v1:\(fileSize):\(Int(modifiedDate.timeIntervalSince1970)):\(fileURL.lastPathComponent)"
    }

    static func isVideo(_ url: URL) -> Bool {
        guard !url.lastPathComponent.hasPrefix("._") else { return false }
        return videoExtensions.contains(url.pathExtension.lowercased())
    }

    private static func parse(fileURL: URL, rootURL: URL) -> ParsedMovieInfo? {
        let rawBaseName = fileURL.deletingPathExtension().lastPathComponent
        let fallbackDirector = "Sconosciuto"
        let fileCandidate = releaseCleanedTitle(rawBaseName)
        let parentCandidate = folderCandidate(for: fileURL, rootURL: rootURL, fileCandidate: fileCandidate)
        let baseName = preferredParseName(
            fileCandidate: fileCandidate,
            parentCandidate: parentCandidate,
            rawFileName: rawBaseName
        )
        if isGenericContainerName(baseName) {
            return ManualMovieCorrections.apply(
                fileURL: fileURL, title: rawBaseName, director: fallbackDirector,
                year: nil, actors: [], inferredGenres: []
            )
        }

        if let match = firstMatch(
            in: baseName,
            pattern: #"^(.+?)\s+-\s+(.+?)\s+\((\d{4})\)(?:\s+-\s+(.+))?$"#
        ) {
            let director = clean(match[1])
            let title = clean(match[2])
            let year = Int(match[3])
            let actorPart = match.count > 4 ? clean(match[4]) : ""
            var inferredGenres: [String] = []
            var actors: [String] = []

            if actorPart.localizedCaseInsensitiveContains("documentary") {
                inferredGenres.append("Documentario")
            } else if actorPart.localizedCaseInsensitiveContains("unknown") {
                actors = []
            } else {
                actors = splitList(actorPart)
            }

            return ManualMovieCorrections.apply(
                fileURL: fileURL,
                title: title,
                director: director,
                year: year,
                actors: actors,
                inferredGenres: inferredGenres
            )
        }

        if let match = firstMatch(in: baseName, pattern: #"^(.+?)\s+\((\d{4})\).*$"#) {
            return ManualMovieCorrections.apply(
                fileURL: fileURL,
                title: clean(match[1]),
                director: fallbackDirector,
                year: Int(match[2]),
                actors: [],
                inferredGenres: []
            )
        }

        if let match = firstMatch(in: baseName, pattern: #"^(.+?)\s+((?:19|20)\d{2})\b.*$"#) {
            return ManualMovieCorrections.apply(
                fileURL: fileURL,
                title: clean(match[1]),
                director: fallbackDirector,
                year: Int(match[2]),
                actors: [],
                inferredGenres: []
            )
        }

        return ManualMovieCorrections.apply(
            fileURL: fileURL,
            title: clean(baseName),
            director: fallbackDirector,
            year: nil,
            actors: [],
            inferredGenres: []
        )
    }

    private static func splitList(_ value: String) -> [String] {
        Movie.unique(value.split(separator: ",").map { String($0) })
    }

    private static func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " - ")
            .replacingOccurrences(of: "–", with: " - ")
            .replacingOccurrences(of: "—", with: " - ")
            .replacingOccurrences(of: #"[\s]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func releaseCleanedTitle(_ value: String) -> String {
        var result = clean(value)
        result = result.replacingOccurrences(of: #"(?i)\b(www|downloaded|scaricato|torrent|watch|guarda)\b.*?\b(from|da)?\b"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\[(?!\d{4}\])[^\]]+\]"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\{(?!\d{4}\})[^\}]+\}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\((?!\d{4}\))[^\)]+\)"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)\b(?:extended|unrated|remastered|restored|proper|repack|limited|criterion|directors cut|director s cut|theatrical|final cut|uncut)\b"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)\b(?:2160p|1080p|1080i|720p|576p|480p|4k|uhd|hdr10\+?|hdr|dv|dolby vision|bluray|blu ray|bdrip|br rip|brrip|web dl|webdl|webrip|web rip|hdtv|dvdrip|dvd rip|dvd9|dvd5|remux)\b.*$"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)\b(?:h264|h265|h 264|h 265|x264|x265|hevc|avc|aac|ac3|eac3|dts|truehd|atmos|ddp?5?1?|5 1|7 1|2 0|10bit|8bit)\b.*$"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)\b(?:ita|italian|eng|english|multi|multi audio|dual audio|sub ita|subbed|sub|subs|forced|mux|mircrew|sp33dy94|gozer)\b.*$"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)\s+-\s+(?:[a-z0-9]{2,12})$"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)\b(?:mkv|mp4|avi|mov|m4v)$"#, with: " ", options: .regularExpression)
        return clean(result)
    }

    private static func preferredParseName(fileCandidate: String, parentCandidate: String?, rawFileName: String) -> String {
        guard let parentCandidate,
              !parentCandidate.isEmpty,
              !isGenericContainerName(parentCandidate) else {
            return fileCandidate
        }

        if isCanonicalFileName(fileCandidate) {
            return fileCandidate
        }

        let fileScore = parseCandidateScore(fileCandidate, rawName: rawFileName)
        let parentScore = parseCandidateScore(parentCandidate, rawName: parentCandidate)

        if isGenericContainerName(fileCandidate) || parentScore >= fileScore + 8 {
            return parentCandidate
        }

        return fileCandidate
    }

    private static func folderCandidate(for fileURL: URL, rootURL: URL, fileCandidate: String) -> String? {
        guard isGenericContainerName(fileCandidate) else {
            let parent = fileURL.deletingLastPathComponent().lastPathComponent
            return parent == rootURL.lastPathComponent ? nil : releaseCleanedTitle(parent)
        }

        let rootPath = rootURL.standardizedFileURL.path
        var directory = fileURL.deletingLastPathComponent()

        while true {
            let directoryPath = directory.standardizedFileURL.path
            let candidate = releaseCleanedTitle(directory.lastPathComponent)
            let parentPath = directory.deletingLastPathComponent().standardizedFileURL.path
            let isRoot = directoryPath == rootPath
            let isDirectChildOfRoot = parentPath == rootPath

            if !candidate.isEmpty,
               !isGenericContainerName(candidate),
               !isLibraryRootName(candidate) {
                if isRoot || isDirectChildOfRoot {
                    if isSelfContainedReleaseFolder(directory: directory, fileURL: fileURL) {
                        return candidate
                    }
                } else {
                    return candidate
                }
            }

            if isRoot { break }
            let next = directory.deletingLastPathComponent()
            if next.standardizedFileURL.path == directoryPath { break }
            directory = next
        }

        return nil
    }

    private static func isSelfContainedReleaseFolder(directory: URL, fileURL: URL) -> Bool {
        let targetPath = fileURL.standardizedFileURL.path
        var pendingDirectories = [directory]
        var videoCount = 0

        while let current = pendingDirectories.popLast() {
            guard let items = try? FileManager.default.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for item in items {
                let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }

                if values?.isDirectory == true {
                    let key = ManualMovieCorrections.normalized(item.lastPathComponent)
                    if !extraDirectoryNames.contains(key) {
                        pendingDirectories.append(item)
                    }
                    continue
                }

                guard values?.isRegularFile == true, isVideo(item) else { continue }
                videoCount += 1
                if item.standardizedFileURL.path != targetPath || videoCount > 1 {
                    return false
                }
            }
        }

        return videoCount == 1
    }

    private static func parseCandidateScore(_ value: String, rawName: String) -> Int {
        let key = ManualMovieCorrections.normalized(value)
        guard !key.isEmpty else { return -100 }

        var score = min(40, key.count / 2)
        if firstMatch(in: value, pattern: #"\b(?:19|20)\d{2}\b"#) != nil { score += 18 }
        if isCanonicalFileName(value) { score += 30 }
        if isGenericContainerName(value) { score -= 35 }
        let words = key.split(separator: " ")
        score += min(18, words.filter { $0.count > 2 }.count * 3)

        let rawKey = ManualMovieCorrections.normalized(rawName)
        let releaseNoise = [
            "1080p", "2160p", "720p", "web", "bluray", "bdrip", "x264", "x265",
            "hevc", "aac", "ac3", "dts", "ita", "eng", "sub"
        ]
        score -= releaseNoise.filter { rawKey.contains($0) }.count * 2
        return score
    }

    private static func isGenericContainerName(_ value: String) -> Bool {
        let key = ManualMovieCorrections.normalized(value)
        guard !key.isEmpty else { return true }
        let generic = [
            "movie", "movies", "film", "films", "video", "videos", "media",
            "watch", "guarda", "download", "downloads", "scaricati",
            "master", "index", "stream", "source", "playlist", "manifest",
            "sample", "trailer", "feature", "featurette", "cd1", "cd2",
            "disc1", "disc2", "dvd1", "dvd2", "bd1", "bd2"
        ]
        if generic.contains(key) { return true }
        if key.count <= 2 { return true }
        return false
    }

    private static func isLibraryRootName(_ value: String) -> Bool {
        let key = ManualMovieCorrections.normalized(value)
        let roots = [
            "film", "films", "movie", "movies", "video", "videos", "videoteca",
            "cinema", "download", "downloads", "scaricati", "cb01",
            "cb01 downloader"
        ]
        return roots.contains(key)
    }

    private static func isCanonicalFileName(_ value: String) -> Bool {
        firstMatch(in: value, pattern: #"^.+?\s+-\s+.+?\s+\(\d{4}\)\s+-\s+.+$"#) != nil
    }

    private static func firstMatch(in value: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range) else { return nil }
        return (0..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
    }
}
