import AppKit
import CryptoKit
import Foundation

enum SeriesOnlineMetadataService {
    static func fetch(for series: SeriesGroup, artworkDirectory: URL, tmdbToken: String? = nil) async throws -> OnlineMovieMetadata {
        let token = tmdbToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !token.isEmpty,
           let metadata = try? await fetchTMDbTVMetadata(for: series, artworkDirectory: artworkDirectory, token: token),
           metadata.hasContent {
            return metadata
        }

        if let metadata = try? await fetchPublicTMDbTVMetadata(for: series, artworkDirectory: artworkDirectory),
           metadata.hasContent {
            return metadata
        }

        throw OnlineMetadataError.noResult
    }

    private static func fetchTMDbTVMetadata(for series: SeriesGroup, artworkDirectory: URL, token: String) async throws -> OnlineMovieMetadata {
        let searchURL = tmdbURL(
            path: "/search/tv",
            token: token,
            queryItems: [
                URLQueryItem(name: "query", value: series.title),
                URLQueryItem(name: "language", value: "it-IT"),
                URLQueryItem(name: "include_adult", value: "false")
            ]
        )
        let searchData = try await tmdbData(from: searchURL, token: token)
        let search = try JSONDecoder().decode(TMDbTVSearchResponse.self, from: searchData)
        guard let match = search.results.max(by: { score($0, for: series) < score($1, for: series) }) else {
            throw OnlineMetadataError.noResult
        }

        let detailURL = tmdbURL(
            path: "/tv/\(match.id)",
            token: token,
            queryItems: [
                URLQueryItem(name: "language", value: "it-IT"),
                URLQueryItem(name: "append_to_response", value: "credits,images"),
                URLQueryItem(name: "include_image_language", value: "it,en,null")
            ]
        )
        let detailData = try await tmdbData(from: detailURL, token: token)
        let details = try JSONDecoder().decode(TMDbTVDetails.self, from: detailData)
        let posterPath = details.posterPath ?? details.images?.posters?.max(by: { posterScore($0) < posterScore($1) })?.filePath ?? match.posterPath
        var artworkPath: String?
        if let posterPath,
           let url = URL(string: "https://image.tmdb.org/t/p/w780\(posterPath)"),
           let downloaded = try? await downloadBestPoster(from: [url], id: series.id, artworkDirectory: artworkDirectory, suffix: "tmdb-tv-\(details.id)") {
            artworkPath = downloaded.path
        }

        let creators = Movie.unique(details.createdBy?.compactMap(\.name) ?? [])
        let cast = Movie.unique((details.credits?.cast ?? []).sorted { ($0.order ?? Int.max) < ($1.order ?? Int.max) }.compactMap(\.name))
        let genres = Movie.unique(details.genres?.compactMap(\.name) ?? [])

        return OnlineMovieMetadata(
            title: details.name ?? match.name,
            originalTitle: details.originalName ?? match.originalName,
            overview: details.overview ?? match.overview,
            genres: genres,
            cast: Array(cast.prefix(18)),
            directors: creators,
            releaseYear: releaseYear(from: details.firstAirDate) ?? match.releaseYear,
            source: "TMDb TV",
            sourceURL: "https://www.themoviedb.org/tv/\(details.id)",
            artworkPath: artworkPath,
            fetchedAt: Date()
        )
    }

    private static func fetchPublicTMDbTVMetadata(for series: SeriesGroup, artworkDirectory: URL) async throws -> OnlineMovieMetadata {
        let ids = try await publicTVSearchIDs(for: series)
        var candidates: [OnlineMovieMetadata] = []
        for id in ids.prefix(6) {
            if let metadata = try? await publicTVMetadata(for: series, id: id, artworkDirectory: artworkDirectory),
               compatible(metadata, with: series) {
                candidates.append(metadata)
            }
        }
        guard let best = candidates.max(by: { publicScore($0, for: series) < publicScore($1, for: series) }) else {
            throw OnlineMetadataError.noResult
        }
        return best
    }

    private static func publicTVSearchIDs(for series: SeriesGroup) async throws -> [String] {
        let queries = Movie.unique([
            series.title,
            series.displayTitle,
            "\(series.title) serie tv"
        ])

        var ids: [String] = []
        for query in queries.prefix(4) {
            var components = URLComponents(string: "https://www.themoviedb.org/search/tv")!
            components.queryItems = [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "language", value: "it-IT")
            ]
            let htmlData = try await data(from: components.url!)
            guard let html = String(data: htmlData, encoding: .utf8) else { continue }
            ids.append(contentsOf: captures(in: html, pattern: #"/tv/(\d+)(?:-[^"'<>?]*)?(?:\?[^"'<>]*)?"#).compactMap(\.first))
            if !ids.isEmpty { break }
        }

        var seen = Set<String>()
        return ids.filter { id in
            guard !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
    }

    private static func publicTVMetadata(for series: SeriesGroup, id: String, artworkDirectory: URL) async throws -> OnlineMovieMetadata {
        guard let url = URL(string: "https://www.themoviedb.org/tv/\(id)?language=it-IT") else {
            throw OnlineMetadataError.noResult
        }
        let htmlData = try await data(from: url)
        guard let html = String(data: htmlData, encoding: .utf8) else {
            throw OnlineMetadataError.noResult
        }

        let title = htmlDecoded(firstMetaContent(named: "og:title", in: html))?.nilIfBlank
        let overview = htmlDecoded(firstMetaContent(named: "og:description", in: html))?.nilIfBlank
        let posterURLs = imageURLs(in: html)
        let year = firstYear(in: html.prefix(60_000).description)
        let cast = Movie.unique(captures(in: html, pattern: #"<li class="card[^"]*"[\s\S]*?<p><a[^>]*>([^<]+)</a></p>"#, options: [.caseInsensitive]).compactMap(\.first).compactMap(htmlDecoded)).prefix(18)
        let genres = Movie.unique(captures(in: html, pattern: #"/genre/\d+[^>]*>([^<]+)</a>"#, options: [.caseInsensitive]).compactMap(\.first).compactMap(htmlDecoded))

        var artworkPath: String?
        if let downloaded = try? await downloadBestPoster(from: posterURLs, id: series.id, artworkDirectory: artworkDirectory, suffix: "tmdb-tv-public-\(id)") {
            artworkPath = downloaded.path
        }

        return OnlineMovieMetadata(
            title: title,
            originalTitle: nil,
            overview: overview,
            genres: genres,
            cast: Array(cast),
            directors: nil,
            releaseYear: year,
            source: "TMDb pubblico TV",
            sourceURL: "https://www.themoviedb.org/tv/\(id)",
            artworkPath: artworkPath,
            fetchedAt: Date()
        )
    }

    private static func compatible(_ metadata: OnlineMovieMetadata, with series: SeriesGroup) -> Bool {
        let target = normalized(series.title)
        let titles = [metadata.title, metadata.originalTitle].compactMap { $0 }.map(normalized).filter { !$0.isEmpty }
        return titles.isEmpty || titles.contains { titlesCompatible(target, $0) }
    }

    private static func score(_ item: TMDbTVSearchItem, for series: SeriesGroup) -> Int {
        var score = 0
        let target = normalized(series.title)
        for title in [item.name, item.originalName].compactMap({ $0 }).map(normalized) {
            if title == target { score += 90 }
            if title.contains(target) || target.contains(title) { score += 45 }
            if titlesCompatible(target, title) { score += 25 }
        }
        if item.posterPath != nil { score += 10 }
        if item.overview?.nilIfBlank != nil { score += 5 }
        score += min(12, Int(item.popularity ?? 0) / 5)
        return score
    }

    private static func publicScore(_ metadata: OnlineMovieMetadata, for series: SeriesGroup) -> Int {
        var score = 0
        if let title = metadata.title, titlesCompatible(normalized(series.title), normalized(title)) { score += 60 }
        if metadata.artworkPath != nil { score += 25 }
        if metadata.overview?.nilIfBlank != nil { score += 15 }
        return score
    }

    private static func titlesCompatible(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let left = significantWords(lhs)
        let right = significantWords(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if left.isSubset(of: right) || right.isSubset(of: left) { return true }
        return Double(left.intersection(right).count) / Double(max(left.count, right.count)) >= 0.60
    }

    private static func significantWords(_ value: String) -> Set<String> {
        let ignored: Set<String> = ["il", "lo", "la", "i", "gli", "le", "un", "una", "uno", "e", "di", "del", "della", "dei", "degli", "the", "a", "an", "of", "tv", "serie"]
        return Set(value.split(separator: " ").map(String.init).filter { $0.count > 1 && !ignored.contains($0) })
    }

    private static func posterScore(_ poster: TMDbTVPoster) -> Double {
        var score = poster.voteAverage ?? 0
        score += min(Double(poster.voteCount ?? 0) / 10.0, 8.0)
        switch poster.languageCode {
        case "it": score += 8
        case "en": score += 3
        case nil: score += 1
        default: break
        }
        return score
    }

    private static func imageURLs(in html: String) -> [URL] {
        var values = allMetaContents(named: "og:image", in: html)
        values.append(contentsOf: captures(in: html, pattern: #"https://image\.tmdb\.org/t/p/[^"' <>)\\]+"#).compactMap(\.first))
        return uniqueURLs(values.compactMap(htmlDecoded).compactMap(URL.init(string:)))
    }

    private static func downloadBestPoster(from urls: [URL], id: String, artworkDirectory: URL, suffix: String) async throws -> URL {
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        for url in urls {
            guard let data = try? await data(from: url),
                  let image = NSImage(data: data),
                  image.size.width > 0,
                  image.size.height / image.size.width >= 1.15 else {
                continue
            }
            let hash = SHA256.hash(data: Data("\(id)-\(suffix)-\(url.absoluteString)".utf8)).compactMap { String(format: "%02x", $0) }.joined()
            let destination = artworkDirectory.appendingPathComponent(hash).appendingPathExtension("jpg")
            try data.write(to: destination, options: [.atomic])
            return destination
        }
        throw OnlineMetadataError.noResult
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

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[\s]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func releaseYear(from value: String?) -> Int? {
        guard let value else { return nil }
        return firstYear(in: value)
    }

    private static func firstYear(in value: String) -> Int? {
        captures(in: value, pattern: #"\b((?:19|20)\d{2})\b"#).compactMap { $0.first.flatMap(Int.init) }.first
    }

    private static func firstMetaContent(named name: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return firstCapture(
            in: html,
            pattern: #"<meta\s+[^>]*(?:property|name)=["']\#(escaped)["'][^>]*content=["']([^"']*)["'][^>]*>"#,
            options: [.caseInsensitive]
        ) ?? firstCapture(
            in: html,
            pattern: #"<meta\s+[^>]*content=["']([^"']*)["'][^>]*(?:property|name)=["']\#(escaped)["'][^>]*>"#,
            options: [.caseInsensitive]
        )
    }

    private static func allMetaContents(named name: String, in html: String) -> [String] {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let first = captures(
            in: html,
            pattern: #"<meta\s+[^>]*(?:property|name)=["']\#(escaped)["'][^>]*content=["']([^"']*)["'][^>]*>"#,
            options: [.caseInsensitive]
        ).compactMap(\.first)
        let second = captures(
            in: html,
            pattern: #"<meta\s+[^>]*content=["']([^"']*)["'][^>]*(?:property|name)=["']\#(escaped)["'][^>]*>"#,
            options: [.caseInsensitive]
        ).compactMap(\.first)
        return first + second
    }

    private static func firstCapture(in value: String, pattern: String, options: NSRegularExpression.Options = []) -> String? {
        captures(in: value, pattern: pattern, options: options).first?.first
    }

    private static func captures(in value: String, pattern: String, options: NSRegularExpression.Options = []) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                guard let range = Range(match.range(at: index), in: value) else { return nil }
                return String(value[range])
            }
        }
    }

    private static func htmlDecoded(_ value: String?) -> String? {
        guard var result = value else { return nil }
        let replacements = [
            "&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
            "&lt;": "<", "&gt;": ">"
        ]
        for (from, to) in replacements {
            result = result.replacingOccurrences(of: from, with: to)
        }
        return result
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { url in
            guard !seen.contains(url.absoluteString) else { return false }
            seen.insert(url.absoluteString)
            return true
        }
    }
}

private struct TMDbTVSearchResponse: Decodable {
    var results: [TMDbTVSearchItem]
}

private struct TMDbTVSearchItem: Decodable {
    var id: Int
    var name: String?
    var originalName: String?
    var overview: String?
    var firstAirDate: String?
    var posterPath: String?
    var popularity: Double?

    var releaseYear: Int? {
        firstAirDate.flatMap { value in
            value.split(separator: "-").first.flatMap { Int($0) }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, overview, popularity
        case originalName = "original_name"
        case firstAirDate = "first_air_date"
        case posterPath = "poster_path"
    }
}

private struct TMDbTVDetails: Decodable {
    var id: Int
    var name: String?
    var originalName: String?
    var overview: String?
    var firstAirDate: String?
    var posterPath: String?
    var genres: [TMDbTVNamedItem]?
    var createdBy: [TMDbTVNamedItem]?
    var credits: TMDbTVCredits?
    var images: TMDbTVImages?

    enum CodingKeys: String, CodingKey {
        case id, name, overview, genres, credits, images
        case originalName = "original_name"
        case firstAirDate = "first_air_date"
        case posterPath = "poster_path"
        case createdBy = "created_by"
    }
}

private struct TMDbTVNamedItem: Decodable {
    var name: String?
}

private struct TMDbTVCredits: Decodable {
    var cast: [TMDbTVCastMember]?
}

private struct TMDbTVCastMember: Decodable {
    var name: String?
    var order: Int?
}

private struct TMDbTVImages: Decodable {
    var posters: [TMDbTVPoster]?
}

private struct TMDbTVPoster: Decodable {
    var filePath: String?
    var voteAverage: Double?
    var voteCount: Int?
    var languageCode: String?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case voteAverage = "vote_average"
        case voteCount = "vote_count"
        case languageCode = "iso_639_1"
    }
}
