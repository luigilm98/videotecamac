import Foundation

struct OnlineSettings: Codable, Equatable {
    var tmdbToken: String = ""
    var autoOrganizeOnScan: Bool = true
    var thumbnailWidth: Double = 178
    var openSubtitlesApiKey: String = ""
    var openSubtitlesUsername: String = ""
    var openSubtitlesPassword: String = ""
    var autoDownloadItalianSubtitles: Bool = false

    init(
        tmdbToken: String = "",
        autoOrganizeOnScan: Bool = true,
        thumbnailWidth: Double = 178,
        openSubtitlesApiKey: String = "",
        openSubtitlesUsername: String = "",
        openSubtitlesPassword: String = "",
        autoDownloadItalianSubtitles: Bool = false
    ) {
        self.tmdbToken = tmdbToken
        self.autoOrganizeOnScan = autoOrganizeOnScan
        self.thumbnailWidth = thumbnailWidth
        self.openSubtitlesApiKey = openSubtitlesApiKey
        self.openSubtitlesUsername = openSubtitlesUsername
        self.openSubtitlesPassword = openSubtitlesPassword
        self.autoDownloadItalianSubtitles = autoDownloadItalianSubtitles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tmdbToken = try container.decodeIfPresent(String.self, forKey: .tmdbToken) ?? ""
        self.autoOrganizeOnScan = try container.decodeIfPresent(Bool.self, forKey: .autoOrganizeOnScan) ?? true
        self.thumbnailWidth = try container.decodeIfPresent(Double.self, forKey: .thumbnailWidth) ?? 178
        self.openSubtitlesApiKey = try container.decodeIfPresent(String.self, forKey: .openSubtitlesApiKey) ?? ""
        self.openSubtitlesUsername = try container.decodeIfPresent(String.self, forKey: .openSubtitlesUsername) ?? ""
        self.openSubtitlesPassword = try container.decodeIfPresent(String.self, forKey: .openSubtitlesPassword) ?? ""
        self.autoDownloadItalianSubtitles = try container.decodeIfPresent(Bool.self, forKey: .autoDownloadItalianSubtitles) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case tmdbToken
        case autoOrganizeOnScan
        case thumbnailWidth
        case openSubtitlesApiKey
        case openSubtitlesUsername
        case openSubtitlesPassword
        case autoDownloadItalianSubtitles
    }
}

final class OnlineSettingsStore {
    private let fileURL: URL
    private(set) var settings: OnlineSettings = OnlineSettings()

    init(applicationSupportURL: URL) {
        self.fileURL = applicationSupportURL.appendingPathComponent("online-settings.json")
        load()
    }

    func update(_ settings: OnlineSettings) {
        self.settings = settings
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(OnlineSettings.self, from: data) else {
            settings = OnlineSettings()
            return
        }
        settings = decoded
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: fileURL, options: [.atomic])
        } catch {
            NSLog("Could not save online settings: \(error.localizedDescription)")
        }
    }
}
