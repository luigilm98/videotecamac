import Foundation

enum VideoMetadataCleaner {
    @discardableResult
    static func cleanGenericContainerTitleIfPossible(fileURL: URL, title: String) -> Bool? {
        let ext = fileURL.pathExtension.lowercased()
        guard ext == "mkv" || ext == "webm" else { return false }
        guard let cleanTitle = title.nilIfBlank, !isGenericTitle(cleanTitle) else { return false }
        guard let currentTitle = VideoProbe.containerTitle(fileURL: fileURL) else { return false }
        guard shouldReplaceContainerTitle(currentTitle, with: cleanTitle) else { return false }
        guard let mkvpropeditURL = mkvpropeditExecutableURL() else { return nil }
        let originalModifiedDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate

        let process = Process()
        process.executableURL = mkvpropeditURL
        process.arguments = [
            fileURL.path,
            "--edit", "info",
            "--set", "title=\(cleanTitle)"
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        if let originalModifiedDate {
            try? FileManager.default.setAttributes(
                [.modificationDate: originalModifiedDate],
                ofItemAtPath: fileURL.path
            )
        }
        return true
    }

    private static func shouldReplaceContainerTitle(_ currentTitle: String, with desiredTitle: String) -> Bool {
        let currentKey = ManualMovieCorrections.normalized(currentTitle)
        let desiredKey = ManualMovieCorrections.normalized(desiredTitle)
        guard !desiredKey.isEmpty, currentKey != desiredKey else { return false }

        if isGenericTitle(currentTitle) { return true }
        if isNumericOrIdentifier(currentKey) { return true }
        if looksLikeReleaseNoise(currentKey) { return true }
        return !titlesCompatible(currentKey, desiredKey)
    }

    private static func isGenericTitle(_ value: String) -> Bool {
        let key = ManualMovieCorrections.normalized(value)
        let generic = [
            "master", "movie", "film", "video", "media", "stream", "source",
            "download", "playlist", "index", "untitled", "mircrew"
        ]
        return key.isEmpty || generic.contains(key)
    }

    private static func isNumericOrIdentifier(_ key: String) -> Bool {
        if key.range(of: #"^\d{3,}$"#, options: .regularExpression) != nil { return true }
        if key.range(of: #"^[a-f0-9]{8,}$"#, options: .regularExpression) != nil { return true }
        let pieces = key.split(separator: " ")
        return pieces.count == 1 && (key.count >= 8 && key.rangeOfCharacter(from: .decimalDigits) != nil)
    }

    private static func looksLikeReleaseNoise(_ key: String) -> Bool {
        let noise = [
            "1080p", "2160p", "720p", "480p", "4k", "uhd", "hdr", "hdr10",
            "h265", "h264", "x265", "x264", "hevc", "ac3", "aac", "dts",
            "ita", "eng", "sub", "subs", "mircrew", "sp33dy94", "rip", "mux"
        ]
        return noise.contains { key.contains($0) }
    }

    private static func titlesCompatible(_ lhsKey: String, _ rhsKey: String) -> Bool {
        if lhsKey == rhsKey || lhsKey.contains(rhsKey) || rhsKey.contains(lhsKey) { return true }

        let left = significantWords(lhsKey)
        let right = significantWords(rhsKey)
        guard !left.isEmpty, !right.isEmpty else { return false }

        let overlap = left.intersection(right).count
        let ratio = Double(overlap) / Double(max(left.count, right.count))
        return ratio >= 0.6 || left.isSubset(of: right) || right.isSubset(of: left)
    }

    private static func significantWords(_ key: String) -> Set<String> {
        let ignored: Set<String> = [
            "il", "lo", "la", "i", "gli", "le", "un", "una", "uno", "e",
            "di", "del", "della", "dei", "degli", "the", "a", "an", "of", "and"
        ]
        return Set(key.split(separator: " ").map(String.init).filter { $0.count > 1 && !ignored.contains($0) })
    }

    private static func mkvpropeditExecutableURL() -> URL? {
        let paths = [
            "/opt/homebrew/bin/mkvpropedit",
            "/usr/local/bin/mkvpropedit",
            "/Applications/MKVToolNix.app/Contents/MacOS/mkvpropedit"
        ]

        if let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "mkvpropedit"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty,
              FileManager.default.isExecutableFile(atPath: output) else {
            return nil
        }
        return URL(fileURLWithPath: output)
    }
}
