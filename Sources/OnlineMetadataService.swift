import CryptoKit
import AppKit
import Foundation

enum OnlineMetadataError: LocalizedError {
    case noResult

    var errorDescription: String? {
        switch self {
        case .noResult:
            return "Nessun metadato online trovato"
        }
    }
}

enum OnlineMetadataService {
    static func fetch(for movie: Movie, artworkDirectory: URL, tmdbToken: String? = nil) async throws -> OnlineMovieMetadata {
        let token = tmdbToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        async let tmdb = fetchTMDbMetadataIfPossible(for: movie, artworkDirectory: artworkDirectory, token: token)
        async let publicTMDb = fetchPublicTMDbMetadataIfPossible(for: movie, artworkDirectory: artworkDirectory)
        async let wikipedia = fetchWikipediaMetadataIfPossible(for: movie, artworkDirectory: artworkDirectory)
        async let wikidata = fetchWikidataMetadataIfPossible(for: movie, artworkDirectory: artworkDirectory)
        async let apple = fetchAppleMetadataIfPossible(for: movie, artworkDirectory: artworkDirectory)
        async let webPoster = fetchWebPosterMetadataIfPossible(for: movie, artworkDirectory: artworkDirectory)

        let merged = mergeAll([
            accepted(await tmdb, for: movie),
            accepted(await publicTMDb, for: movie),
            accepted(await wikipedia, for: movie),
            accepted(await wikidata, for: movie),
            accepted(await apple, for: movie),
            accepted(await webPoster, for: movie)
        ]).map { completedWithLocalCorrections($0, for: movie) }

        guard let merged, merged.hasContent else {
            throw OnlineMetadataError.noResult
        }
        return merged
    }

    private static func fetchTMDbMetadataIfPossible(for movie: Movie, artworkDirectory: URL, token: String) async -> OnlineMovieMetadata? {
        guard !token.isEmpty else { return nil }
        return try? await fetchTMDbMetadata(for: movie, artworkDirectory: artworkDirectory, token: token)
    }

    private static func fetchPublicTMDbMetadataIfPossible(for movie: Movie, artworkDirectory: URL) async -> OnlineMovieMetadata? {
        try? await fetchPublicTMDbMetadata(for: movie, artworkDirectory: artworkDirectory)
    }

    private static func fetchWikipediaMetadataIfPossible(for movie: Movie, artworkDirectory: URL) async -> OnlineMovieMetadata? {
        try? await fetchWikipediaMetadata(for: movie, artworkDirectory: artworkDirectory)
    }

    private static func fetchWikidataMetadataIfPossible(for movie: Movie, artworkDirectory: URL) async -> OnlineMovieMetadata? {
        try? await fetchWikidataMetadata(for: movie, artworkDirectory: artworkDirectory)
    }

    private static func fetchAppleMetadataIfPossible(for movie: Movie, artworkDirectory: URL) async -> OnlineMovieMetadata? {
        try? await fetchAppleMetadata(for: movie, artworkDirectory: artworkDirectory)
    }

    private static func fetchWebPosterMetadataIfPossible(for movie: Movie, artworkDirectory: URL) async -> OnlineMovieMetadata? {
        try? await fetchWebPosterMetadata(for: movie, artworkDirectory: artworkDirectory)
    }

    private static func accepted(_ metadata: OnlineMovieMetadata?, for movie: Movie) -> OnlineMovieMetadata? {
        guard let metadata, isCompatible(metadata, with: movie) else {
            return nil
        }
        return metadata
    }

    private static func mergeAll(_ candidates: [OnlineMovieMetadata?]) -> OnlineMovieMetadata? {
        var merged: OnlineMovieMetadata?
        for candidate in candidates.compactMap({ $0 }) {
            if let current = merged {
                merged = merge(primary: current, secondary: candidate)
            } else {
                merged = candidate
            }
        }
        merged?.fetchedAt = Date()
        return merged
    }

    private static func merge(primary: OnlineMovieMetadata?, secondary: OnlineMovieMetadata?) -> OnlineMovieMetadata? {
        guard primary != nil || secondary != nil else { return nil }

        var result = primary ?? OnlineMovieMetadata()
        if let secondary {
            result.title = result.title?.nilIfBlank ?? secondary.title
            result.originalTitle = result.originalTitle?.nilIfBlank ?? secondary.originalTitle
            result.overview = chooseBetterOverview(primary: result.overview, secondary: secondary.overview)
            result.releaseYear = result.releaseYear ?? secondary.releaseYear
            result.artworkPath = chooseBetterArtworkPath(primary: result.artworkPath, secondary: secondary.artworkPath)
            result.source = [result.source, secondary.source].compactMap { $0?.nilIfBlank }.joined(separator: " + ").nilIfBlank
            result.sourceURL = result.sourceURL?.nilIfBlank ?? secondary.sourceURL
            result.genres = Movie.unique((result.genres ?? []) + (secondary.genres ?? []))
            result.cast = Movie.unique((result.cast ?? []) + (secondary.cast ?? []))
            result.directors = Movie.unique((result.directors ?? []) + (secondary.directors ?? []))
        }
        result.fetchedAt = Date()
        return result
    }

    static func completedWithLocalCorrections(_ metadata: OnlineMovieMetadata, for movie: Movie) -> OnlineMovieMetadata {
        let completions = Movie.unique([movie.title, movie.displayTitle, metadata.title, metadata.originalTitle].compactMap { $0 })
            .compactMap { ManualMovieCorrections.completion(for: movie.fileURL, title: $0) }
        guard let correction = completions.first else {
            return metadata
        }

        var result = metadata
        if result.title?.nilIfBlank == nil {
            result.title = correction.title
        }
        result.releaseYear = result.releaseYear ?? correction.year

        let correctedDirector = knownDirector(correction.director).map { [$0] } ?? []
        if (result.directors ?? []).isEmpty {
            result.directors = correctedDirector
        } else {
            result.directors = Movie.unique((result.directors ?? []) + correctedDirector)
        }

        if (result.cast ?? []).isEmpty {
            result.cast = correction.actors
        } else {
            result.cast = Movie.unique((result.cast ?? []) + correction.actors)
        }

        if (result.genres ?? []).isEmpty {
            result.genres = correction.inferredGenres
        } else {
            result.genres = Movie.unique((result.genres ?? []) + correction.inferredGenres)
        }

        return result
    }

    static func hasWeakOverview(_ value: String?) -> Bool {
        guard let text = value?.nilIfBlank else { return true }
        let lower = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        if text.count < 120 { return true }
        if lower.contains("[ modifica | modifica wikitesto ]") { return true }
        if lower.hasPrefix("film del ") || lower.hasPrefix("film documentario del ") { return true }
        if lower.hasSuffix("'") || lower.hasSuffix("’") { return true }

        let danglingEndings = [
            " d", " l", " un", " una", " uno", " il", " lo", " la",
            " di", " da", " del", " dei", " dell", " della", " degli",
            " all", " alla", " dall", " dalla", " nell", " nella", " sull", " sulla",
            " con", " per", " tra", " fra"
        ]
        return danglingEndings.contains { lower.hasSuffix($0) }
    }

    private static func overviewScore(_ value: String?) -> Int {
        guard let text = value?.nilIfBlank else { return 0 }
        var score = min(text.count, 1200)
        if hasWeakOverview(text) { score -= 500 }
        if text.contains("[ modifica | modifica wikitesto ]") { score -= 300 }
        if text.contains("...") { score += 20 }
        return score
    }

    private static func chooseBetterArtworkPath(primary: String?, secondary: String?) -> String? {
        let primaryPath = primary?.nilIfBlank
        let secondaryPath = secondary?.nilIfBlank
        guard primaryPath != nil || secondaryPath != nil else { return nil }
        if primaryPath == nil { return secondaryPath }
        if secondaryPath == nil { return primaryPath }

        let primaryScore = artworkScore(path: primaryPath)
        let secondaryScore = artworkScore(path: secondaryPath)
        return secondaryScore > primaryScore ? secondaryPath : primaryPath
    }

    private static func artworkScore(path: String?) -> Double {
        guard let path,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let score = posterScore(forImageData: data) else {
            return 0
        }
        return score
    }

    static func isCompatible(_ metadata: OnlineMovieMetadata, with movie: Movie) -> Bool {
        let movieTitle = normalizedTitle(movie.title)
        let metadataTitles = [metadata.title, metadata.originalTitle]
            .compactMap { $0?.nilIfBlank }
            .map(normalizedTitle)
            .filter { !$0.isEmpty }
        let hasCompatibleTitle = !metadataTitles.isEmpty &&
            metadataTitles.contains(where: { titlesCompatible(movieTitle, $0) })

        if !metadataTitles.isEmpty && !hasCompatibleTitle {
            return false
        }

        let movieMarkers = titleMarkers(movie.title)
        if !movieMarkers.isEmpty {
            let metadataMarkerSet = Set(metadataTitles.flatMap(titleMarkers))
            // Rifiuta solo se i metadati riportano ESPLICITAMENTE un altro capitolo/parte
            // (es. "Parte 2" quando il file locale è "Parte 1"). Se i metadati non
            // contengono alcun marker riconosciuto (perché la fonte ha restituito il
            // titolo in inglese, es. "Part 1" invece di "Parte 1"), non scartiamo il
            // risultato solo per questo: altrimenti film come "Harry Potter e i Doni
            // della Morte - Parte 1/2" restano sempre senza copertina.
            if !metadataMarkerSet.isEmpty && movieMarkers.isDisjoint(with: metadataMarkerSet) {
                return false
            }
        }

        if !hasCompatibleTitle,
           let movieYear = movie.year,
           let metadataYear = metadata.releaseYear,
           abs(movieYear - metadataYear) > 1 {
            return false
        }

        return true
    }

    static func hasHardIdentityMismatch(_ metadata: OnlineMovieMetadata, with movie: Movie) -> Bool {
        let movieTitle = normalizedTitle(movie.title)
        let metadataTitles = [metadata.title, metadata.originalTitle]
            .compactMap { $0?.nilIfBlank }
            .map(normalizedTitle)
            .filter { !$0.isEmpty }

        if !metadataTitles.isEmpty,
           !metadataTitles.contains(where: { titlesCompatible(movieTitle, $0) }) {
            return true
        }

        let movieMarkers = titleMarkers(movie.title)
        if !movieMarkers.isEmpty {
            let metadataMarkerSet = Set(metadataTitles.flatMap(titleMarkers))
            if !metadataMarkerSet.isEmpty && movieMarkers.isDisjoint(with: metadataMarkerSet) {
                return true
            }
        }

        return false
    }

    private static func titlesCompatible(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let lhsWords = significantWords(lhs)
        let rhsWords = significantWords(rhs)
        guard !lhsWords.isEmpty, !rhsWords.isEmpty else { return false }
        if lhsWords.isSubset(of: rhsWords) || rhsWords.isSubset(of: lhsWords) {
            return true
        }
        let overlap = lhsWords.intersection(rhsWords).count
        return Double(overlap) / Double(max(lhsWords.count, rhsWords.count)) >= 0.60
    }

    private static func significantWords(_ value: String) -> Set<String> {
        let ignored: Set<String> = ["il", "lo", "la", "i", "gli", "le", "un", "una", "uno", "e", "di", "del", "della", "dei", "degli", "the", "a", "an", "of"]
        return Set(value.split(separator: " ").map(String.init).filter { $0.count > 1 && !ignored.contains($0) })
    }

    private static func titleMarkers(_ value: String) -> Set<String> {
        let normalized = normalizedTitle(value)
        var markers = Set<String>()
        let checks: [(String, String)] = [
            ("atto ii", "atto-2"),
            ("atto 2", "atto-2"),
            ("atto secondo", "atto-2"),
            ("act ii", "atto-2"),
            ("act 2", "atto-2"),
            ("atto iii", "atto-3"),
            ("atto 3", "atto-3"),
            ("atto terzo", "atto-3"),
            ("act iii", "atto-3"),
            ("act 3", "atto-3"),
            ("parte 1", "parte-1"),
            ("parte i", "parte-1"),
            ("parte prima", "parte-1"),
            ("part 1", "parte-1"),
            ("part i", "parte-1"),
            ("parte 2", "parte-2"),
            ("parte ii", "parte-2"),
            ("parte seconda", "parte-2"),
            ("part 2", "parte-2"),
            ("part ii", "parte-2")
        ]
        for (needle, marker) in checks where normalized.contains(needle) {
            markers.insert(marker)
        }
        return markers
    }

    private static func fetchTMDbMetadata(for movie: Movie, artworkDirectory: URL, token: String) async throws -> OnlineMovieMetadata {
        let searchURL = tmdbURL(
            path: "/search/movie",
            token: token,
            queryItems: [
                URLQueryItem(name: "query", value: movie.title),
                URLQueryItem(name: "language", value: "it-IT"),
                URLQueryItem(name: "include_adult", value: "false"),
                URLQueryItem(name: "year", value: movie.year.map(String.init))
            ].compactMap { $0.value == nil ? nil : $0 }
        )

        let searchData = try await tmdbData(from: searchURL, token: token)
        let searchResponse = try JSONDecoder().decode(TMDbSearchResponse.self, from: searchData)
        guard let match = bestTMDbItem(searchResponse.results, for: movie) else {
            throw OnlineMetadataError.noResult
        }

        let detailURL = tmdbURL(
            path: "/movie/\(match.id)",
            token: token,
            queryItems: [
                URLQueryItem(name: "language", value: "it-IT"),
                URLQueryItem(name: "append_to_response", value: "credits,images"),
                URLQueryItem(name: "include_image_language", value: "it,en,null")
            ]
        )

        let detailData = try await tmdbData(from: detailURL, token: token)
        let details = try JSONDecoder().decode(TMDbMovieDetails.self, from: detailData)
        let directors = Movie.unique(details.credits?.crew?.filter { $0.job == "Director" }.compactMap(\.name) ?? [])
        let cast = Movie.unique((details.credits?.cast ?? []).sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }.compactMap(\.name))
        let genres = Movie.unique(details.genres?.compactMap(\.name) ?? [])
        let posterPath = preferredPosterPath(from: details) ?? match.posterPath

        var artworkPath: String?
        if let posterPath,
           let posterURL = URL(string: "https://image.tmdb.org/t/p/w780\(posterPath)"),
           let downloaded = try? await downloadBestPoster(from: [posterURL], for: movie, artworkDirectory: artworkDirectory, suffix: "tmdb-\(details.id)") {
            artworkPath = downloaded.path
        }

        return OnlineMovieMetadata(
            title: details.title?.nilIfBlank ?? match.title,
            originalTitle: details.originalTitle?.nilIfBlank ?? match.originalTitle,
            overview: details.overview?.nilIfBlank ?? match.overview,
            genres: genres,
            cast: Array(cast.prefix(18)),
            directors: directors,
            releaseYear: releaseYear(from: details.releaseDate) ?? match.releaseYear,
            source: "TMDb",
            sourceURL: "https://www.themoviedb.org/movie/\(details.id)",
            artworkPath: artworkPath,
            fetchedAt: Date()
        )
    }

    private static func bestTMDbItem(_ items: [TMDbSearchItem], for movie: Movie) -> TMDbSearchItem? {
        items.max { lhs, rhs in
            score(lhs, for: movie) < score(rhs, for: movie)
        }
    }

    private static func score(_ item: TMDbSearchItem, for movie: Movie) -> Int {
        let target = normalizedTitle(movie.title)
        let title = normalizedTitle(item.title ?? "")
        let originalTitle = normalizedTitle(item.originalTitle ?? "")
        var score = 0

        if title == target || originalTitle == target {
            score += 90
        } else {
            if title.contains(target) || target.contains(title) { score += 45 }
            if originalTitle.contains(target) || target.contains(originalTitle) { score += 35 }
        }

        if let itemYear = item.releaseYear, let movieYear = movie.year {
            let distance = abs(itemYear - movieYear)
            if distance == 0 {
                score += 35
            } else if distance <= 1 {
                score += 22
            } else if distance <= 3 {
                score += 8
            } else {
                score -= min(25, distance * 2)
            }
        }

        if item.posterPath != nil { score += 8 }
        if item.overview?.nilIfBlank != nil { score += 5 }
        score += min(12, Int(item.popularity ?? 0.0) / 5)
        score += min(10, (item.voteCount ?? 0) / 100)
        return score
    }

    private static func preferredPosterPath(from details: TMDbMovieDetails) -> String? {
        if let posterPath = details.posterPath?.nilIfBlank {
            return posterPath
        }

        return details.images?.posters?.max { lhs, rhs in
            posterScore(lhs) < posterScore(rhs)
        }?.filePath
    }

    private static func posterScore(_ poster: TMDbPoster) -> Double {
        var score = poster.voteAverage ?? 0
        score += min(Double(poster.voteCount ?? 0) / 10.0, 8.0)
        switch poster.languageCode {
        case "it":
            score += 8
        case "en":
            score += 3
        case nil:
            score += 1
        default:
            break
        }
        return score
    }

    private static func fetchPublicTMDbMetadata(for movie: Movie, artworkDirectory: URL) async throws -> OnlineMovieMetadata {
        let candidateIDs = try await tmdbPublicCandidateIDs(for: movie)
        var candidates: [OnlineMovieMetadata] = []

        for tmdbID in candidateIDs.prefix(6) {
            if let metadata = try? await fetchPublicTMDbMetadata(for: movie, tmdbID: tmdbID, artworkDirectory: artworkDirectory),
               isCompatible(metadata, with: movie) {
                candidates.append(metadata)
            }
        }

        guard let best = candidates.max(by: { publicTMDbScore($0, for: movie) < publicTMDbScore($1, for: movie) }) else {
            throw OnlineMetadataError.noResult
        }
        return best
    }

    private static func fetchPublicTMDbMetadata(for movie: Movie, tmdbID: String, artworkDirectory: URL) async throws -> OnlineMovieMetadata {
        guard let pageURL = URL(string: "https://www.themoviedb.org/movie/\(tmdbID)?language=it-IT") else {
            throw OnlineMetadataError.noResult
        }

        let htmlData = try await data(from: pageURL)
        guard let html = String(data: htmlData, encoding: .utf8) else {
            throw OnlineMetadataError.noResult
        }

        let title = htmlDecoded(firstMetaContent(named: "og:title", in: html))?.nilIfBlank
        let overview = htmlDecoded(firstMetaContent(named: "og:description", in: html))?.nilIfBlank
        let posterURLs = tmdbPublicImageURLs(in: html)
        let releaseYear = tmdbPublicReleaseYear(in: html)
        let directors = tmdbPublicDirectors(in: html)
        let cast = tmdbPublicCast(in: html)
        let genres = tmdbPublicGenres(in: html)
        let originalTitle = tmdbPublicOriginalTitle(in: html)

        var artworkPath: String?
        if let downloaded = try? await downloadBestPoster(from: posterURLs, for: movie, artworkDirectory: artworkDirectory, suffix: "tmdb-public-\(tmdbID)") {
            artworkPath = downloaded.path
        }

        guard title != nil || overview != nil || artworkPath != nil else {
            throw OnlineMetadataError.noResult
        }

        return OnlineMovieMetadata(
            title: title,
            originalTitle: originalTitle,
            overview: overview,
            genres: genres,
            cast: cast,
            directors: directors,
            releaseYear: releaseYear,
            source: "TMDb pubblico",
            sourceURL: "https://www.themoviedb.org/movie/\(tmdbID)",
            artworkPath: artworkPath,
            fetchedAt: Date()
        )
    }

    private static func tmdbPublicCandidateIDs(for movie: Movie) async throws -> [String] {
        var ids: [String] = []
        if let wikidataID = try? await wikidataTMDbID(for: movie) {
            ids.append(wikidataID)
        }

        ids.append(contentsOf: (try? await tmdbPublicSearchIDs(for: movie)) ?? [])

        var seen = Set<String>()
        return ids.filter { id in
            guard !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
    }

    private static func tmdbPublicSearchIDs(for movie: Movie) async throws -> [String] {
        let yearText = movie.year.map(String.init) ?? ""
        let titles = searchTitleCandidates(for: movie)
        let queries = Movie.unique(titles.flatMap { title in
            [
                title,
                "\(title) \(yearText)",
                "\(title) film"
            ]
        }).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var ids: [String] = []
        for query in queries.prefix(5) {
            var components = URLComponents(string: "https://www.themoviedb.org/search/movie")!
            components.queryItems = [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "language", value: "it-IT")
            ]

            let htmlData = try await data(from: components.url!)
            guard let html = String(data: htmlData, encoding: .utf8) else {
                continue
            }
            ids.append(contentsOf: tmdbPublicMovieIDs(inSearchHTML: html))
            if !ids.isEmpty { break }
        }

        var seen = Set<String>()
        return ids.filter { id in
            guard !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
    }

    private static func tmdbPublicMovieIDs(inSearchHTML html: String) -> [String] {
        Movie.unique(captures(
            in: html,
            pattern: #"/movie/(\d+)(?:-[^"'<>?]*)?(?:\?[^"'<>]*)?"#,
            options: [.caseInsensitive]
        ).compactMap(\.first))
    }

    private static func publicTMDbScore(_ metadata: OnlineMovieMetadata, for movie: Movie) -> Int {
        var score = 0
        if let title = metadata.title, titlesCompatible(normalizedTitle(movie.title), normalizedTitle(title)) {
            score += 50
        }
        if let year = movie.year, let releaseYear = metadata.releaseYear {
            let distance = abs(year - releaseYear)
            score += distance == 0 ? 40 : max(0, 20 - distance * 5)
        }
        if metadata.artworkPath != nil { score += 20 }
        if metadata.overview?.nilIfBlank != nil { score += 5 }
        return score
    }

    private static func fetchWebPosterMetadata(for movie: Movie, artworkDirectory: URL) async throws -> OnlineMovieMetadata {
        let candidates = try await webPosterCandidateURLs(for: movie)
        for pageURL in candidates.prefix(16) {
            if let metadata = try? await fetchWebPosterMetadata(for: movie, pageURL: pageURL, artworkDirectory: artworkDirectory) {
                return metadata
            }
        }
        throw OnlineMetadataError.noResult
    }

    private static func fetchWebPosterMetadata(for movie: Movie, pageURL: URL, artworkDirectory: URL) async throws -> OnlineMovieMetadata {
        let htmlData = try await data(from: pageURL)
        guard let html = String(data: htmlData, encoding: .utf8) else {
            throw OnlineMetadataError.noResult
        }

        let pageTitle = webPageTitle(in: html)
        let description = htmlDecoded(firstMetaContent(named: "og:description", in: html))?.nilIfBlank
        let releaseYear = webReleaseYear(in: [pageTitle, description, pageURL.absoluteString].compactMap { $0 }.joined(separator: " "))
        guard webPosterPageMatches(movie: movie, title: pageTitle, releaseYear: releaseYear, html: html, url: pageURL) else {
            throw OnlineMetadataError.noResult
        }

        let posterURLs = webPosterImageURLs(in: html, baseURL: pageURL)
        guard let downloaded = try? await downloadBestPoster(
            from: posterURLs,
            for: movie,
            artworkDirectory: artworkDirectory,
            suffix: "web-\(pageURL.absoluteString)"
        ) else {
            throw OnlineMetadataError.noResult
        }

        return OnlineMovieMetadata(
            title: pageTitle?.nilIfBlank ?? movie.title,
            originalTitle: nil,
            overview: nil,
            genres: nil,
            cast: nil,
            directors: nil,
            releaseYear: releaseYear,
            source: "Poster web verificato",
            sourceURL: pageURL.absoluteString,
            artworkPath: downloaded.path,
            fetchedAt: Date()
        )
    }

    private static func webPosterCandidateURLs(for movie: Movie) async throws -> [URL] {
        let titles = searchTitleCandidates(for: movie)
        let year = movie.year.map(String.init) ?? ""
        let director = knownDirector(movie.director)
        let queries = Movie.unique(titles.prefix(3).flatMap { title in
            [
                "\(title) \(year) locandina film",
                "\(title) \(year) poster film",
                [title, director, "locandina"].compactMap { $0 }.joined(separator: " "),
                [title, director, "poster"].compactMap { $0 }.joined(separator: " "),
                "site:letterboxd.com/film \(title) \(year)",
                "site:filmtv.it/film \(title) \(year)",
                "site:davinotti.com/film \(title) \(year)",
                "site:mymovies.it \(title) \(year) locandina",
                "site:movieplayer.it \(title) \(year) poster",
                "site:cinematografo.it \(title) \(year) locandina"
            ]
        }).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var urls: [URL] = []
        for query in queries.prefix(10) {
            urls.append(contentsOf: (try? await duckDuckGoResultURLs(for: query)) ?? [])
            if urls.count >= 16 { break }
        }

        var seen = Set<String>()
        return urls.filter { url in
            guard trustedWebPosterURL(url), !seen.contains(url.absoluteString) else {
                return false
            }
            seen.insert(url.absoluteString)
            return true
        }
    }

    private static func duckDuckGoResultURLs(for query: String) async throws -> [URL] {
        var components = URLComponents(string: "https://duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        let htmlData = try await data(from: components.url!)
        guard let html = String(data: htmlData, encoding: .utf8) else { return [] }

        let hrefs = captures(
            in: html,
            pattern: #"<a[^>]+class=["'][^"']*\bresult__a\b[^"']*["'][^>]+href=["']([^"']+)["']"#,
            options: [.caseInsensitive]
        ).compactMap(\.first)

        return hrefs.compactMap { href in
            webSearchResultURL(from: href)
        }
    }

    private static func webSearchResultURL(from href: String) -> URL? {
        let decoded = htmlDecoded(href) ?? href
        if let url = URL(string: decoded), url.host?.contains("duckduckgo.com") == true {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let target = components?.queryItems?.first(where: { $0.name == "uddg" })?.value {
                return URL(string: target)
            }
        }
        if decoded.hasPrefix("//") {
            return URL(string: "https:" + decoded)
        }
        return URL(string: decoded)
    }

    private static func trustedWebPosterURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let trustedHosts = [
            "letterboxd.com", "www.letterboxd.com",
            "filmtv.it", "www.filmtv.it",
            "davinotti.com", "www.davinotti.com",
            "mymovies.it", "www.mymovies.it",
            "movieplayer.it", "www.movieplayer.it",
            "cinematografo.it", "www.cinematografo.it",
            "comingsoon.it", "www.comingsoon.it",
            "filmitalia.org", "www.filmitalia.org",
            "themoviedb.org", "www.themoviedb.org"
        ]
        return trustedHosts.contains(host)
    }

    private static func webPosterPageMatches(movie: Movie, title: String?, releaseYear: Int?, html: String, url: URL) -> Bool {
        let movieTitle = normalizedTitle(movie.title)
        let pageTitle = normalizedTitle(title ?? url.deletingPathExtension().lastPathComponent)
        guard titlesCompatible(movieTitle, pageTitle) || pageTitle.contains(movieTitle) || movieTitle.contains(pageTitle) else {
            return false
        }

        if let movieYear = movie.year, let releaseYear {
            return abs(movieYear - releaseYear) <= 1
        }

        if movie.year != nil, releaseYear == nil {
            guard let director = knownDirector(movie.director) else { return false }
            let pageText = normalizedTitle(String(html.prefix(80_000)))
            return pageText.contains(normalizedTitle(director))
        }

        return true
    }

    private static func webPosterImageURLs(in html: String, baseURL: URL) -> [URL] {
        var values = allMetaContents(named: "og:image", in: html)
        values.append(contentsOf: allMetaContents(named: "twitter:image", in: html))
        values.append(contentsOf: captures(
            in: html,
            pattern: #""image"\s*:\s*"?([^",}\]]+)""#,
            options: [.caseInsensitive]
        ).compactMap(\.first))
        values.append(contentsOf: captures(
            in: html,
            pattern: #"(https?://[^"' <>)\\]+\.(?:jpg|jpeg|png|webp)(?:\?[^"' <>)\\]+)?)"#,
            options: [.caseInsensitive]
        ).compactMap(\.first))

        let urls = values.compactMap(htmlDecoded).compactMap { value in
            resolvedURL(value, baseURL: baseURL)
        }.filter { url in
            let lower = url.absoluteString.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return !lower.contains("avatar") &&
                !lower.contains("no_portrait") &&
                !lower.contains("no-image") &&
                !lower.contains("empty-poster") &&
                !lower.contains("logo") &&
                !lower.contains("touch-icon")
        }

        return uniqueURLs(urls)
    }

    private static func resolvedURL(_ value: String, baseURL: URL) -> URL? {
        if value.hasPrefix("//") {
            return URL(string: "https:" + value)
        }
        if let url = URL(string: value), url.scheme != nil {
            return url
        }
        return URL(string: value, relativeTo: baseURL)?.absoluteURL
    }

    private static func webPageTitle(in html: String) -> String? {
        if let title = htmlDecoded(firstMetaContent(named: "og:title", in: html))?.nilIfBlank {
            return title
        }
        return firstCapture(
            in: html,
            pattern: #"<title[^>]*>([\s\S]*?)</title>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ).flatMap(htmlDecoded)?.nilIfBlank
    }

    private static func webReleaseYear(in value: String) -> Int? {
        captures(
            in: value,
            pattern: #"\b((?:19|20)\d{2})\b"#,
            options: [.caseInsensitive]
        ).compactMap { $0.first.flatMap(Int.init) }.first
    }

    private static func knownDirector(_ value: String) -> String? {
        let normalized = ManualMovieCorrections.normalized(value)
        guard !normalized.isEmpty,
              normalized != ManualMovieCorrections.normalized("Sconosciuto"),
              normalized != ManualMovieCorrections.normalized("Unknown") else {
            return nil
        }
        return value
    }

    private static func wikidataTMDbID(for movie: Movie) async throws -> String? {
        let query = """
        SELECT ?item ?itemLabel ?publicationDate ?tmdbID WHERE {
          SERVICE wikibase:mwapi {
            bd:serviceParam wikibase:endpoint "www.wikidata.org";
                            wikibase:api "EntitySearch";
                            mwapi:search "\(sparqlEscaped(movie.title))";
                            mwapi:language "it".
            ?item wikibase:apiOutputItem mwapi:item.
          }
          ?item wdt:P31/wdt:P279* wd:Q11424.
          OPTIONAL { ?item wdt:P577 ?publicationDate. }
          OPTIONAL { ?item wdt:P4947 ?tmdbID. }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "it,en". }
        }
        LIMIT 25
        """

        var components = URLComponents(string: "https://query.wikidata.org/sparql")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "format", value: "json")
        ]

        let responseData = try await data(from: components.url!)
        let response = try JSONDecoder().decode(SPARQLResponse.self, from: responseData)
        return bestWikidataRow(response.results.bindings, for: movie)?.tmdbID?.value.nilIfBlank
    }

    private static func bestWikidataRow(_ rows: [SPARQLBinding], for movie: Movie) -> SPARQLBinding? {
        rows.max { lhs, rhs in
            wikidataScore(lhs, for: movie) < wikidataScore(rhs, for: movie)
        }
    }

    private static func wikidataScore(_ row: SPARQLBinding, for movie: Movie) -> Int {
        let target = normalizedTitle(movie.title)
        let title = normalizedTitle(row.itemLabel?.value ?? "")
        var score = 0

        if title == target {
            score += 80
        } else if title.contains(target) || target.contains(title) {
            score += 35
        }

        if let rowYear = releaseYear(from: row.publicationDate?.value), let movieYear = movie.year {
            let distance = abs(rowYear - movieYear)
            if distance == 0 {
                score += 35
            } else if distance <= 1 {
                score += 18
            } else {
                score -= min(25, distance * 2)
            }
        }

        if row.tmdbID?.value.nilIfBlank != nil { score += 20 }
        return score
    }

    private static func fetchWikipediaMetadata(for movie: Movie, artworkDirectory: URL) async throws -> OnlineMovieMetadata {
        let pages = try await wikipediaSearchPages(for: movie)
        guard let page = bestWikipediaPage(pages, for: movie) else {
            throw OnlineMetadataError.noResult
        }

        let summary = try await wikipediaSummary(title: page.title)
        var artworkPath: String?
        if let imageURL = summary.bestPosterLikeImageURL,
           let downloaded = try? await downloadBestPoster(from: [imageURL], for: movie, artworkDirectory: artworkDirectory, suffix: "wikipedia-\(page.pageid)") {
            artworkPath = downloaded.path
        }

        let plot = try? await wikipediaPlot(title: page.title)
        let overview = chooseBetterOverview(primary: plot, secondary: summary.extract)
        guard overview != nil || artworkPath != nil else {
            throw OnlineMetadataError.noResult
        }

        return OnlineMovieMetadata(
            title: summary.title?.nilIfBlank ?? page.title,
            originalTitle: nil,
            overview: overview,
            genres: nil,
            cast: nil,
            directors: nil,
            releaseYear: nil,
            source: "Wikipedia",
            sourceURL: summary.pageURL ?? "https://it.wikipedia.org/wiki/\(wikiPathEscaped(page.title))",
            artworkPath: artworkPath,
            fetchedAt: Date()
        )
    }

    private static func wikipediaSearchPages(for movie: Movie) async throws -> [WikipediaSearchItem] {
        let yearText = movie.year.map(String.init) ?? ""
        let searches = Movie.unique(searchTitleCandidates(for: movie).flatMap { title in
            [
                "\(title) \(yearText) film",
                "\(title) film",
                title
            ]
        })

        var results: [WikipediaSearchItem] = []
        for search in searches {
            var components = URLComponents(string: "https://it.wikipedia.org/w/api.php")!
            components.queryItems = [
                URLQueryItem(name: "action", value: "query"),
                URLQueryItem(name: "list", value: "search"),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "srlimit", value: "8"),
                URLQueryItem(name: "srsearch", value: search)
            ]
            let responseData = try await data(from: components.url!)
            let response = try JSONDecoder().decode(WikipediaSearchResponse.self, from: responseData)
            results.append(contentsOf: response.query.search)
            if !results.isEmpty { break }
        }
        return results
    }

    private static func bestWikipediaPage(_ pages: [WikipediaSearchItem], for movie: Movie) -> WikipediaSearchItem? {
        pages.max { lhs, rhs in
            wikipediaScore(lhs, for: movie) < wikipediaScore(rhs, for: movie)
        }
    }

    private static func wikipediaScore(_ page: WikipediaSearchItem, for movie: Movie) -> Int {
        let target = normalizedTitle(movie.title)
        let title = normalizedTitle(page.title)
        let snippet = normalizedTitle(page.snippet ?? "")
        var score = 0

        if title == target { score += 75 }
        if title.contains(target) || target.contains(title) { score += 35 }
        if title.contains("film") { score += 18 }
        if snippet.contains("film") { score += 12 }
        if snippet.contains("diretto") || snippet.contains("regia") { score += 10 }
        if let year = movie.year {
            let yearText = String(year)
            if page.title.contains(yearText) { score += 25 }
            if page.snippet?.contains(yearText) == true { score += 20 }
        }
        return score
    }

    private static func wikipediaSummary(title: String) async throws -> WikipediaSummary {
        guard let url = URL(string: "https://it.wikipedia.org/api/rest_v1/page/summary/\(wikiPathEscaped(title))") else {
            throw OnlineMetadataError.noResult
        }
        let responseData = try await data(from: url)
        return try JSONDecoder().decode(WikipediaSummary.self, from: responseData)
    }

    private static func wikipediaPlot(title: String) async throws -> String? {
        guard let section = try await wikipediaSectionIndex(title: title, matching: ["trama", "sinossi", "storia"]) else {
            return nil
        }

        var components = URLComponents(string: "https://it.wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "parse"),
            URLQueryItem(name: "page", value: title),
            URLQueryItem(name: "prop", value: "text"),
            URLQueryItem(name: "section", value: section),
            URLQueryItem(name: "format", value: "json")
        ]

        let responseData = try await data(from: components.url!)
        let response = try JSONDecoder().decode(WikipediaTextResponse.self, from: responseData)
        let text = plainText(fromHTML: response.parse.text.html)
        return compactOverview(text)
    }

    private static func wikipediaSectionIndex(title: String, matching names: [String]) async throws -> String? {
        var components = URLComponents(string: "https://it.wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "parse"),
            URLQueryItem(name: "page", value: title),
            URLQueryItem(name: "prop", value: "tocdata"),
            URLQueryItem(name: "format", value: "json")
        ]

        let responseData = try await data(from: components.url!)
        let response = try JSONDecoder().decode(WikipediaTOCResponse.self, from: responseData)
        let normalizedNames = names.map(normalizedTitle)
        return response.parse.tocdata.sections.first { section in
            let line = normalizedTitle(section.line)
            return normalizedNames.contains { line == $0 || line.contains($0) }
        }?.index
    }

    private static func chooseBetterOverview(primary: String?, secondary: String?) -> String? {
        let primaryText = primary?.nilIfBlank
        let secondaryText = secondary?.nilIfBlank
        guard primaryText != nil || secondaryText != nil else { return nil }
        if primaryText == nil { return secondaryText }
        if secondaryText == nil { return primaryText }
        return overviewScore(secondaryText) > overviewScore(primaryText) ? secondaryText : primaryText
    }

    private static func fetchAppleMetadata(for movie: Movie, artworkDirectory: URL) async throws -> OnlineMovieMetadata {
        let terms = searchTitleCandidates(for: movie)
        var item: AppleMovieItem?

        for term in terms.prefix(4) {
            var components = URLComponents(string: "https://itunes.apple.com/search")!
            components.queryItems = [
                URLQueryItem(name: "term", value: term),
                URLQueryItem(name: "media", value: "movie"),
                URLQueryItem(name: "entity", value: "movie"),
                URLQueryItem(name: "country", value: "IT"),
                URLQueryItem(name: "lang", value: "it_it"),
                URLQueryItem(name: "limit", value: "8")
            ]

            let data = try await data(from: components.url!)
            let response = try JSONDecoder().decode(AppleSearchResponse.self, from: data)
            if let match = bestAppleItem(response.results, for: movie) {
                item = match
                break
            }
        }

        guard let item else { throw OnlineMetadataError.noResult }

        var artworkPath: String?
        if let artwork = item.largeArtworkURL,
           let downloaded = try? await downloadBestPoster(from: [artwork], for: movie, artworkDirectory: artworkDirectory, suffix: "apple") {
            artworkPath = downloaded.path
        }

        return OnlineMovieMetadata(
            title: item.trackName,
            originalTitle: nil,
            overview: item.longDescription ?? item.shortDescription,
            genres: item.primaryGenreName.map { [$0] },
            cast: nil,
            directors: item.artistName.map { [$0] },
            releaseYear: item.releaseYear,
            source: "Apple",
            sourceURL: item.trackViewUrl,
            artworkPath: artworkPath,
            fetchedAt: Date()
        )
    }

    private static func bestAppleItem(_ items: [AppleMovieItem], for movie: Movie) -> AppleMovieItem? {
        items.max { lhs, rhs in
            score(lhs, for: movie) < score(rhs, for: movie)
        }
    }

    private static func score(_ item: AppleMovieItem, for movie: Movie) -> Int {
        var score = 0
        if item.trackName.localizedCaseInsensitiveContains(movie.title) ||
            movie.title.localizedCaseInsensitiveContains(item.trackName) {
            score += 50
        }
        if let itemYear = item.releaseYear, let movieYear = movie.year {
            score += max(0, 20 - abs(itemYear - movieYear) * 5)
        }
        if let director = item.artistName,
           director.localizedCaseInsensitiveContains(movie.director) ||
            movie.director.localizedCaseInsensitiveContains(director) {
            score += 20
        }
        if item.longDescription != nil || item.shortDescription != nil {
            score += 5
        }
        if item.artworkUrl100 != nil {
            score += 5
        }
        return score
    }

    private static func fetchWikidataMetadata(for movie: Movie, artworkDirectory: URL) async throws -> OnlineMovieMetadata {
        let query = """
        SELECT ?item ?itemLabel ?description ?directorLabel ?castLabel ?genreLabel ?image ?publicationDate WHERE {
          SERVICE wikibase:mwapi {
            bd:serviceParam wikibase:endpoint "www.wikidata.org";
                            wikibase:api "EntitySearch";
                            mwapi:search "\(sparqlEscaped(movie.title))";
                            mwapi:language "it".
            ?item wikibase:apiOutputItem mwapi:item.
          }
          ?item wdt:P31/wdt:P279* wd:Q11424.
          OPTIONAL { ?item schema:description ?description FILTER(LANG(?description) = "it") }
          OPTIONAL { ?item wdt:P57 ?director. }
          OPTIONAL { ?item wdt:P161 ?cast. }
          OPTIONAL { ?item wdt:P136 ?genre. }
          OPTIONAL { ?item wdt:P18 ?image. }
          OPTIONAL { ?item wdt:P577 ?publicationDate. }
          SERVICE wikibase:label { bd:serviceParam wikibase:language "it,en". }
        }
        LIMIT 60
        """

        var components = URLComponents(string: "https://query.wikidata.org/sparql")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "format", value: "json")
        ]

        let responseData = try await data(from: components.url!)
        let response = try JSONDecoder().decode(SPARQLResponse.self, from: responseData)
        let rows = response.results.bindings
        guard !rows.isEmpty else { throw OnlineMetadataError.noResult }

        let filtered = filterRows(rows, for: movie)
        guard !filtered.isEmpty else { throw OnlineMetadataError.noResult }

        let title = filtered.compactMap { $0.itemLabel?.value.nilIfBlank }.first
        let overview = filtered.compactMap { $0.description?.value.nilIfBlank }.first
        let sourceURL = filtered.compactMap { $0.item?.value.nilIfBlank }.first
        let year = filtered.compactMap { releaseYear(from: $0.publicationDate?.value) }.first
        let directors = Movie.unique(filtered.compactMap { $0.directorLabel?.value })
        let cast = Movie.unique(filtered.compactMap { $0.castLabel?.value }).prefix(18)
        let genres = Movie.unique(filtered.compactMap { $0.genreLabel?.value })

        var artworkPath: String?
        if let image = filtered.compactMap({ $0.image?.value.nilIfBlank }).first(where: wikipediaImageLooksPosterLike),
           let imageURL = URL(string: image),
           let downloaded = try? await downloadBestPoster(from: [imageURL], for: movie, artworkDirectory: artworkDirectory, suffix: "wikidata") {
            artworkPath = downloaded.path
        }

        return OnlineMovieMetadata(
            title: title,
            originalTitle: nil,
            overview: overview,
            genres: Array(genres),
            cast: Array(cast),
            directors: directors,
            releaseYear: year,
            source: "Wikidata",
            sourceURL: sourceURL,
            artworkPath: artworkPath,
            fetchedAt: Date()
        )
    }

    private static func filterRows(_ rows: [SPARQLBinding], for movie: Movie) -> [SPARQLBinding] {
        guard let year = movie.year else { return rows }
        let matching = rows.filter { row in
            guard let rowYear = releaseYear(from: row.publicationDate?.value) else { return true }
            return abs(rowYear - year) <= 1
        }
        return matching.isEmpty ? rows : matching
    }

    private static func releaseYear(from value: String?) -> Int? {
        guard let value, value.count >= 4 else { return nil }
        return Int(value.prefix(4))
    }

    private static func normalizedTitle(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var cleaned = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
            } else {
                cleaned.append(" ")
            }
        }
        return cleaned.split(separator: " ").joined(separator: " ")
    }

    private static func sparqlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func wikiPathEscaped(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func firstMetaContent(named property: String, in html: String) -> String? {
        allMetaContents(named: property, in: html).first
    }

    private static func allMetaContents(named property: String, in html: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            #"<meta\s+[^>]*(?:property|name)=["']\#(escaped)["'][^>]*content="([^"]*)"[^>]*>"#,
            #"<meta\s+[^>]*(?:property|name)=["']\#(escaped)["'][^>]*content='([^']*)'[^>]*>"#,
            #"<meta\s+[^>]*content="([^"]*)"[^>]*(?:property|name)=["']\#(escaped)["'][^>]*>"#,
            #"<meta\s+[^>]*content='([^']*)'[^>]*(?:property|name)=["']\#(escaped)["'][^>]*>"#
        ]

        return patterns.flatMap { pattern -> [String] in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return []
            }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            return regex.matches(in: html, range: range).compactMap { match in
                guard match.numberOfRanges > 1,
                      let range = Range(match.range(at: 1), in: html) else { return nil }
                return String(html[range])
            }
        }
    }

    private static func tmdbPublicImageURLs(in html: String) -> [URL] {
        var images = tmdbPublicStructuredImageURLs(in: html)
        images.append(contentsOf: allMetaContents(named: "og:image", in: html)
            .compactMap(htmlDecoded)
            .compactMap(URL.init(string:)))

        images.append(contentsOf: imageURLs(in: html).filter { $0.host == "image.tmdb.org" })

        return uniqueURLs(images).sorted { lhs, rhs in
            tmdbPublicImagePriority(lhs) > tmdbPublicImagePriority(rhs)
        }
    }

    private static func tmdbPublicStructuredImageURLs(in html: String) -> [URL] {
        captures(
            in: html,
            pattern: #""image"\s*:\s*"([^"]+)""#,
            options: [.caseInsensitive]
        )
        .compactMap(\.first)
        .compactMap(htmlDecoded)
        .compactMap(URL.init(string:))
        .filter { $0.host == "image.tmdb.org" }
    }

    private static func imageURLs(in html: String) -> [URL] {
        let patterns = [
            #"https://image\.tmdb\.org/t/p/[^"' <>)\\]+"#,
            #"//image\.tmdb\.org/t/p/[^"' <>)\\]+"#
        ]

        return patterns.flatMap { pattern -> [URL] in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            return regex.matches(in: html, range: range).compactMap { match in
                guard let range = Range(match.range(at: 0), in: html) else { return nil }
                var value = String(html[range])
                value = htmlDecoded(value) ?? value
                if value.hasPrefix("//") {
                    value = "https:" + value
                }
                return URL(string: value)
            }
        }
    }

    fileprivate static func wikipediaImageLooksPosterLike(_ value: String) -> Bool {
        guard let decoded = htmlDecoded(value) else { return false }
        let lower = decoded.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let positive = [
            "poster", "locandina", "manifesto", "film poster", "dvd", "cover"
        ]
        let negative = [
            "book cover", "romanzo", "novel", "portrait", "ritratto", "author",
            "scrittore", "writer", "stemma", "logo", "map", "mappa", "wikimedia",
            "commons", "set photo", "scene"
        ]
        if negative.contains(where: { lower.contains($0) }) {
            return false
        }
        return positive.contains { lower.contains($0) }
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let key = url.absoluteString
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return url
        }
    }

    private static func tmdbPublicImagePriority(_ url: URL) -> Int {
        let value = url.absoluteString
        if value.contains("/w500/") { return 100 }
        if value.contains("/w342/") { return 90 }
        if value.contains("/original/") { return 80 }
        if value.contains("/w780/") { return 10 }
        return 20
    }

    private static func tmdbPublicReleaseYear(in html: String) -> Int? {
        let patterns = [
            #"<span[^>]*class=["'][^"']*\btag\s+release_date\b[^"']*["'][^>]*>\s*\((\d{4})\)\s*</span>"#,
            #"<span[^>]*class=["'][^"']*\brelease\b[^"']*["'][^>]*>\s*\d{1,2}/\d{1,2}/(\d{4})"#,
            #"<title>[\s\S]*?\((\d{4})\)[\s\S]*?The Movie Database"#
        ]

        return patterns.compactMap { pattern in
            firstCapture(in: html, pattern: pattern).flatMap(Int.init)
        }.first
    }

    private static func tmdbPublicOriginalTitle(in html: String) -> String? {
        firstCapture(
            in: html,
            pattern: #"<strong>\s*Titolo originale\s*</strong>\s*([^<]+)</p>"#
        ).flatMap(htmlDecoded)?.nilIfBlank
    }

    private static func tmdbPublicDirectors(in html: String) -> [String]? {
        let pattern = #"<li[^>]*class=["'][^"']*\bprofile\b[^"']*["'][^>]*>[\s\S]*?<a[^>]*>([^<]+)</a>[\s\S]*?<p[^>]*class=["'][^"']*\bcharacter\b[^"']*["'][^>]*>([^<]+)</p>[\s\S]*?</li>"#
        let rows = captures(in: html, pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let names = rows.compactMap { row -> String? in
            guard row.count >= 2 else { return nil }
            let role = htmlDecoded(row[1])?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) ?? ""
            guard role.contains("director") || role.contains("regia") else { return nil }
            return htmlDecoded(row[0])?.nilIfBlank
        }
        let unique = Movie.unique(names)
        return unique.isEmpty ? nil : unique
    }

    private static func tmdbPublicCast(in html: String) -> [String]? {
        guard let block = firstCapture(
            in: html,
            pattern: #"<div[^>]*id=["']cast_scroller["'][^>]*>[\s\S]*?<ol[^>]*>([\s\S]*?)</ol>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }

        let names = captures(
            in: block,
            pattern: #"<p>\s*<a[^>]*href=["']/person/[^"']*["'][^>]*>([^<]+)</a>\s*</p>\s*<p[^>]*class=["'][^"']*\bcharacter\b[^"']*["']"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ).compactMap { $0.first.flatMap(htmlDecoded)?.nilIfBlank }

        let unique = Movie.unique(names)
        return unique.isEmpty ? nil : Array(unique.prefix(18))
    }

    private static func tmdbPublicGenres(in html: String) -> [String]? {
        guard let block = firstCapture(
            in: html,
            pattern: #"<span[^>]*class=["'][^"']*\bgenres\b[^"']*["'][^>]*>([\s\S]*?)</span>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }

        let genres = captures(
            in: block,
            pattern: #"<a[^>]*>([^<]+)</a>"#,
            options: [.caseInsensitive]
        ).compactMap { $0.first.flatMap(htmlDecoded)?.nilIfBlank }
        let unique = Movie.unique(genres)
        return unique.isEmpty ? nil : unique
    }

    private static func plainText(fromHTML html: String) -> String {
        var text = html
        text = text.replacingOccurrences(of: #"<style[\s\S]*?</style>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<script[\s\S]*?</script>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<sup[\s\S]*?</sup>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<table[\s\S]*?</table>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<figure[\s\S]*?</figure>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = htmlDecoded(text) ?? text
        text = text.replacingOccurrences(of: #"\[[0-9]+\]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[\s*modifica\s*\|\s*modifica wikitesto\s*\]"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"^\s*(Trama|Sinossi|Storia)\s+"#, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"[\s\n\r\t]+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func compactOverview(_ value: String?) -> String? {
        guard let value = value?.nilIfBlank else { return nil }
        if value.count <= 1200 {
            return value
        }
        let prefix = String(value.prefix(1200))
        if let sentenceEnd = prefix.lastIndex(where: { ".!?".contains($0) }) {
            return String(prefix[...sentenceEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func htmlDecoded(_ value: String?) -> String? {
        guard var value else { return nil }
        let namedEntities = [
            "&quot;": "\"",
            "&#34;": "\"",
            "&#039;": "'",
            "&#39;": "'",
            "&apos;": "'",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&nbsp;": " "
        ]
        for (entity, replacement) in namedEntities {
            value = value.replacingOccurrences(of: entity, with: replacement)
        }

        if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let original = value
            var result = ""
            var cursor = original.startIndex
            let matches = regex.matches(in: original, range: NSRange(original.startIndex..<original.endIndex, in: original))
            for match in matches {
                guard let fullRange = Range(match.range(at: 0), in: original),
                      let numberRange = Range(match.range(at: 1), in: original),
                      let scalarValue = UInt32(original[numberRange]),
                      let scalar = UnicodeScalar(scalarValue) else {
                    continue
                }
                result += original[cursor..<fullRange.lowerBound]
                result.append(Character(scalar))
                cursor = fullRange.upperBound
            }
            result += original[cursor..<original.endIndex]
            value = result
        }

        return value.replacingOccurrences(of: #"[\s]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func searchTitleCandidates(for movie: Movie) -> [String] {
        let baseTitles = Movie.unique([
            movie.title,
            movie.displayTitle,
            searchFriendlyTitle(movie.title),
            searchFriendlyTitle(movie.displayTitle),
            titleWithoutEdition(movie.title),
            titleWithoutEdition(movie.displayTitle)
        ])

        return Movie.unique(baseTitles.compactMap { value in
            let cleaned = searchFriendlyTitle(value)
            return cleaned.nilIfBlank
        })
    }

    private static func searchFriendlyTitle(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: #"(?i)\bf\.?\s*f\.?\s*s\.?\s*s\.?\b"#, with: "FF.SS.", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bcioe\b"#, with: "cioè", options: .regularExpression)
            .replacingOccurrences(of: #"[._]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[(?!\d{4}\])[^\]]+\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\((?!\d{4}\))[^\)]+\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\b(?:2160p|1080p|720p|480p|4k|uhd|hdr10\+?|hdr|bluray|blu ray|bdrip|brrip|webdl|web dl|webrip|web rip|dvdrip|hdtv|x264|x265|h264|h265|hevc|aac|ac3|eac3|dts|ita|eng|multi|sub|subs|mux)\b.*$"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\.\.\.\s*"#, with: " ...", options: .regularExpression)
            .replacingOccurrences(of: #"[\s]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        result = result.replacingOccurrences(of: #"(?i)^\s*(?:watch|guarda)\s+"#, with: "", options: .regularExpression)
        return result
    }

    private static func titleWithoutEdition(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"(?i)\b(?:extended|unrated|remastered|restored|proper|repack|limited|criterion|directors cut|director s cut|theatrical|final cut|uncut)\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[\s]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstCapture(
        in value: String,
        pattern: String,
        options: NSRegularExpression.Options = [.caseInsensitive]
    ) -> String? {
        captures(in: value, pattern: pattern, options: options).first?.first
    }

    private static func captures(
        in value: String,
        pattern: String,
        options: NSRegularExpression.Options
    ) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                guard let range = Range(match.range(at: index), in: value) else { return nil }
                return String(value[range])
            }
        }
    }

    private static func tmdbURL(path: String, token: String, queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(string: "https://api.themoviedb.org/3\(path)")!
        var items = queryItems
        if !usesBearerToken(token) {
            items.append(URLQueryItem(name: "api_key", value: token))
        }
        components.queryItems = items
        return components.url!
    }

    private static func tmdbData(from url: URL, token: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VideotecaOffline/1.0 (local macOS app)", forHTTPHeaderField: "User-Agent")
        if usesBearerToken(token) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private static func usesBearerToken(_ token: String) -> Bool {
        token.hasPrefix("eyJ") || token.contains(".") || token.count > 60
    }

    private static func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("VideotecaOffline/1.0 (local macOS app)", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    private static func downloadImage(from url: URL, for movie: Movie, artworkDirectory: URL, suffix: String) async throws -> URL {
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        let data = try await data(from: url)
        let digest = SHA256.hash(data: Data((movie.id + suffix).utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        let destination = artworkDirectory.appendingPathComponent(name).appendingPathExtension("jpg")
        try data.write(to: destination, options: [.atomic])
        return destination
    }

    private static func downloadBestPoster(from urls: [URL], for movie: Movie, artworkDirectory: URL, suffix: String) async throws -> URL {
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        var best: (data: Data, score: Double)?

        for url in urls {
            let imageData = try await data(from: url)
            guard let score = posterScore(forImageData: imageData) else {
                continue
            }
            if best == nil || score > best!.score {
                best = (imageData, score)
            }
        }

        guard let best else {
            throw OnlineMetadataError.noResult
        }

        let digest = SHA256.hash(data: Data((movie.id + suffix).utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        let destination = artworkDirectory.appendingPathComponent(name).appendingPathExtension("jpg")
        try best.data.write(to: destination, options: [.atomic])
        return destination
    }

    private static func posterScore(forImageData data: Data) -> Double? {
        guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
            return nil
        }

        let width = Double(image.size.width)
        let height = Double(image.size.height)
        let aspect = width / height
        guard aspect >= 0.50, aspect <= 0.82, height > width * 1.20 else {
            return nil
        }

        let idealAspect = 2.0 / 3.0
        let aspectScore = 100.0 - abs(aspect - idealAspect) * 120.0
        let sizeScore = min((width * height) / 300_000.0, 20.0)
        return aspectScore + sizeScore
    }
}

private struct TMDbSearchResponse: Decodable {
    let results: [TMDbSearchItem]
}

private struct TMDbSearchItem: Decodable {
    let id: Int
    let title: String?
    let originalTitle: String?
    let overview: String?
    let releaseDate: String?
    let posterPath: String?
    let popularity: Double?
    let voteCount: Int?

    var releaseYear: Int? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return Int(releaseDate.prefix(4))
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case originalTitle = "original_title"
        case overview
        case releaseDate = "release_date"
        case posterPath = "poster_path"
        case popularity
        case voteCount = "vote_count"
    }
}

private struct TMDbMovieDetails: Decodable {
    let id: Int
    let title: String?
    let originalTitle: String?
    let overview: String?
    let releaseDate: String?
    let posterPath: String?
    let genres: [TMDbGenre]?
    let credits: TMDbCredits?
    let images: TMDbImages?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case originalTitle = "original_title"
        case overview
        case releaseDate = "release_date"
        case posterPath = "poster_path"
        case genres
        case credits
        case images
    }
}

private struct TMDbGenre: Decodable {
    let name: String?
}

private struct TMDbCredits: Decodable {
    let cast: [TMDbCastMember]?
    let crew: [TMDbCrewMember]?
}

private struct TMDbCastMember: Decodable {
    let name: String?
    let order: Int?
}

private struct TMDbCrewMember: Decodable {
    let name: String?
    let job: String?
}

private struct TMDbImages: Decodable {
    let posters: [TMDbPoster]?
}

private struct TMDbPoster: Decodable {
    let filePath: String?
    let voteAverage: Double?
    let voteCount: Int?
    let languageCode: String?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case languageCode = "iso_639_1"
    }
}

private struct WikipediaSearchResponse: Decodable {
    let query: WikipediaSearchQuery
}

private struct WikipediaSearchQuery: Decodable {
    let search: [WikipediaSearchItem]
}

private struct WikipediaSearchItem: Decodable {
    let pageid: Int
    let title: String
    let snippet: String?
}

private struct WikipediaSummary: Decodable {
    let title: String?
    let extract: String?
    let contentURLs: WikipediaContentURLs?
    let thumbnail: WikipediaImage?
    let originalImage: WikipediaImage?

    var pageURL: String? {
        contentURLs?.desktop?.page
    }

    var bestPosterLikeImageURL: URL? {
        if let source = originalImage?.source,
           OnlineMetadataService.wikipediaImageLooksPosterLike(source),
           let url = URL(string: source) {
            return url
        }
        if let source = thumbnail?.source,
           OnlineMetadataService.wikipediaImageLooksPosterLike(source),
           let url = URL(string: source) {
            return url
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case title
        case extract
        case contentURLs = "content_urls"
        case thumbnail
        case originalImage = "originalimage"
    }
}

private struct WikipediaContentURLs: Decodable {
    let desktop: WikipediaDesktopURLs?
}

private struct WikipediaDesktopURLs: Decodable {
    let page: String?
}

private struct WikipediaImage: Decodable {
    let source: String?
}

private struct AppleSearchResponse: Decodable {
    let results: [AppleMovieItem]
}

private struct AppleMovieItem: Decodable {
    let trackName: String
    let artistName: String?
    let releaseDate: String?
    let primaryGenreName: String?
    let shortDescription: String?
    let longDescription: String?
    let artworkUrl100: String?
    let trackViewUrl: String?

    var releaseYear: Int? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return Int(releaseDate.prefix(4))
    }

    var largeArtworkURL: URL? {
        guard var artworkUrl100 else { return nil }
        artworkUrl100 = artworkUrl100
            .replacingOccurrences(of: "100x100bb", with: "1000x1500bb")
            .replacingOccurrences(of: "100x100", with: "1000x1500")
        return URL(string: artworkUrl100)
    }
}

private struct SPARQLResponse: Decodable {
    let results: SPARQLResults
}

private struct SPARQLResults: Decodable {
    let bindings: [SPARQLBinding]
}

private struct SPARQLBinding: Decodable {
    let item: SPARQLValue?
    let itemLabel: SPARQLValue?
    let description: SPARQLValue?
    let directorLabel: SPARQLValue?
    let castLabel: SPARQLValue?
    let genreLabel: SPARQLValue?
    let image: SPARQLValue?
    let publicationDate: SPARQLValue?
    let tmdbID: SPARQLValue?
}

private struct SPARQLValue: Decodable {
    let value: String
}

private struct WikipediaTOCResponse: Decodable {
    let parse: WikipediaTOCParse
}

private struct WikipediaTOCParse: Decodable {
    let tocdata: WikipediaTOCData
}

private struct WikipediaTOCData: Decodable {
    let sections: [WikipediaTOCSection]
}

private struct WikipediaTOCSection: Decodable {
    let line: String
    let index: String
}

private struct WikipediaTextResponse: Decodable {
    let parse: WikipediaTextParse
}

private struct WikipediaTextParse: Decodable {
    let text: WikipediaHTMLText
}

private struct WikipediaHTMLText: Decodable {
    let html: String

    enum CodingKeys: String, CodingKey {
        case html = "*"
    }
}
