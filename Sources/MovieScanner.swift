import Foundation

enum MovieScanner {
    static let videoExtensions: Set<String> = ["mkv", "mp4", "avi", "mov", "m4v", "mpg", "mpeg"]
    private static let ignoredPathFragments = ["/_extra/", "/Featurettes/", "/featurettes/", "/Extras/", "/extras/"]
    private static let extraDirectoryNames: Set<String> = [
        "_extra", "featurettes", "extras", "extra", "sample", "samples",
        "trailer", "trailers"
    ]
    private static let ignoredDirectoryNames: Set<String> = [
        "_extra", "featurettes", "extras", "extra", "sample", "samples",
        "trailer", "trailers", "output", "tmp", "temp", "pdf", "pdfs",
        "info", "subs", "sub", "subtitles", "screens", "screenshots"
    ]

    static func scan(sources: [LibrarySource], metadataStore: MetadataStore, coverCacheURL: URL) -> [Movie] {
        var movies: [Movie] = []
        var extras: [MovieExtra] = []
        var seenPaths = Set<String>()

        for source in sources where source.exists {
            let root = source.url
            if source.isDirectory {
                movies.append(contentsOf: scanDirectory(
                    rootURL: root,
                    metadataStore: metadataStore,
                    coverCacheURL: coverCacheURL,
                    seenPaths: &seenPaths
                ))
                extras.append(contentsOf: collectExtras(rootURL: root))
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

        let moviesWithExtras = attach(extras: extras, to: movies, rootURLs: sources.filter(\.isDirectory).map(\.url))
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
                    seenPaths: &seenPaths
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

        let nameKey = ManualMovieCorrections.normalized(directory.lastPathComponent)
        if ignoredDirectoryNames.contains(nameKey) { return false }
        if ignoredPathFragments.contains(where: { standardizedPath.contains($0) }) { return false }
        return true
    }

    private static func collectExtras(rootURL: URL) -> [MovieExtra] {
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item -> MovieExtra? in
            guard let url = item as? URL,
                  isVideo(url),
                  isExtraPath(url, rootURL: rootURL),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }

            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let fileSize = Int64(values?.fileSize ?? 0)
            let standardizedPath = url.standardizedFileURL.path
            return MovieExtra(
                id: standardizedPath,
                fileURL: url,
                title: extraTitle(for: url, rootURL: rootURL),
                kind: extraKind(for: url, rootURL: rootURL, fileSize: fileSize),
                fileSize: fileSize,
                modifiedDate: values?.contentModificationDate ?? .distantPast
            )
        }
    }

    private static func attach(extras: [MovieExtra], to movies: [Movie], rootURLs: [URL]) -> [Movie] {
        guard !extras.isEmpty, !movies.isEmpty else { return movies }
        var result = movies

        for extra in extras.sorted(by: { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) {
            guard let matchIndex = bestMovieIndex(for: extra, in: result, rootURLs: rootURLs) else { continue }
            if !result[matchIndex].extras.contains(where: { $0.id == extra.id }) {
                result[matchIndex].extras.append(extra)
            }
        }

        for index in result.indices {
            result[index].extras.sort {
                if $0.kind != $1.kind {
                    return $0.kind.localizedCaseInsensitiveCompare($1.kind) == .orderedAscending
                }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }

        return result
    }

    private static func bestMovieIndex(for extra: MovieExtra, in movies: [Movie], rootURLs: [URL]) -> Int? {
        let extraPathKey = ManualMovieCorrections.normalized(extra.fileURL.deletingPathExtension().path)
        let extraTokens = Set(extraPathKey.split(separator: " ").map(String.init).filter { $0.count > 2 })
        let extraRoot = rootURL(containing: extra.fileURL, from: rootURLs)
        let extraDirector = extraRoot.flatMap { firstRelativeComponent(of: extra.fileURL, rootURL: $0) }

        var best: (index: Int, score: Int)?

        for (index, movie) in movies.enumerated() {
            var score = 0

            if let extraRoot,
               let extraDirector,
               firstRelativeComponent(of: movie.fileURL, rootURL: extraRoot) == extraDirector {
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

            for title in titles {
                let titleKey = ManualMovieCorrections.normalized(title)
                guard titleKey.count > 3 else { continue }
                if extraPathKey.contains(titleKey) {
                    score += 95 + min(25, titleKey.count / 2)
                    continue
                }

                let titleTokens = Set(titleKey.split(separator: " ").map(String.init).filter { $0.count > 2 })
                guard !titleTokens.isEmpty else { continue }
                let overlap = titleTokens.intersection(extraTokens).count
                if overlap == titleTokens.count {
                    score += 70
                } else if overlap >= max(2, titleTokens.count - 1) {
                    score += 42
                } else if overlap >= 2 {
                    score += 24
                }
            }

            if best == nil || score > best!.score {
                best = (index, score)
            }
        }

        guard let best, best.score >= 70 else { return nil }
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
        seenPaths: inout Set<String>
    ) -> Movie? {
        let standardizedPath = fileURL.standardizedFileURL.path
        guard isVideo(fileURL),
              !seenPaths.contains(standardizedPath),
              !ignoredPathFragments.contains(where: { standardizedPath.contains($0) }) else { return nil }
        guard !fileURL.lastPathComponent.hasPrefix("._") else { return nil }
        let fileKey = ManualMovieCorrections.normalized(fileURL.deletingPathExtension().lastPathComponent)
        guard fileKey != "sample", fileKey != "trailer" else { return nil }

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
        let technicalIdentity = VideoProbe.technicalSignature(for: fileURL, fileIdentity: identity)
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
        let parent = fileURL.deletingLastPathComponent().lastPathComponent
        let rootName = rootURL.lastPathComponent
        let fallbackDirector = parent == rootName ? "Sconosciuto" : parent
        let fileCandidate = releaseCleanedTitle(rawBaseName)
        let parentCandidate = folderCandidate(for: fileURL, rootURL: rootURL, fileCandidate: fileCandidate)
        let baseName = preferredParseName(
            fileCandidate: fileCandidate,
            parentCandidate: parentCandidate,
            rawFileName: rawBaseName
        )
        guard !isGenericContainerName(baseName) else { return nil }

        if let match = firstMatch(
            in: baseName,
            pattern: #"^(.+?)\s+-\s+(.+?)\s+\((\d{4})\)\s+-\s+(.+)$"#
        ) {
            let director = clean(match[1])
            let title = clean(match[2])
            let year = Int(match[3])
            let actorPart = clean(match[4])
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
                    if !ignoredDirectoryNames.contains(key) {
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
