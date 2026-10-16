import AppKit
import Foundation

enum PlayerLauncher {
    static func open(movie: Movie) {
        open(url: movie.fileURL)
    }

    static func open(url: URL) {
        let vlcURL = URL(fileURLWithPath: "/Applications/VLC.app")
        if FileManager.default.fileExists(atPath: vlcURL.path) {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: vlcURL, configuration: configuration)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static func reveal(movie: Movie) {
        reveal(url: movie.fileURL)
    }

    static func reveal(url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
