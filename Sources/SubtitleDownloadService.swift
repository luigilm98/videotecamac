import Foundation

struct OpenSubtitlesCredentials {
    var apiKey: String
    var username: String
    var password: String

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty
    }
}

private struct OpenSubtitlesSession {
    var token: String
    var baseURL: URL
}

enum SubtitleDownloadService {
    static func downloadItalianSubtitleIfNeeded(
        for movie: Movie,
        credentials: OpenSubtitlesCredentials
    ) async throws -> URL? {
        guard credentials.isConfigured else { return nil }
        guard movie.technicalInfo?.hasSubtitleLanguage(["it", "ita"]) != true else { return nil }
        guard existingSubtitleURL(for: movie.fileURL, languageCode: "it") == nil else { return nil }

        let session = try await login(credentials: credentials)
        let candidates = try await searchCandidates(for: movie, credentials: credentials, session: session)
        guard let best = candidates.sorted(by: { score($0, for: movie) > score($1, for: movie) }).first,
              let fileID = best.fileID else {
            return nil
        }

        let link = try await downloadLink(fileID: fileID, credentials: credentials, session: session)
        let data = try await downloadData(from: link)
        let subtitleText = try normalizedSubtitleText(from: data)
        let target = sidecarURL(for: movie.fileURL, languageCode: "it")
        try subtitleText.write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    private static func login(credentials: OpenSubtitlesCredentials) async throws -> OpenSubtitlesSession {
        var request = URLRequest(url: URL(string: "https://api.opensubtitles.com/api/v1/login")!)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        addCommonHeaders(to: &request, apiKey: credentials.apiKey)
        request.httpBody = try JSONEncoder().encode(OpenSubtitlesLoginRequest(
            username: credentials.username,
            password: credentials.password
        ))

        let response: OpenSubtitlesLoginResponse = try await decodedResponse(for: request)
        return OpenSubtitlesSession(
            token: response.token,
            baseURL: apiBaseURL(from: response.baseURL)
        )
    }

    private static func searchCandidates(
        for movie: Movie,
        credentials: OpenSubtitlesCredentials,
        session: OpenSubtitlesSession
    ) async throws -> [OpenSubtitlesCandidate] {
        let hash = movieHash(for: movie.fileURL)
        let year = movie.displayYear.map(String.init)
        let queries = Movie.unique([
            movie.displayTitle,
            [movie.displayTitle, year].compactMap { $0 }.joined(separator: " "),
            [movie.displayTitle, movie.displayDirector].joined(separator: " ")
        ])

        var results: [OpenSubtitlesCandidate] = []
        var searchPlans: [(query: String?, movieHash: String?)] = []
        if let hash {
            searchPlans.append((query: nil, movieHash: hash))
        }
        for query in queries.prefix(3) {
            searchPlans.append((query: query, movieHash: nil))
            if let hash {
                searchPlans.append((query: query, movieHash: hash))
            }
        }

        for plan in searchPlans {
            guard var components = URLComponents(url: apiURL("/api/v1/subtitles", baseURL: session.baseURL), resolvingAgainstBaseURL: false) else {
                continue
            }
            var queryItems = [
                URLQueryItem(name: "languages", value: "it"),
                URLQueryItem(name: "order_by", value: "download_count"),
                URLQueryItem(name: "order_direction", value: "desc")
            ]
            if let query = plan.query?.nilIfBlank {
                queryItems.append(URLQueryItem(name: "query", value: query))
            }
            if let movieHash = plan.movieHash?.nilIfBlank {
                queryItems.append(URLQueryItem(name: "moviehash", value: movieHash))
            }
            components.queryItems = queryItems
            guard let url = components.url else { continue }
            var request = URLRequest(url: url)
            addCommonHeaders(to: &request, apiKey: credentials.apiKey, token: session.token)

            if let response: OpenSubtitlesSearchResponse = try? await decodedResponse(for: request) {
                results.append(contentsOf: response.data.map(OpenSubtitlesCandidate.init(result:)))
            }
            if results.contains(where: { $0.matchedBy?.localizedCaseInsensitiveContains("moviehash") == true }) {
                break
            }
        }

        return results.filter { candidate in
            guard candidate.language == "it" else { return false }
            let title = candidate.featureTitle ?? ""
            let compatibleTitle = title.isEmpty || titlesCompatible(movie.displayTitle, title)
            let compatibleYear = movie.displayYear == nil || candidate.year == nil || abs((movie.displayYear ?? 0) - (candidate.year ?? 0)) <= 1
            return compatibleTitle && compatibleYear
        }
    }

    private static func downloadLink(
        fileID: Int,
        credentials: OpenSubtitlesCredentials,
        session: OpenSubtitlesSession
    ) async throws -> URL {
        var request = URLRequest(url: apiURL("/api/v1/download", baseURL: session.baseURL))
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        addCommonHeaders(to: &request, apiKey: credentials.apiKey, token: session.token)
        request.httpBody = try JSONEncoder().encode(OpenSubtitlesDownloadRequest(fileID: fileID, subFormat: "srt"))

        let response: OpenSubtitlesDownloadResponse = try await decodedResponse(for: request)
        guard let url = URL(string: response.link) else {
            throw URLError(.badURL)
        }
        return url
    }

    private static func downloadData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.addValue("Videoteca/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    private static func normalizedSubtitleText(from data: Data) throws -> String {
        if data.starts(with: [0x50, 0x4B]) {
            throw URLError(.cannotDecodeContentData)
        }
        if let text = String(data: data, encoding: .utf8)?.nilIfBlank {
            return text
        }
        if let text = String(data: data, encoding: .isoLatin1)?.nilIfBlank {
            return text
        }
        throw URLError(.cannotDecodeContentData)
    }

    private static func addCommonHeaders(to request: inout URLRequest, apiKey: String, token: String? = nil) {
        request.addValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.addValue("Videoteca/1.0", forHTTPHeaderField: "User-Agent")
        if let token {
            request.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func decodedResponse<T: Decodable>(for request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func apiURL(_ path: String, baseURL: URL) -> URL {
        URL(string: path, relativeTo: baseURL)!.absoluteURL
    }

    private static func apiBaseURL(from value: String?) -> URL {
        let fallback = URL(string: "https://api.opensubtitles.com")!
        guard let value = value?.nilIfBlank else { return fallback }
        let lowercasedValue = value.lowercased()
        if lowercasedValue.hasPrefix("http://") || lowercasedValue.hasPrefix("https://") {
            return URL(string: value) ?? fallback
        }
        return URL(string: "https://\(value)") ?? fallback
    }

    private static func sidecarURL(for movieURL: URL, languageCode: String) -> URL {
        movieURL
            .deletingLastPathComponent()
            .appendingPathComponent(movieURL.deletingPathExtension().lastPathComponent + ".\(languageCode)")
            .appendingPathExtension("srt")
    }

    private static func existingSubtitleURL(for movieURL: URL, languageCode: String) -> URL? {
        let url = sidecarURL(for: movieURL, languageCode: languageCode)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func score(_ candidate: OpenSubtitlesCandidate, for movie: Movie) -> Int {
        var value = 0
        if candidate.matchedBy?.localizedCaseInsensitiveContains("moviehash") == true { value += 80 }
        if let title = candidate.featureTitle, titlesCompatible(movie.displayTitle, title) { value += 35 }
        if let year = candidate.year, let movieYear = movie.displayYear, abs(year - movieYear) <= 1 { value += 25 }
        if candidate.fromTrusted == true { value += 10 }
        value += min(20, candidate.downloadCount / 1000)
        return value
    }

    private static func titlesCompatible(_ lhs: String, _ rhs: String) -> Bool {
        let leftKey = ManualMovieCorrections.normalized(lhs)
        let rightKey = ManualMovieCorrections.normalized(rhs)
        if leftKey == rightKey || leftKey.contains(rightKey) || rightKey.contains(leftKey) { return true }
        let left = significantWords(leftKey)
        let right = significantWords(rightKey)
        guard !left.isEmpty, !right.isEmpty else { return false }
        let ratio = Double(left.intersection(right).count) / Double(max(left.count, right.count))
        return ratio >= 0.6 || left.isSubset(of: right) || right.isSubset(of: left)
    }

    private static func significantWords(_ key: String) -> Set<String> {
        let ignored: Set<String> = ["il", "lo", "la", "i", "gli", "le", "un", "una", "uno", "e", "di", "del", "della", "dei", "degli", "the", "a", "an", "of", "and"]
        return Set(key.split(separator: " ").map(String.init).filter { $0.count > 1 && !ignored.contains($0) })
    }

    private static func movieHash(for url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return nil }
        var hash = size

        func addChunks(from offset: UInt64, length: Int) {
            try? handle.seek(toOffset: offset)
            let data = handle.readData(ofLength: length)
            data.withUnsafeBytes { raw in
                var index = 0
                while index + 8 <= raw.count {
                    hash &+= raw.loadUnaligned(fromByteOffset: index, as: UInt64.self).littleEndian
                    index += 8
                }
            }
        }

        addChunks(from: 0, length: min(64 * 1024, Int(size)))
        if size > 64 * 1024 {
            addChunks(from: max(0, size - UInt64(64 * 1024)), length: 64 * 1024)
        }
        return String(format: "%016llx", hash)
    }
}

private struct OpenSubtitlesLoginRequest: Encodable {
    var username: String
    var password: String
}

private struct OpenSubtitlesLoginResponse: Decodable {
    var token: String
    var baseURL: String?

    enum CodingKeys: String, CodingKey {
        case token
        case baseURL = "base_url"
    }
}

private struct OpenSubtitlesSearchResponse: Decodable {
    var data: [OpenSubtitlesResult]
}

private struct OpenSubtitlesResult: Decodable {
    var attributes: OpenSubtitlesAttributes
}

private struct OpenSubtitlesAttributes: Decodable {
    var language: String?
    var matchedBy: String?
    var downloadCount: Int?
    var fromTrusted: Bool?
    var featureDetails: OpenSubtitlesFeatureDetails?
    var files: [OpenSubtitlesFile]?

    enum CodingKeys: String, CodingKey {
        case language
        case matchedBy = "matched_by"
        case downloadCount = "download_count"
        case fromTrusted = "from_trusted"
        case featureDetails = "feature_details"
        case files
    }
}

private struct OpenSubtitlesFeatureDetails: Decodable {
    var title: String?
    var year: Int?
}

private struct OpenSubtitlesFile: Decodable {
    var fileID: Int

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
    }
}

private struct OpenSubtitlesCandidate {
    var language: String?
    var matchedBy: String?
    var downloadCount: Int
    var fromTrusted: Bool?
    var featureTitle: String?
    var year: Int?
    var fileID: Int?

    init(result: OpenSubtitlesResult) {
        let attributes = result.attributes
        self.language = attributes.language
        self.matchedBy = attributes.matchedBy
        self.downloadCount = attributes.downloadCount ?? 0
        self.fromTrusted = attributes.fromTrusted
        self.featureTitle = attributes.featureDetails?.title
        self.year = attributes.featureDetails?.year
        self.fileID = attributes.files?.first?.fileID
    }
}

private struct OpenSubtitlesDownloadRequest: Encodable {
    var fileID: Int
    var subFormat: String

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case subFormat = "sub_format"
    }
}

private struct OpenSubtitlesDownloadResponse: Decodable {
    var link: String
}
