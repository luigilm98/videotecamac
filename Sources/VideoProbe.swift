import Foundation

enum VideoProbe {
    static func containerTitle(fileURL: URL) -> String? {
        guard let ffprobeURL = ffprobeExecutableURL() else { return nil }

        let process = Process()
        process.executableURL = ffprobeURL
        process.arguments = [
            "-v", "error",
            "-show_entries", "format_tags=title",
            "-print_format", "json",
            fileURL.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = try? JSONDecoder().decode(FFProbeOutput.self, from: data) else {
            return nil
        }
        return output.format?.tags?.title?.nilIfBlank
    }

    static func probe(fileURL: URL) -> VideoTechnicalInfo? {
        guard let ffprobeURL = ffprobeExecutableURL() else { return nil }

        let process = Process()
        process.executableURL = ffprobeURL
        process.arguments = [
            "-v", "error",
            "-show_format",
            "-show_streams",
            "-print_format", "json",
            fileURL.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = try? JSONDecoder().decode(FFProbeOutput.self, from: data) else {
            return nil
        }

        let streams = output.streams ?? []
        let video = streams.first { $0.codecType == "video" }
        let audioTracks = streams
            .filter { $0.codecType == "audio" }
            .map {
                MediaTrackInfo(
                    languageCode: $0.tags?.language,
                    title: $0.tags?.title,
                    codec: $0.codecName,
                    channels: $0.channels
                )
            }
        let subtitleTracks = streams
            .filter { $0.codecType == "subtitle" }
            .map {
                MediaTrackInfo(
                    languageCode: $0.tags?.language,
                    title: $0.tags?.title,
                    codec: $0.codecName,
                    channels: nil
                )
            }

        return VideoTechnicalInfo(
            durationSeconds: output.format?.durationValue ?? streams.compactMap(\.tagDurationValue).max(),
            width: video?.width,
            height: video?.height,
            frameRate: video?.frameRateValue,
            videoCodec: video?.codecName,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            externalSubtitleTracks: externalSubtitleTracks(for: fileURL),
            scannedAt: Date()
        )
    }

    static func technicalSignature(for fileURL: URL, fileIdentity: String) -> String {
        let sidecars = externalSubtitleURLs(for: fileURL)
            .compactMap { url -> String? in
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                    return nil
                }
                let size = values.fileSize ?? 0
                let modified = Int((values.contentModificationDate ?? Date.distantPast).timeIntervalSince1970)
                return "\(url.lastPathComponent):\(size):\(modified)"
            }
            .joined(separator: "|")
        return sidecars.isEmpty ? "v1:\(fileIdentity)" : "v1:\(fileIdentity):\(sidecars)"
    }

    private static func ffprobeExecutableURL() -> URL? {
        let paths = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe"
        ]

        if let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "ffprobe"]
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

    private static func externalSubtitleTracks(for fileURL: URL) -> [MediaTrackInfo] {
        externalSubtitleURLs(for: fileURL).map { url in
            MediaTrackInfo(
                languageCode: subtitleLanguageCode(for: url, movieURL: fileURL),
                title: "Esterno",
                codec: url.pathExtension.lowercased(),
                channels: nil
            )
        }
    }

    private static func externalSubtitleURLs(for fileURL: URL) -> [URL] {
        let subtitleExtensions: Set<String> = ["srt", "vtt", "ass", "ssa", "sub"]
        let folder = fileURL.deletingLastPathComponent()
        let base = fileURL.deletingPathExtension().lastPathComponent
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return items.filter { item in
            guard subtitleExtensions.contains(item.pathExtension.lowercased()) else { return false }
            let name = item.deletingPathExtension().lastPathComponent
            return name == base || name.hasPrefix(base + ".") || name.hasPrefix(base + "-")
        }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func subtitleLanguageCode(for subtitleURL: URL, movieURL: URL) -> String? {
        let base = movieURL.deletingPathExtension().lastPathComponent
        let name = subtitleURL.deletingPathExtension().lastPathComponent
        let suffix: String
        if name == base {
            suffix = ""
        } else if name.hasPrefix(base + ".") {
            suffix = String(name.dropFirst(base.count + 1))
        } else if name.hasPrefix(base + "-") {
            suffix = String(name.dropFirst(base.count + 1))
        } else {
            suffix = name
        }

        let key = ManualMovieCorrections.normalized(suffix)
        switch key {
        case "it", "ita", "italian", "italiano":
            return "it"
        case "en", "eng", "english", "inglese":
            return "en"
        case "forced", "it forced", "ita forced", "italian forced":
            return "it"
        case "":
            return nil
        default:
            return key.split(separator: " ").first.map(String.init)
        }
    }
}

private struct FFProbeOutput: Decodable {
    let streams: [FFProbeStream]?
    let format: FFProbeFormat?
}

private struct FFProbeFormat: Decodable {
    let duration: String?
    let tags: FFProbeTags?

    var durationValue: Double? {
        duration.flatMap(Double.init)
    }
}

private struct FFProbeStream: Decodable {
    let codecName: String?
    let codecType: String?
    let width: Int?
    let height: Int?
    let avgFrameRate: String?
    let channels: Int?
    let tags: FFProbeTags?

    var frameRateValue: Double? {
        guard let avgFrameRate, avgFrameRate != "0/0" else { return nil }
        let parts = avgFrameRate.split(separator: "/")
        if parts.count == 2,
           let numerator = Double(parts[0]),
           let denominator = Double(parts[1]),
           denominator != 0 {
            return numerator / denominator
        }
        return Double(avgFrameRate)
    }

    var tagDurationValue: Double? {
        tags?.duration.flatMap(Self.parseTagDuration)
    }

    private static func parseTagDuration(_ value: String) -> Double? {
        let pieces = value.split(separator: ":")
        guard pieces.count == 3,
              let hours = Double(pieces[0]),
              let minutes = Double(pieces[1]),
              let seconds = Double(pieces[2]) else {
            return Double(value)
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    enum CodingKeys: String, CodingKey {
        case codecName = "codec_name"
        case codecType = "codec_type"
        case width
        case height
        case avgFrameRate = "avg_frame_rate"
        case channels
        case tags
    }
}

private struct FFProbeTags: Decodable {
    let language: String?
    let title: String?
    let duration: String?

    enum CodingKeys: String, CodingKey {
        case language
        case title
        case duration = "DURATION"
    }
}
