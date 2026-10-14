import CryptoKit
import Foundation

enum CoverGenerator {
    static func existingCover(for movieURL: URL, cacheDirectory: URL) -> URL? {
        if let sidecar = sidecarCover(for: movieURL) {
            return sidecar
        }
        let cached = cachedCoverURL(for: movieURL, cacheDirectory: cacheDirectory)
        return FileManager.default.fileExists(atPath: cached.path) ? cached : nil
    }

    static func generateCover(for movieURL: URL, cacheDirectory: URL) -> URL? {
        if let sidecar = sidecarCover(for: movieURL) {
            return sidecar
        }

        let outputURL = cachedCoverURL(for: movieURL, cacheDirectory: cacheDirectory)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return outputURL
        }

        guard let ffmpegURL = ffmpegExecutableURL() else {
            return nil
        }

        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let offsets = ["00:05:00", "00:02:00", "00:00:30"]
        for offset in offsets {
            if runFFmpeg(ffmpegURL: ffmpegURL, inputURL: movieURL, outputURL: outputURL, offset: offset) {
                return outputURL
            }
        }
        try? FileManager.default.removeItem(at: outputURL)
        return nil
    }

    static func cachedCoverURL(for movieURL: URL, cacheDirectory: URL) -> URL {
        let digest = SHA256.hash(data: Data(movieURL.path.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(name).appendingPathExtension("jpg")
    }

    private static func sidecarCover(for movieURL: URL) -> URL? {
        let folder = movieURL.deletingLastPathComponent()
        let base = movieURL.deletingPathExtension().lastPathComponent
        let fileNames = [
            "\(base).jpg", "\(base).jpeg", "\(base).png", "\(base).webp",
            "cover.jpg", "cover.png", "poster.jpg", "poster.png", "folder.jpg", "folder.png"
        ]

        for name in fileNames {
            let candidate = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func ffmpegExecutableURL() -> URL? {
        let paths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return paths.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func runFFmpeg(ffmpegURL: URL, inputURL: URL, outputURL: URL, offset: String) -> Bool {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = [
            "-hide_banner",
            "-loglevel", "error",
            "-y",
            "-ss", offset,
            "-i", inputURL.path,
            "-frames:v", "1",
            "-vf", "scale=640:-1",
            "-q:v", "4",
            outputURL.path
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: outputURL.path)
        } catch {
            return false
        }
    }
}

