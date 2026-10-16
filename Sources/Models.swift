import Foundation

struct Movie: Identifiable, Hashable {
    let id: String
    let fileURL: URL
    var extras: [MovieExtra] = []
    var title: String
    var director: String
    var year: Int?
    var actors: [String]
    var inferredGenres: [String]
    var userGenres: [String]
    var favorite: Bool
    var watched: Bool
    var notes: String
    var onlineMetadata: OnlineMovieMetadata?
    var onlineLookupSignature: String?
    var onlineLookupFailedAt: Date?
    var organizationSignature: String?
    var technicalInfo: VideoTechnicalInfo?
    var technicalSignature: String?
    var fileSize: Int64
    var modifiedDate: Date
    var coverURL: URL?

    var genres: [String] {
        Movie.unique(inferredGenres + userGenres)
    }

    var displayTitle: String {
        onlineMetadata?.title?.nilIfBlank ?? title
    }

    var displayDirector: String {
        let directors = onlineMetadata?.directors ?? []
        let knownDirector = ManualMovieCorrections.normalized(director) == ManualMovieCorrections.normalized("Sconosciuto")
            ? nil
            : director
        let combined = Movie.unique([knownDirector].compactMap { $0 } + directors)
        return combined.isEmpty ? director : combined.joined(separator: ", ")
    }

    var displayActors: [String] {
        let cast = onlineMetadata?.cast ?? []
        return actors.isEmpty ? cast : Movie.unique(actors + cast)
    }

    var displayGenres: [String] {
        Movie.unique((onlineMetadata?.genres ?? []) + genres)
    }

    var displayYear: Int? {
        onlineMetadata?.releaseYear ?? year
    }

    var displayYearText: String {
        displayYear.map(String.init) ?? "Senza anno"
    }

    var metadataQuality: MovieMetadataQuality {
        let severities = qualityIssues.map(\.severity)
        if severities.contains(.critical) || severities.filter({ $0 == .warning }).count >= 2 {
            return .review
        }
        if severities.contains(.warning) || severities.contains(.info) {
            return .medium
        }
        return .high
    }

    var qualityIssues: [MovieQualityIssue] {
        var issues: [MovieQualityIssue] = []

        if onlineMetadata == nil {
            issues.append(MovieQualityIssue(
                title: "Metadati online mancanti",
                detail: "Titolo, descrizione, cast o fonte non sono stati salvati.",
                severity: .critical
            ))
        }

        if posterURL == nil {
            issues.append(MovieQualityIssue(
                title: "Locandina mancante",
                detail: "Non c'e una locandina ufficiale salvata per questo film.",
                severity: .critical
            ))
        }

        if hasWeakOverview {
            issues.append(MovieQualityIssue(
                title: "Descrizione debole",
                detail: "La descrizione e assente o troppo corta per essere utile.",
                severity: .warning
            ))
        }

        if displayGenres.isEmpty {
            issues.append(MovieQualityIssue(
                title: "Genere mancante",
                detail: "Il film non compare nei filtri per genere.",
                severity: .warning
            ))
        }

        if displayActors.isEmpty {
            issues.append(MovieQualityIssue(
                title: "Cast mancante",
                detail: "Non sono salvati attori principali.",
                severity: .info
            ))
        }

        if ManualMovieCorrections.normalized(displayDirector) == ManualMovieCorrections.normalized("Sconosciuto") {
            issues.append(MovieQualityIssue(
                title: "Regista sconosciuto",
                detail: "La catalogazione per regista puo essere sbagliata.",
                severity: .warning
            ))
        }

        if let localYear = year,
           let onlineYear = onlineMetadata?.releaseYear,
           abs(localYear - onlineYear) > 1 {
            issues.append(MovieQualityIssue(
                title: "Anno sospetto",
                detail: "Il file indica \(localYear), la scheda online \(onlineYear).",
                severity: .warning
            ))
        }

        guard let technicalInfo else {
            issues.append(MovieQualityIssue(
                title: "Scheda tecnica mancante",
                detail: "Durata, risoluzione, audio e sottotitoli non sono stati letti.",
                severity: .warning
            ))
            return issues
        }

        if technicalInfo.durationSeconds == nil {
            issues.append(MovieQualityIssue(
                title: "Durata non rilevata",
                detail: "Il file non espone una durata leggibile.",
                severity: .warning
            ))
        }

        if technicalInfo.width == nil || technicalInfo.height == nil {
            issues.append(MovieQualityIssue(
                title: "Risoluzione non rilevata",
                detail: "Il file non espone dimensioni video leggibili.",
                severity: .warning
            ))
        }

        if technicalInfo.audioTracks.isEmpty {
            issues.append(MovieQualityIssue(
                title: "Audio non rilevato",
                detail: "Non risultano tracce audio nel file.",
                severity: .critical
            ))
        }

        return issues
    }

    var hasWeakOverview: Bool {
        guard let overview = overview else { return true }
        let normalized = ManualMovieCorrections.normalized(overview)
        if normalized.count < 80 { return true }
        let weakPhrases = ["trama non disponibile", "descrizione non disponibile", "sinossi non disponibile"]
        return weakPhrases.contains { normalized.contains($0) }
    }

    var overview: String? {
        onlineMetadata?.overview?.nilIfBlank
    }

    var posterURL: URL? {
        if let path = onlineMetadata?.artworkPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return coverURL
    }

    var posterCacheKey: String {
        let artworkKey = onlineMetadata?.artworkPath ?? coverURL?.path ?? "placeholder"
        let fetchedKey = onlineMetadata?.fetchedAt.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
        return "\(id)|\(artworkKey)|\(fetchedKey)"
    }

    var fileIdentity: String {
        let timestamp = Int(modifiedDate.timeIntervalSince1970)
        return "v2:\(fileSize):\(timestamp)"
    }

    var technicalIdentity: String {
        VideoProbe.technicalSignature(for: fileURL, fileIdentity: fileIdentity)
    }

    var yearText: String {
        year.map(String.init) ?? "Senza anno"
    }

    var fileName: String {
        fileURL.lastPathComponent
    }

    var folderName: String {
        fileURL.deletingLastPathComponent().lastPathComponent
    }

    var fileSignature: String {
        fileIdentity
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return trimmed
        }
    }
}

struct MovieExtra: Identifiable, Hashable {
    let id: String
    let fileURL: URL
    var title: String
    var kind: String
    var fileSize: Int64
    var modifiedDate: Date

    var fileName: String {
        fileURL.lastPathComponent
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}

struct MovieMetadata: Codable, Equatable {
    var genres: [String] = []
    var favorite: Bool = false
    var watched: Bool = false
    var notes: String = ""
    var online: OnlineMovieMetadata? = nil
    var onlineLookupSignature: String? = nil
    var onlineLookupFailedAt: Date? = nil
    var organizationSignature: String? = nil
    var fileIdentity: String? = nil
    var technicalInfo: VideoTechnicalInfo? = nil
    var technicalSignature: String? = nil
    var containerTitleSignature: String? = nil
    var subtitleLookupSignature: String? = nil
    var subtitleLookupFailedAt: Date? = nil
}

struct SeriesEpisode: Identifiable, Hashable {
    var id: String { movie.id }
    var movie: Movie
    var seasonNumber: Int
    var episodeNumber: Int
    var episodeTitle: String

    var displayTitle: String {
        episodeTitle.nilIfBlank ?? movie.displayTitle
    }

    var code: String {
        if episodeNumber > 0 {
            return String(format: "S%02dE%02d", seasonNumber, episodeNumber)
        }
        return String(format: "S%02d", seasonNumber)
    }
}

struct SeriesGroup: Identifiable, Hashable {
    var id: String
    var title: String
    var episodes: [SeriesEpisode]
    var onlineMetadata: OnlineMovieMetadata? = nil

    var displayTitle: String {
        onlineMetadata?.title?.nilIfBlank ?? title
    }

    var sortedEpisodes: [SeriesEpisode] {
        episodes.sorted { lhs, rhs in
            if lhs.seasonNumber != rhs.seasonNumber {
                return lhs.seasonNumber < rhs.seasonNumber
            }
            if lhs.episodeNumber != rhs.episodeNumber {
                return lhs.episodeNumber < rhs.episodeNumber
            }
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }
    }

    var seasons: [Int] {
        Array(Set(episodes.map(\.seasonNumber))).sorted()
    }

    var representativeEpisode: SeriesEpisode? {
        sortedEpisodes.first
    }

    var representativeMovie: Movie? {
        representativeEpisode?.movie
    }

    var posterURL: URL? {
        if let path = onlineMetadata?.artworkPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return sortedEpisodes.compactMap { $0.movie.posterURL }.first
    }

    var posterCacheKey: String {
        let posterKey = posterURL?.path ?? "placeholder"
        return "\(id)|\(episodes.count)|\(posterKey)"
    }

    var displayYear: Int? {
        if let year = onlineMetadata?.releaseYear {
            return year
        }
        return sortedEpisodes.compactMap { $0.movie.displayYear }.min()
    }

    var displayYearText: String {
        let years = Array(Set(sortedEpisodes.compactMap { $0.movie.displayYear })).sorted()
        guard let first = years.first else { return "Serie TV" }
        if let last = years.last, last != first {
            return "\(first)-\(last)"
        }
        return "\(first)"
    }

    var displayGenres: [String] {
        Movie.unique((onlineMetadata?.genres ?? []) + sortedEpisodes.flatMap { $0.movie.displayGenres })
    }

    var displayActors: [String] {
        Movie.unique((onlineMetadata?.cast ?? []) + sortedEpisodes.flatMap { $0.movie.displayActors })
    }

    var displayDirector: String {
        if let directors = onlineMetadata?.directors, !directors.isEmpty {
            return directors.joined(separator: ", ")
        }
        let values = Movie.unique(sortedEpisodes.map(\.movie.displayDirector))
        let unknownKey = ManualMovieCorrections.normalized("Sconosciuto")
        let filtered = values.filter { ManualMovieCorrections.normalized($0) != unknownKey }
        return filtered.prefix(3).joined(separator: ", ").nilIfBlank ?? "Serie TV"
    }

    var favorite: Bool {
        episodes.contains { $0.movie.favorite }
    }

    var watched: Bool {
        !episodes.isEmpty && episodes.allSatisfy { $0.movie.watched }
    }

    var modifiedDate: Date {
        episodes.map(\.movie.modifiedDate).max() ?? .distantPast
    }

    var fileSize: Int64 {
        episodes.reduce(Int64(0)) { $0 + $1.movie.fileSize }
    }

    var sizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var overview: String? {
        onlineMetadata?.overview?.nilIfBlank ?? sortedEpisodes.compactMap { $0.movie.overview }.first
    }

    var subtitle: String {
        let seasonText = seasons.count == 1 ? "1 stagione" : "\(seasons.count) stagioni"
        let episodeText = episodes.count == 1 ? "1 episodio" : "\(episodes.count) episodi"
        return "\(seasonText) - \(episodeText)"
    }
}

enum LibraryItemKind: Hashable {
    case movie
    case series
}

struct LibraryItem: Identifiable, Hashable {
    var id: String
    var kind: LibraryItemKind
    var movie: Movie?
    var series: SeriesGroup?

    var displayTitle: String {
        series?.displayTitle ?? movie?.displayTitle ?? ""
    }

    var displayYear: Int? {
        series?.displayYear ?? movie?.displayYear
    }

    var displayYearText: String {
        series?.displayYearText ?? movie?.displayYearText ?? "Senza anno"
    }

    var displaySubtitle: String {
        if let series {
            return series.subtitle
        }
        guard let movie else { return "" }
        return [movie.displayYearText, movie.displayDirector].joined(separator: " - ")
    }

    var posterURL: URL? {
        series?.posterURL ?? movie?.posterURL
    }

    var posterCacheKey: String {
        series?.posterCacheKey ?? movie?.posterCacheKey ?? id
    }

    var displayGenres: [String] {
        series?.displayGenres ?? movie?.displayGenres ?? []
    }

    var displayActors: [String] {
        series?.displayActors ?? movie?.displayActors ?? []
    }

    var displayDirector: String {
        series?.displayDirector ?? movie?.displayDirector ?? ""
    }

    var favorite: Bool {
        series?.favorite ?? movie?.favorite ?? false
    }

    var watched: Bool {
        series?.watched ?? movie?.watched ?? false
    }

    var modifiedDate: Date {
        series?.modifiedDate ?? movie?.modifiedDate ?? .distantPast
    }

    var fileSize: Int64 {
        series?.fileSize ?? movie?.fileSize ?? 0
    }

    var movies: [Movie] {
        if let series {
            return series.sortedEpisodes.map(\.movie)
        }
        return movie.map { [$0] } ?? []
    }

    var isSeries: Bool {
        kind == .series
    }
}

enum LibraryItemBuilder {
    static func build(from movies: [Movie], seriesMetadata: [String: OnlineMovieMetadata] = [:]) -> [LibraryItem] {
        var groups: [String: (title: String, episodes: [SeriesEpisode])] = [:]
        var episodeMovieIDs = Set<String>()

        for movie in movies {
            guard let info = SeriesDetector.episodeInfo(for: movie) else { continue }
            let key = ManualMovieCorrections.normalized(info.seriesTitle)
            guard !key.isEmpty else { continue }

            episodeMovieIDs.insert(movie.id)
            let episode = SeriesEpisode(
                movie: movie,
                seasonNumber: info.seasonNumber,
                episodeNumber: info.episodeNumber,
                episodeTitle: info.episodeTitle
            )
            var group = groups[key] ?? (title: info.seriesTitle, episodes: [])
            group.episodes.append(episode)
            groups[key] = group
        }

        let movieItems = movies
            .filter { !episodeMovieIDs.contains($0.id) }
            .map { LibraryItem(id: $0.id, kind: .movie, movie: $0, series: nil) }

        let seriesItems = groups.map { key, group in
            let seriesID = "series:\(key)"
            return LibraryItem(
                id: seriesID,
                kind: .series,
                movie: nil,
                series: SeriesGroup(
                    id: seriesID,
                    title: group.title,
                    episodes: group.episodes,
                    onlineMetadata: seriesMetadata[seriesID]
                )
            )
        }

        return (movieItems + seriesItems).sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }
    }
}

struct OnlineMovieMetadata: Codable, Equatable, Hashable {
    var title: String?
    var originalTitle: String?
    var overview: String?
    var genres: [String]?
    var cast: [String]?
    var directors: [String]?
    var releaseYear: Int?
    var source: String?
    var sourceURL: String?
    var artworkPath: String?
    var fetchedAt: Date?

    var hasContent: Bool {
        title?.nilIfBlank != nil ||
        overview?.nilIfBlank != nil ||
        !(genres ?? []).isEmpty ||
        !(cast ?? []).isEmpty ||
        !(directors ?? []).isEmpty ||
        releaseYear != nil ||
        artworkPath != nil
    }
}

struct MediaTrackInfo: Codable, Equatable, Hashable {
    var languageCode: String?
    var title: String?
    var codec: String?
    var channels: Int?
}

struct VideoTechnicalInfo: Codable, Equatable, Hashable {
    var durationSeconds: Double?
    var width: Int?
    var height: Int?
    var frameRate: Double?
    var videoCodec: String?
    var audioTracks: [MediaTrackInfo]
    var subtitleTracks: [MediaTrackInfo]
    var externalSubtitleTracks: [MediaTrackInfo]? = nil
    var scannedAt: Date?

    var durationText: String {
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0 else {
            return "Non rilevata"
        }
        let total = Int(durationSeconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(String(format: "%02d", minutes))m"
        }
        return "\(minutes)m"
    }

    var resolutionText: String {
        if let width, let height, width > 0, height > 0 {
            return "\(width)x\(height)"
        }
        return "Non rilevata"
    }

    var primaryAudioText: String {
        languageNames(for: audioTracks).first ?? "Non rilevata"
    }

    var extraAudioText: String {
        let names = Array(languageNames(for: audioTracks).dropFirst())
        return names.isEmpty ? "Nessuna" : names.joined(separator: ", ")
    }

    var subtitleText: String {
        let names = languageNames(for: allSubtitleTracks)
        return names.isEmpty ? "Nessuno" : names.joined(separator: ", ")
    }

    var audioDetailText: String {
        trackDetailText(for: audioTracks, fallback: "Nessuna traccia audio")
    }

    var subtitleDetailText: String {
        trackDetailText(for: allSubtitleTracks, fallback: "Nessun sottotitolo")
    }

    var frameRateText: String {
        guard let frameRate, frameRate.isFinite, frameRate > 0 else {
            return "Non rilevati"
        }
        return "\(String(format: "%.2f", frameRate)) fps"
    }

    var videoCodecText: String {
        videoCodec?.uppercased() ?? "Non rilevato"
    }

    var resolutionClass: String {
        guard let width, let height else { return "Sconosciuta" }
        if width >= 3840 || height >= 2160 { return "4K" }
        if width >= 1900 || height >= 1000 { return "1080p" }
        if width >= 1200 || height >= 700 { return "720p" }
        return "\(width)x\(height)"
    }

    func hasAudioLanguage(_ codes: Set<String>) -> Bool {
        audioTracks.contains { track in
            guard let code = track.languageCode?.lowercased() else { return false }
            return codes.contains(code)
        }
    }

    func hasSubtitleLanguage(_ codes: Set<String>) -> Bool {
        allSubtitleTracks.contains { track in
            guard let code = track.languageCode?.lowercased() else { return false }
            return codes.contains(code)
        }
    }

    private var allSubtitleTracks: [MediaTrackInfo] {
        subtitleTracks + (externalSubtitleTracks ?? [])
    }

    private func trackDetailText(for tracks: [MediaTrackInfo], fallback: String) -> String {
        guard !tracks.isEmpty else { return fallback }
        return tracks.enumerated().map { index, track in
            var parts: [String] = [Self.languageName(for: track.languageCode) ?? track.title?.nilIfBlank ?? "Sconosciuta"]
            if let codec = track.codec?.nilIfBlank {
                parts.append(codec.uppercased())
            }
            if let channels = track.channels, channels > 0 {
                parts.append(channels == 1 ? "mono" : "\(channels) ch")
            }
            return "\(index + 1). " + parts.joined(separator: " - ")
        }.joined(separator: "\n")
    }

    private func languageNames(for tracks: [MediaTrackInfo]) -> [String] {
        let values = tracks.map { track -> String in
            if let language = Self.languageName(for: track.languageCode) {
                return language
            }
            if let title = track.title?.nilIfBlank {
                return title
            }
            return "Sconosciuta"
        }
        return Movie.unique(values)
    }

    private static func languageName(for code: String?) -> String? {
        guard let raw = code?.nilIfBlank else { return nil }
        let key = raw.lowercased()
        let normalized: String
        switch key {
        case "ita", "it":
            normalized = "it"
        case "eng", "en":
            normalized = "en"
        case "fre", "fra", "fr":
            normalized = "fr"
        case "ger", "deu", "de":
            normalized = "de"
        case "spa", "es":
            normalized = "es"
        case "por", "pt":
            normalized = "pt"
        case "und", "unknown":
            return nil
        default:
            normalized = key
        }
        return Locale(identifier: "it_IT")
            .localizedString(forLanguageCode: normalized)?
            .capitalized
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum LibrarySortMode: String, CaseIterable, Identifiable {
    case title = "Titolo"
    case newest = "Anno: recenti"
    case oldest = "Anno: vecchi"
    case director = "Regista"
    case recentlyModified = "Modificati"
    case largest = "Dimensione"

    var id: String { rawValue }
}

enum LibraryFilter: Hashable {
    case all
    case favorites
    case unwatched
    case withoutGenre
    case qualityReview
    case weakMetadata
    case missingPoster
    case noSubtitles
    case italianAudio
    case multiAudio
    case fullHD
    case fourK
    case shortMovies
    case recentImports
    case genre(String)
    case director(String)
    case actor(String)

    var title: String {
        switch self {
        case .all: return "Tutti i film"
        case .favorites: return "Preferiti"
        case .unwatched: return "Da vedere"
        case .withoutGenre: return "Senza genere"
        case .qualityReview: return "Da controllare"
        case .weakMetadata: return "Metadati deboli"
        case .missingPoster: return "Senza locandina"
        case .noSubtitles: return "Senza sottotitoli"
        case .italianAudio: return "Audio italiano"
        case .multiAudio: return "Multi-audio"
        case .fullHD: return "1080p"
        case .fourK: return "4K"
        case .shortMovies: return "Sotto 90 min"
        case .recentImports: return "Nuovi arrivi"
        case .genre(let value): return value
        case .director(let value): return value
        case .actor(let value): return value
        }
    }
}

enum MovieIssueSeverity: Int, Hashable {
    case info = 0
    case warning = 1
    case critical = 2
}

struct MovieQualityIssue: Hashable {
    let title: String
    let detail: String
    let severity: MovieIssueSeverity
}

enum MovieMetadataQuality: String, Hashable {
    case high = "Alta"
    case medium = "Media"
    case review = "Da controllare"
}
