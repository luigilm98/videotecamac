import Foundation

struct SeriesEpisodeInfo: Hashable {
    var seriesTitle: String
    var seasonNumber: Int
    var episodeNumber: Int
    var episodeTitle: String
}

enum SeriesDetector {
    static func episodeInfo(for movie: Movie, rootURL: URL? = nil) -> SeriesEpisodeInfo? {
        episodeInfo(for: movie.fileURL, rootURL: rootURL)
    }

    static func episodeInfo(for fileURL: URL, rootURL: URL? = nil) -> SeriesEpisodeInfo? {
        let rawFileBase = fileURL.deletingPathExtension().lastPathComponent
        let fileBase = cleanReleaseNoise(rawFileBase)
        let parent = fileURL.deletingLastPathComponent()
        let parentName = clean(parent.lastPathComponent)
        let grandparent = parent.deletingLastPathComponent()
        let grandparentName = clean(grandparent.lastPathComponent)
        let rootPath = rootURL?.standardizedFileURL.path
        let parentIsRoot = rootPath.map { parent.standardizedFileURL.path == $0 } ?? false
        let grandparentIsRoot = rootPath.map { grandparent.standardizedFileURL.path == $0 } ?? false

        if let season = seasonNumber(in: parentName),
           !grandparentIsRoot,
           let seriesTitle = usableSeriesTitle(grandparentName) {
            let parsedEpisode = leadingEpisodeNumber(in: rawFileBase) ?? leadingEpisodeNumber(in: fileBase)
            let episodeTitle = parsedEpisode?.title.nilIfBlank ?? cleanEpisodeTitle(fileBase)
            return SeriesEpisodeInfo(
                seriesTitle: seriesTitle,
                seasonNumber: season,
                episodeNumber: parsedEpisode?.number ?? 0,
                episodeTitle: episodeTitle
            )
        }

        if let coded = codedEpisode(in: rawFileBase) ?? codedEpisode(in: fileBase) {
            let titleFromName = cleanEpisodeTitle(
                rawFileBase.replacingOccurrences(of: coded.match, with: " ", options: .caseInsensitive)
            )
            let inferredSeries = usableSeriesTitle(titleFromName)
                ?? (parentIsRoot ? nil : usableSeriesTitle(parentName))
            guard let seriesTitle = inferredSeries else { return nil }
            return SeriesEpisodeInfo(
                seriesTitle: seriesTitle,
                seasonNumber: coded.season,
                episodeNumber: coded.episode,
                episodeTitle: titleFromName == seriesTitle ? "" : titleFromName
            )
        }

        if let parsedEpisode = leadingEpisodeNumber(in: rawFileBase) ?? leadingEpisodeNumber(in: fileBase),
           looseNumberedFolderLooksLikeSeries(parent: parent, rootURL: rootURL),
           let seriesTitle = usableSeriesTitle(parentName) {
            return SeriesEpisodeInfo(
                seriesTitle: seriesTitle,
                seasonNumber: 1,
                episodeNumber: parsedEpisode.number,
                episodeTitle: parsedEpisode.title
            )
        }

        return nil
    }

    static func isSeasonFolderName(_ value: String) -> Bool {
        seasonNumber(in: value) != nil
    }

    static func folderLooksLikeLooseSeries(for fileURL: URL, rootURL: URL? = nil) -> Bool {
        looseNumberedFolderLooksLikeSeries(parent: fileURL.deletingLastPathComponent(), rootURL: rootURL)
    }

    private static func seasonNumber(in value: String) -> Int? {
        let normalized = clean(value)
        let patterns = [
            #"(?i)^(?:stagione|season|serie|s)\s*0?(\d{1,2})$"#,
            #"(?i)^(?:stagione|season)\s+0?(\d{1,2})\b.*$"#
        ]
        for pattern in patterns {
            if let match = firstMatch(in: normalized, pattern: pattern),
               match.count > 1,
               let number = Int(match[1]) {
                return number
            }
        }
        return nil
    }

    private static func leadingEpisodeNumber(in value: String) -> (number: Int, title: String)? {
        guard let match = firstMatch(in: value, pattern: #"^\s*0?(\d{1,3})\s*[\.\-_\)]\s*(.+)$"#),
              match.count > 2,
              let number = Int(match[1]) else {
            return nil
        }
        return (number, cleanEpisodeTitle(match[2]))
    }

    private static func looseNumberedFolderLooksLikeSeries(parent: URL, rootURL: URL?) -> Bool {
        if let rootURL, parent.standardizedFileURL.path == rootURL.standardizedFileURL.path {
            return false
        }
        guard usableSeriesTitle(clean(parent.lastPathComponent)) != nil,
              let items = try? FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return false
        }

        var episodeNumbers = Set<Int>()
        for item in items {
            guard MovieScanner.isVideo(item),
                  (try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let rawBase = item.deletingPathExtension().lastPathComponent
            let cleanBase = cleanReleaseNoise(rawBase)
            if let parsed = leadingEpisodeNumber(in: rawBase) ?? leadingEpisodeNumber(in: cleanBase) {
                episodeNumbers.insert(parsed.number)
            }
        }
        return episodeNumbers.count >= 2
    }

    private static func codedEpisode(in value: String) -> (match: String, season: Int, episode: Int)? {
        let patterns = [
            #"(?i)\bS0?(\d{1,2})\s*E0?(\d{1,3})\b"#,
            #"(?i)\b0?(\d{1,2})x0?(\d{1,3})\b"#,
            #"(?i)\bStagione\s*0?(\d{1,2})\s*Episodio\s*0?(\d{1,3})\b"#,
            #"(?i)\bSeason\s*0?(\d{1,2})\s*Episode\s*0?(\d{1,3})\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = regex.firstMatch(in: value, range: range),
                  match.numberOfRanges > 2,
                  let fullRange = Range(match.range(at: 0), in: value),
                  let seasonRange = Range(match.range(at: 1), in: value),
                  let episodeRange = Range(match.range(at: 2), in: value),
                  let season = Int(value[seasonRange]),
                  let episode = Int(value[episodeRange]) else {
                continue
            }
            return (String(value[fullRange]), season, episode)
        }

        return nil
    }

    private static func usableSeriesTitle(_ value: String) -> String? {
        let cleaned = clean(value)
        let key = ManualMovieCorrections.normalized(cleaned)
        guard !cleaned.isEmpty,
              key.count > 2,
              !isLibraryRootName(key),
              seasonNumber(in: cleaned) == nil else {
            return nil
        }
        return cleaned
    }

    private static func cleanEpisodeTitle(_ value: String) -> String {
        var result = cleanReleaseNoise(value)
        result = result.replacingOccurrences(of: #"(?i)\b(?:mray|mr|xvid|rip)[a-z0-9]*\b$"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)\s+-\s+[a-z0-9]{4,12}$"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)\s+-\s*$"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"[\s]+"#, with: " ", options: .regularExpression)
        return clean(result)
    }

    private static func cleanReleaseNoise(_ value: String) -> String {
        var result = clean(value)
        result = result.replacingOccurrences(of: #"\[(?!\d{4}\])[^\]]+\]"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\{(?!\d{4}\})[^\}]+\}"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?i)\b(?:2160p|1080p|720p|480p|4k|uhd|hdr10\+?|hdr|bluray|blu ray|bdrip|brrip|webdl|web dl|webrip|web rip|dvdrip|hdtv|x264|x265|h264|h265|hevc|aac|ac3|eac3|dts|ita|eng|multi|sub|subs|mux|mircrew)\b.*$"#, with: " ", options: .regularExpression)
        return clean(result)
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

    private static func isLibraryRootName(_ key: String) -> Bool {
        let roots = [
            "film", "films", "movie", "movies", "video", "videos", "videoteca",
            "cinema", "download", "downloads", "scaricati", "cb01",
            "cb01 downloader", "ssd", "ssdex"
        ]
        return roots.contains(key)
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
