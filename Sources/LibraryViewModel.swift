import AppKit
import Foundation
import SwiftUI

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var allMovies: [Movie] = []
    @Published var libraryItems: [LibraryItem] = []
    @Published var sources: [LibrarySource] = []
    @Published var searchText: String = ""
    @Published var sortMode: LibrarySortMode = .title
    @Published var selectedFilter: LibraryFilter = .all
    @Published var selectedMovieID: String?
    @Published var isScanning: Bool = false
    @Published var isGeneratingCovers: Bool = false
    @Published var isFetchingOnlineMetadata: Bool = false
    @Published var isEnrichingAllMetadata: Bool = false
    @Published var isDownloadingSubtitles: Bool = false
    @Published var isOrganizingLibrary: Bool = false
    @Published var showingSources: Bool = false
    @Published var tmdbToken: String = ""
    @Published var openSubtitlesApiKey: String = ""
    @Published var openSubtitlesUsername: String = ""
    @Published var openSubtitlesPassword: String = ""
    @Published var autoDownloadItalianSubtitles: Bool = false
    @Published var autoOrganizeOnScan: Bool = true
    @Published var thumbnailWidth: Double = 178
    @Published var statusText: String = "Pronto"

    private let applicationSupportURL: URL
    private let coverCacheURL: URL
    private let onlineArtworkURL: URL
    private let organizationLogURL: URL
    private let metadataStore: MetadataStore
    private let sourceStore: SourceStore
    private let onlineSettingsStore: OnlineSettingsStore
    private let automaticOnlineRetryInterval: TimeInterval = 30 * 60
    private let coreMetadataRefreshInterval: TimeInterval = 12 * 60 * 60
    private let weakOverviewRefreshInterval: TimeInterval = 7 * 24 * 60 * 60
    private var initialScanRequested = false

    init() {
        let supportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.applicationSupportURL = supportRoot.appendingPathComponent("Videoteca Offline", isDirectory: true)
        self.coverCacheURL = applicationSupportURL.appendingPathComponent("Covers", isDirectory: true)
        self.onlineArtworkURL = applicationSupportURL.appendingPathComponent("OnlineArtwork", isDirectory: true)
        self.organizationLogURL = applicationSupportURL.appendingPathComponent("organization-log.jsonl")
        self.metadataStore = MetadataStore(applicationSupportURL: applicationSupportURL)
        self.onlineSettingsStore = OnlineSettingsStore(applicationSupportURL: applicationSupportURL)
        let externalFilmURL = URL(fileURLWithPath: "/Volumes/ssdex/film", isDirectory: true)
        let localFilmURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/film", isDirectory: true)
        let defaultFilmURL = FileManager.default.fileExists(atPath: externalFilmURL.path) ? externalFilmURL : localFilmURL
        self.sourceStore = SourceStore(
            applicationSupportURL: applicationSupportURL,
            defaultSources: [LibrarySource(url: defaultFilmURL)]
        )
        self.sources = sourceStore.sources
        self.tmdbToken = onlineSettingsStore.settings.tmdbToken
        self.openSubtitlesApiKey = onlineSettingsStore.settings.openSubtitlesApiKey
        self.openSubtitlesUsername = onlineSettingsStore.settings.openSubtitlesUsername
        self.openSubtitlesPassword = onlineSettingsStore.settings.openSubtitlesPassword
        self.autoDownloadItalianSubtitles = onlineSettingsStore.settings.autoDownloadItalianSubtitles
        self.autoOrganizeOnScan = true
        self.thumbnailWidth = min(270, max(130, onlineSettingsStore.settings.thumbnailWidth))
        try? FileManager.default.createDirectory(at: coverCacheURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: onlineArtworkURL, withIntermediateDirectories: true)
        DispatchQueue.main.async { [weak self] in
            self?.startInitialScanIfNeeded()
        }
    }

    var selectedItem: LibraryItem? {
        guard let id = selectedMovieID else { return filteredItems.first }
        return libraryItems.first { $0.id == id }
    }

    var selectedMovie: Movie? {
        selectedItem?.movie ?? selectedItem?.series?.representativeMovie
    }

    var filteredItems: [LibraryItem] {
        var items = libraryItems.filter { itemMatches($0, filter: selectedFilter) }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            items = items.filter { itemMatchesSearch($0, query: query) }
        }

        return items.sorted(by: itemSorter)
    }

    var filteredMovies: [Movie] {
        filteredItems.flatMap(\.movies)
    }

    private var legacyFilteredMovies: [Movie] {
        var movies = allMovies

        switch selectedFilter {
        case .all:
            break
        case .favorites:
            movies = movies.filter(\.favorite)
        case .unwatched:
            movies = movies.filter { !$0.watched }
        case .withoutGenre:
            movies = movies.filter { $0.displayGenres.isEmpty }
        case .qualityReview:
            movies = movies.filter { $0.metadataQuality == .review }
        case .weakMetadata:
            movies = movies.filter { !$0.qualityIssues.isEmpty }
        case .missingPoster:
            movies = movies.filter { $0.posterURL == nil }
        case .noSubtitles:
            movies = movies.filter { $0.technicalInfo?.subtitleText == "Nessuno" }
        case .italianAudio:
            movies = movies.filter { $0.technicalInfo?.hasAudioLanguage(["ita", "it"]) == true }
        case .multiAudio:
            movies = movies.filter { ($0.technicalInfo?.audioTracks.count ?? 0) > 1 }
        case .fullHD:
            movies = movies.filter { movie in
                guard let info = movie.technicalInfo,
                      let width = info.width,
                      let height = info.height else { return false }
                return (width >= 1900 || height >= 1000) && width < 3840 && height < 2160
            }
        case .fourK:
            movies = movies.filter { movie in
                guard let info = movie.technicalInfo,
                      let width = info.width,
                      let height = info.height else { return false }
                return width >= 3840 || height >= 2160
            }
        case .shortMovies:
            movies = movies.filter { ($0.technicalInfo?.durationSeconds ?? .infinity) <= 90 * 60 }
        case .recentImports:
            let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
            movies = movies.filter { $0.modifiedDate >= cutoff }
        case .genre(let genre):
            movies = movies.filter { $0.displayGenres.contains { $0.caseInsensitiveCompare(genre) == .orderedSame } }
        case .director(let director):
            movies = movies.filter { $0.displayDirector.caseInsensitiveCompare(director) == .orderedSame }
        case .actor(let actor):
            movies = movies.filter { $0.displayActors.contains { $0.caseInsensitiveCompare(actor) == .orderedSame } }
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            movies = movies.filter { movie in
                let technicalValues = [
                    movie.technicalInfo?.durationText,
                    movie.technicalInfo?.resolutionText,
                    movie.technicalInfo?.primaryAudioText,
                    movie.technicalInfo?.extraAudioText,
                    movie.technicalInfo?.subtitleText,
                    movie.technicalInfo?.videoCodecText
                ].compactMap { $0 }
                let haystack = ([movie.title, movie.displayTitle, movie.director, movie.displayDirector, movie.yearText, movie.displayYearText] + movie.displayActors + movie.displayGenres + technicalValues)
                    .joined(separator: " ")
                return haystack.localizedCaseInsensitiveContains(query)
            }
        }

        return movies.sorted(by: sorter)
    }

    var allGenres: [String] {
        Movie.unique(libraryItems.flatMap(\.displayGenres)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var allDirectors: [String] {
        Movie.unique(libraryItems.map(\.displayDirector)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var allActors: [String] {
        Movie.unique(libraryItems.flatMap(\.displayActors)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var countText: String {
        let totalItems = libraryItems.count
        let filteredCount = filteredItems.count
        guard allMovies.count != totalItems else {
            return "\(filteredCount) di \(totalItems) titoli"
        }
        return "\(filteredCount) di \(totalItems) titoli, \(allMovies.count) file"
    }

    var qualityReviewCount: Int {
        allMovies.filter { $0.metadataQuality == .review }.count
    }

    var weakMetadataCount: Int {
        allMovies.filter { !$0.qualityIssues.isEmpty }.count
    }

    var recentImportCount: Int {
        let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
        return allMovies.filter { $0.modifiedDate >= cutoff }.count
    }

    func startInitialScanIfNeeded() {
        guard !initialScanRequested,
              ProcessInfo.processInfo.environment["VIDEOTECA_SKIP_AUTOSCAN"] != "1" else {
            return
        }
        initialScanRequested = true
        scan()
    }

    func scan() {
        guard !isScanning, !isOrganizingLibrary else { return }
        isScanning = true
        statusText = "Scansione sorgenti..."
        let sourceList = sources
        let store = metadataStore
        let coverRoot = coverCacheURL
        let artworkRoot = onlineArtworkURL
        let logURL = organizationLogURL
        let token = tmdbToken
        let shouldOrganize = true

        Task.detached(priority: .userInitiated) {
            let prunedCount = store.pruneMissingFiles(within: sourceList)
            var movies = MovieScanner.scan(sources: sourceList, metadataStore: store, coverCacheURL: coverRoot)
            let repairedCount = Self.repairIncompatibleOnlineMetadata(in: movies, metadataStore: store)
            if prunedCount > 0 || repairedCount > 0 {
                movies = MovieScanner.scan(sources: sourceList, metadataStore: store, coverCacheURL: coverRoot)
            }

            let initialMovies = movies
            await MainActor.run {
                self.publishScannedMovies(initialMovies)
                self.isScanning = false
                self.statusText = "Trovati \(self.libraryItems.count) titoli"
            }

            if shouldOrganize {
                await MainActor.run {
                    self.isOrganizingLibrary = true
                    self.statusText = "Controllo nuovi film da catalogare..."
                }
                let summary = await MovieOrganizer.organize(
                    movies: movies,
                    sources: sourceList,
                    metadataStore: store,
                    coverCacheURL: coverRoot,
                    artworkDirectory: artworkRoot,
                    logURL: logURL,
                    tmdbToken: token
                ) { message in
                    await MainActor.run {
                        self.statusText = message
                    }
                }
                movies = MovieScanner.scan(sources: sourceList, metadataStore: store, coverCacheURL: coverRoot)
                let repairedCount = Self.repairIncompatibleOnlineMetadata(in: movies, metadataStore: store)
                if repairedCount > 0 {
                    movies = MovieScanner.scan(sources: sourceList, metadataStore: store, coverCacheURL: coverRoot)
                }
                let organizedMovies = movies
                await MainActor.run {
                    self.publishScannedMovies(organizedMovies)
                    self.isOrganizingLibrary = false
                    self.statusText = "Catalogati \(summary.movedCount), saltati \(summary.skippedCount), errori \(summary.failedCount)"
                }
            }

            await MainActor.run {
                self.statusText = "Controllo titoli interni video..."
            }
            let cleanedTitleCount = Self.cleanGenericContainerTitles(in: movies, metadataStore: store)
            if cleanedTitleCount > 0 {
                movies = MovieScanner.scan(sources: sourceList, metadataStore: store, coverCacheURL: coverRoot)
            }

            let finalMovies = movies
            await MainActor.run {
                self.publishScannedMovies(finalMovies)
                self.isScanning = false
                self.statusText = "Trovati \(self.libraryItems.count) titoli"
            }
            await self.generateMissingTechnicalInfo()
            await self.downloadMissingItalianSubtitles()
            await self.generateMissingCovers()
            await self.enrichMissingOnlineMetadata()
            await self.enrichMissingSeriesMetadata()
        }
    }

    func updateGenres(for movie: Movie, text: String) {
        let genres = Movie.unique(text.split(separator: ",").map { String($0) })
        updateMetadata(for: movie.id) { metadata in
            metadata.genres = genres
        }
        updateMovie(movie.id) { $0.userGenres = genres }
    }

    func updateNotes(for movie: Movie, text: String) {
        updateMetadata(for: movie.id) { metadata in
            metadata.notes = text
        }
        updateMovie(movie.id) { $0.notes = text }
    }

    func updateOnlineMetadata(_ online: OnlineMovieMetadata, for movie: Movie) {
        let online = completedOnlineMetadata(online, for: movie)
        updateMetadata(for: movie.id) { metadata in
            metadata.online = online
            metadata.onlineLookupSignature = movie.fileSignature
            metadata.onlineLookupFailedAt = nil
            metadata.fileIdentity = movie.fileIdentity
        }
        updateMovie(movie.id) {
            $0.onlineMetadata = online
            $0.onlineLookupSignature = movie.fileSignature
            $0.onlineLookupFailedAt = nil
        }
    }

    private func completedOnlineMetadata(_ online: OnlineMovieMetadata, for movie: Movie) -> OnlineMovieMetadata {
        var result = OnlineMetadataService.completedWithLocalCorrections(online, for: movie)
        result.genres = Movie.unique((result.genres ?? []) + movie.genres)
        return result
    }

    func setFavorite(_ value: Bool, for movie: Movie) {
        updateMetadata(for: movie.id) { metadata in
            metadata.favorite = value
        }
        updateMovie(movie.id) { $0.favorite = value }
    }

    func setWatched(_ value: Bool, for movie: Movie) {
        updateMetadata(for: movie.id) { metadata in
            metadata.watched = value
        }
        updateMovie(movie.id) { $0.watched = value }
    }

    func regenerateCover(for movie: Movie) {
        statusText = "Genero copertina..."
        Task.detached(priority: .utility) {
            let cached = CoverGenerator.cachedCoverURL(for: movie.fileURL, cacheDirectory: self.coverCacheURL)
            try? FileManager.default.removeItem(at: cached)
            let cover = CoverGenerator.generateCover(for: movie.fileURL, cacheDirectory: self.coverCacheURL)
            await MainActor.run {
                self.updateMovie(movie.id) { $0.coverURL = cover }
                self.statusText = cover == nil ? "Copertina non generata" : "Copertina aggiornata"
            }
        }
    }

    func fetchOnlineMetadata(for movie: Movie) {
        isFetchingOnlineMetadata = true
        statusText = "Cerco metadati online..."
        let token = tmdbToken

        Task.detached(priority: .userInitiated) {
            do {
                let online = try await OnlineMetadataService.fetch(for: movie, artworkDirectory: self.onlineArtworkURL, tmdbToken: token)
                await MainActor.run {
                    self.updateOnlineMetadata(online, for: movie)
                    self.isFetchingOnlineMetadata = false
                    self.statusText = "Metadati online salvati"
                }
            } catch {
                await MainActor.run {
                    self.markOnlineLookupFailed(for: movie)
                    self.isFetchingOnlineMetadata = false
                    self.statusText = error.localizedDescription
                }
            }
        }
    }

    func enrichAllOnlineMetadata() {
        guard !allMovies.isEmpty else { return }
        isEnrichingAllMetadata = true
        statusText = "Aggiorno metadati e poster..."
        let movies = allMovies.filter { !isSeriesEpisode($0) }
        let artworkRoot = onlineArtworkURL
        let token = tmdbToken

        Task.detached(priority: .utility) {
            var successCount = 0
            for (index, movie) in movies.enumerated() {
                if Task.isCancelled { break }
                await MainActor.run {
                    self.statusText = "Online \(index + 1)/\(movies.count): \(movie.title)"
                }

                if let online = try? await OnlineMetadataService.fetch(for: movie, artworkDirectory: artworkRoot, tmdbToken: token) {
                    await MainActor.run {
                        self.updateOnlineMetadata(online, for: movie)
                    }
                    successCount += 1
                } else {
                    await MainActor.run {
                        self.markOnlineLookupFailed(for: movie)
                    }
                }
            }

            let finalSuccessCount = successCount
            await MainActor.run {
                self.isEnrichingAllMetadata = false
                self.statusText = "Metadati online salvati per \(finalSuccessCount) film"
            }
        }
    }

    func enrichMissingOnlineMetadata() async {
        let movies = allMovies.filter { movie in
            !isSeriesEpisode(movie) && needsBetterOnlineMetadata(movie)
        }
        guard !movies.isEmpty, !isEnrichingAllMetadata else { return }

        isEnrichingAllMetadata = true
        statusText = "Completo schede e copertine..."
        let artworkRoot = onlineArtworkURL
        let token = tmdbToken

        await Task.detached(priority: .utility) {
            var successCount = 0
            for (index, movie) in movies.enumerated() {
                if Task.isCancelled { break }
                await MainActor.run {
                    self.statusText = "Schede \(index + 1)/\(movies.count): \(movie.title)"
                }

                if let online = try? await OnlineMetadataService.fetch(for: movie, artworkDirectory: artworkRoot, tmdbToken: token) {
                    await MainActor.run {
                        self.updateOnlineMetadata(online, for: movie)
                    }
                    successCount += 1
                } else {
                    await MainActor.run {
                        self.markOnlineLookupFailed(for: movie)
                    }
                }
            }

            let finalSuccessCount = successCount
            await MainActor.run {
                self.isEnrichingAllMetadata = false
                self.statusText = finalSuccessCount == 0
                    ? "Videoteca aggiornata"
                    : "Schede aggiornate per \(finalSuccessCount) film"
            }
        }.value
    }

    func enrichMissingSeriesMetadata() async {
        let seriesToUpdate = libraryItems.compactMap(\.series).filter(needsBetterSeriesMetadata)
        guard !seriesToUpdate.isEmpty, !isEnrichingAllMetadata else { return }

        isEnrichingAllMetadata = true
        statusText = "Completo schede serie..."
        let artworkRoot = onlineArtworkURL
        let token = tmdbToken

        await Task.detached(priority: .utility) {
            var successCount = 0
            for (index, series) in seriesToUpdate.enumerated() {
                if Task.isCancelled { break }
                await MainActor.run {
                    self.statusText = "Serie \(index + 1)/\(seriesToUpdate.count): \(series.displayTitle)"
                }

                if let online = try? await SeriesOnlineMetadataService.fetch(for: series, artworkDirectory: artworkRoot, tmdbToken: token) {
                    await MainActor.run {
                        self.updateMetadata(for: series.id) { metadata in
                            metadata.online = online
                            metadata.onlineLookupSignature = self.seriesLookupSignature(for: series)
                            metadata.onlineLookupFailedAt = nil
                        }
                        self.rebuildLibraryItems()
                    }
                    successCount += 1
                } else {
                    await MainActor.run {
                        self.updateMetadata(for: series.id) { metadata in
                            metadata.onlineLookupSignature = self.seriesLookupSignature(for: series)
                            metadata.onlineLookupFailedAt = Date()
                        }
                    }
                }
            }

            let finalSuccessCount = successCount
            await MainActor.run {
                self.isEnrichingAllMetadata = false
                self.statusText = finalSuccessCount == 0
                    ? "Videoteca aggiornata"
                    : "Schede serie aggiornate per \(finalSuccessCount) serie"
            }
        }.value
    }

    private func needsBetterOnlineMetadata(_ movie: Movie) -> Bool {
        if let online = movie.onlineMetadata, OnlineMetadataService.hasHardIdentityMismatch(online, with: movie) {
            return true
        }

        let signatureMatches = movie.onlineLookupSignature == movie.fileSignature
        guard let online = movie.onlineMetadata else {
            if signatureMatches,
               let failedAt = movie.onlineLookupFailedAt,
               Date().timeIntervalSince(failedAt) < automaticOnlineRetryInterval {
                return false
            }
            return true
        }

        let hasWeakOverview = OnlineMetadataService.hasWeakOverview(online.overview)
        let hasBadArtwork = !hasUsablePoster(online.artworkPath)
        let hasMissingCore = online.title?.nilIfBlank == nil ||
            online.releaseYear == nil ||
            (online.directors ?? []).isEmpty

        guard hasWeakOverview || hasBadArtwork || hasMissingCore else { return false }

        if hasBadArtwork || hasMissingCore {
            return shouldRefreshExistingMetadata(online, for: movie, minimumAge: coreMetadataRefreshInterval)
        }

        return shouldRefreshExistingMetadata(online, for: movie, minimumAge: weakOverviewRefreshInterval)
    }

    private func needsBetterSeriesMetadata(_ series: SeriesGroup) -> Bool {
        let metadata = metadataStore.metadata(for: series.id)
        let signature = seriesLookupSignature(for: series)
        if metadata.onlineLookupSignature == signature,
           let failedAt = metadata.onlineLookupFailedAt,
           Date().timeIntervalSince(failedAt) < automaticOnlineRetryInterval {
            return false
        }

        guard let online = metadata.online else {
            return true
        }

        let hasPoster = hasUsablePoster(online.artworkPath)
        let hasOverview = !OnlineMetadataService.hasWeakOverview(online.overview)
        return !hasPoster || !hasOverview || (online.cast ?? []).isEmpty || (online.genres ?? []).isEmpty
    }

    private func seriesLookupSignature(for series: SeriesGroup) -> String {
        let newest = Int(series.modifiedDate.timeIntervalSince1970)
        return "tv:v1:\(series.episodes.count):\(newest):\(series.id)"
    }

    private func shouldRefreshExistingMetadata(_ online: OnlineMovieMetadata, for movie: Movie, minimumAge: TimeInterval) -> Bool {
        if let failedAt = movie.onlineLookupFailedAt,
           Date().timeIntervalSince(failedAt) < automaticOnlineRetryInterval {
            return false
        }

        guard let fetchedAt = online.fetchedAt else { return true }
        return Date().timeIntervalSince(fetchedAt) >= minimumAge
    }

    private func hasUsablePoster(_ path: String?) -> Bool {
        guard let path = path?.nilIfBlank,
              FileManager.default.fileExists(atPath: path),
              let image = NSImage(contentsOfFile: path),
              image.size.width > 0 else {
            return false
        }
        return image.size.height / image.size.width >= 1.20
    }

    func saveOnlineSettings() {
        onlineSettingsStore.update(OnlineSettings(
            tmdbToken: tmdbToken.trimmingCharacters(in: .whitespacesAndNewlines),
            autoOrganizeOnScan: true,
            thumbnailWidth: thumbnailWidth,
            openSubtitlesApiKey: openSubtitlesApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            openSubtitlesUsername: openSubtitlesUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            openSubtitlesPassword: openSubtitlesPassword,
            autoDownloadItalianSubtitles: autoDownloadItalianSubtitles
        ))
        tmdbToken = onlineSettingsStore.settings.tmdbToken
        openSubtitlesApiKey = onlineSettingsStore.settings.openSubtitlesApiKey
        openSubtitlesUsername = onlineSettingsStore.settings.openSubtitlesUsername
        openSubtitlesPassword = onlineSettingsStore.settings.openSubtitlesPassword
        autoDownloadItalianSubtitles = onlineSettingsStore.settings.autoDownloadItalianSubtitles
        autoOrganizeOnScan = true
        thumbnailWidth = min(270, max(130, onlineSettingsStore.settings.thumbnailWidth))
        statusText = "Impostazioni online salvate"
    }

    func setThumbnailWidth(_ value: Double) {
        thumbnailWidth = min(270, max(130, value))
        onlineSettingsStore.update(OnlineSettings(
            tmdbToken: tmdbToken.trimmingCharacters(in: .whitespacesAndNewlines),
            autoOrganizeOnScan: true,
            thumbnailWidth: thumbnailWidth,
            openSubtitlesApiKey: openSubtitlesApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            openSubtitlesUsername: openSubtitlesUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            openSubtitlesPassword: openSubtitlesPassword,
            autoDownloadItalianSubtitles: autoDownloadItalianSubtitles
        ))
    }

    func organizeNewMovies() {
        guard !isOrganizingLibrary else { return }
        isOrganizingLibrary = true
        statusText = "Catalogo nuovi film..."
        let sourceList = sources
        let store = metadataStore
        let coverRoot = coverCacheURL
        let artworkRoot = onlineArtworkURL
        let logURL = organizationLogURL
        let token = tmdbToken
        let movies = allMovies.isEmpty
            ? MovieScanner.scan(sources: sourceList, metadataStore: store, coverCacheURL: coverRoot)
            : allMovies

        Task.detached(priority: .userInitiated) {
            let summary = await MovieOrganizer.organize(
                movies: movies,
                sources: sourceList,
                metadataStore: store,
                coverCacheURL: coverRoot,
                artworkDirectory: artworkRoot,
                logURL: logURL,
                tmdbToken: token
            ) { message in
                await MainActor.run {
                    self.statusText = message
                }
            }

            let updated = MovieScanner.scan(sources: sourceList, metadataStore: store, coverCacheURL: coverRoot)
            await MainActor.run {
                self.publishScannedMovies(updated)
                self.isOrganizingLibrary = false
                self.statusText = "Catalogati \(summary.movedCount), saltati \(summary.skippedCount), errori \(summary.failedCount)"
            }
            await self.generateMissingTechnicalInfo()
            await self.downloadMissingItalianSubtitles()
            await self.generateMissingCovers()
            await self.enrichMissingSeriesMetadata()
        }
    }

    func chooseFolderSource() {
        let panel = NSOpenPanel()
        panel.title = "Aggiungi una cartella video"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK {
            setSources(sources + panel.urls.map(LibrarySource.init(url:)))
        }
    }

    func replaceWithFolderSource() {
        let panel = NSOpenPanel()
        panel.title = "Scegli la cartella principale della videoteca"
        panel.message = "Puoi scegliere Documenti/film, una cartella su hard disk esterno, o direttamente una cartella che contiene i film."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Users/luigi/Documents", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.urls.first {
            setSources([LibrarySource(url: url)])
        }
    }

    func chooseExternalDriveSource() {
        let panel = NSOpenPanel()
        panel.title = "Scegli cartella o hard disk esterno"
        panel.message = "Seleziona il disco esterno o una cartella al suo interno. Verranno letti i file video contenuti."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        if panel.runModal() == .OK {
            setSources(sources + panel.urls.map(LibrarySource.init(url:)))
        }
    }

    func chooseFileSources() {
        let panel = NSOpenPanel()
        panel.title = "Scegli file video"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK {
            setSources(sources + panel.urls.filter(MovieScanner.isVideo).map(LibrarySource.init(url:)))
        }
    }

    func removeSource(_ source: LibrarySource) {
        setSources(sources.filter { $0.id != source.id })
    }

    func resetSources() {
        sourceStore.reset()
        sources = sourceStore.sources
        scan()
    }

    private func setSources(_ newSources: [LibrarySource]) {
        sourceStore.replace(with: newSources)
        sources = sourceStore.sources
        selectedFilter = .all
        selectedMovieID = nil
        scan()
    }

    func generateMissingCovers() async {
        let movies = allMovies.filter { $0.coverURL == nil }
        guard !movies.isEmpty else { return }

        await MainActor.run {
            self.isGeneratingCovers = true
            self.statusText = "Genero copertine offline..."
        }

        for movie in movies {
            let cover = await Task.detached(priority: .utility) {
                CoverGenerator.generateCover(for: movie.fileURL, cacheDirectory: self.coverCacheURL)
            }.value

            if let cover {
                await MainActor.run {
                    self.updateMovie(movie.id) { $0.coverURL = cover }
                }
            }
        }

        await MainActor.run {
            self.isGeneratingCovers = false
            self.statusText = "Videoteca aggiornata"
        }
    }

    func generateMissingTechnicalInfo() async {
        let movies = allMovies.filter { movie in
            movie.technicalInfo == nil || movie.technicalSignature != movie.technicalIdentity
        }
        guard !movies.isEmpty else { return }

        await MainActor.run {
            self.statusText = "Leggo durata, lingue e risoluzione..."
        }

        for (index, movie) in movies.enumerated() {
            if Task.isCancelled { break }

            await MainActor.run {
                self.statusText = "Dettagli video \(index + 1)/\(movies.count): \(movie.title)"
            }

            let technicalInfo = await Task.detached(priority: .utility) {
                VideoProbe.probe(fileURL: movie.fileURL)
            }.value

            guard let technicalInfo else { continue }

            await MainActor.run {
                self.updateMetadata(for: movie.id) { metadata in
                    metadata.technicalInfo = technicalInfo
                    metadata.technicalSignature = movie.technicalIdentity
                    metadata.fileIdentity = movie.fileIdentity
                }
                self.updateMovie(movie.id) {
                    $0.technicalInfo = technicalInfo
                    $0.technicalSignature = movie.technicalIdentity
                }
            }
        }

        await MainActor.run {
            self.statusText = "Dettagli video aggiornati"
        }
    }

    func downloadMissingItalianSubtitles() async {
        let credentials = OpenSubtitlesCredentials(
            apiKey: openSubtitlesApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            username: openSubtitlesUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            password: openSubtitlesPassword
        )
        guard autoDownloadItalianSubtitles, credentials.isConfigured, !isDownloadingSubtitles else { return }

        let retryInterval: TimeInterval = 24 * 60 * 60
        let candidates = allMovies.filter { movie in
            guard FileManager.default.fileExists(atPath: movie.fileURL.path),
                  movie.technicalInfo?.hasSubtitleLanguage(["it", "ita"]) != true else { return false }
            let metadata = metadataStore.metadata(for: movie.id)
            let signature = subtitleLookupSignature(for: movie)
            if metadata.subtitleLookupSignature == signature,
               let failedAt = metadata.subtitleLookupFailedAt,
               Date().timeIntervalSince(failedAt) < retryInterval {
                return false
            }
            return true
        }
        .prefix(12)

        guard !candidates.isEmpty else { return }

        await MainActor.run {
            self.isDownloadingSubtitles = true
            self.statusText = "Cerco sottotitoli italiani..."
        }

        var downloadedCount = 0
        for (index, movie) in candidates.enumerated() {
            if Task.isCancelled { break }

            await MainActor.run {
                self.statusText = "Sottotitoli \(index + 1)/\(candidates.count): \(movie.displayTitle)"
            }

            do {
                if try await SubtitleDownloadService.downloadItalianSubtitleIfNeeded(for: movie, credentials: credentials) != nil {
                    downloadedCount += 1
                    let technicalInfo = await Task.detached(priority: .utility) {
                        VideoProbe.probe(fileURL: movie.fileURL)
                    }.value
                    await MainActor.run {
                        self.updateMetadata(for: movie.id) { metadata in
                            metadata.subtitleLookupSignature = self.subtitleLookupSignature(for: movie)
                            metadata.subtitleLookupFailedAt = nil
                            if let technicalInfo {
                                metadata.technicalInfo = technicalInfo
                                metadata.technicalSignature = movie.technicalIdentity
                            } else {
                                metadata.technicalSignature = nil
                            }
                        }
                        if let technicalInfo {
                            self.updateMovie(movie.id) {
                                $0.technicalInfo = technicalInfo
                                $0.technicalSignature = movie.technicalIdentity
                            }
                        }
                    }
                } else {
                    await MainActor.run {
                        self.markSubtitleLookupFailed(for: movie)
                    }
                }
            } catch {
                await MainActor.run {
                    self.markSubtitleLookupFailed(for: movie)
                }
            }
        }

        await MainActor.run {
            self.isDownloadingSubtitles = false
            self.statusText = downloadedCount == 0
                ? "Sottotitoli aggiornati"
                : "Sottotitoli scaricati per \(downloadedCount) film"
        }
    }

    func openSelectedMovie() {
        guard let item = selectedItem else { return }
        open(item: item)
    }

    func open(item: LibraryItem) {
        if let movie = item.movie {
            PlayerLauncher.open(movie: movie)
        } else if let movie = item.series?.sortedEpisodes.first?.movie {
            PlayerLauncher.open(movie: movie)
        }
    }

    private func itemSorter(_ lhs: LibraryItem, _ rhs: LibraryItem) -> Bool {
        switch sortMode {
        case .title:
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        case .newest:
            return (lhs.displayYear ?? Int.min, lhs.displayTitle) > (rhs.displayYear ?? Int.min, rhs.displayTitle)
        case .oldest:
            return (lhs.displayYear ?? Int.max, lhs.displayTitle) < (rhs.displayYear ?? Int.max, rhs.displayTitle)
        case .director:
            let directorOrder = lhs.displayDirector.localizedCaseInsensitiveCompare(rhs.displayDirector)
            if directorOrder != .orderedSame { return directorOrder == .orderedAscending }
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        case .recentlyModified:
            return lhs.modifiedDate > rhs.modifiedDate
        case .largest:
            return lhs.fileSize > rhs.fileSize
        }
    }

    private func itemMatches(_ item: LibraryItem, filter: LibraryFilter) -> Bool {
        switch filter {
        case .all:
            return true
        case .favorites:
            return item.favorite
        case .unwatched:
            return !item.watched
        case .withoutGenre:
            return item.displayGenres.isEmpty
        case .qualityReview:
            return item.movies.contains { $0.metadataQuality == .review }
        case .weakMetadata:
            return item.movies.contains { !$0.qualityIssues.isEmpty }
        case .missingPoster:
            return item.posterURL == nil
        case .noSubtitles:
            return item.movies.contains { $0.technicalInfo?.subtitleText == "Nessuno" }
        case .italianAudio:
            return item.movies.contains { $0.technicalInfo?.hasAudioLanguage(["ita", "it"]) == true }
        case .multiAudio:
            return item.movies.contains { ($0.technicalInfo?.audioTracks.count ?? 0) > 1 }
        case .fullHD:
            return item.movies.contains { movie in
                guard let info = movie.technicalInfo,
                      let width = info.width,
                      let height = info.height else { return false }
                return (width >= 1900 || height >= 1000) && width < 3840 && height < 2160
            }
        case .fourK:
            return item.movies.contains { movie in
                guard let info = movie.technicalInfo,
                      let width = info.width,
                      let height = info.height else { return false }
                return width >= 3840 || height >= 2160
            }
        case .shortMovies:
            return item.movies.contains { ($0.technicalInfo?.durationSeconds ?? .infinity) <= 90 * 60 }
        case .recentImports:
            let cutoff = Date().addingTimeInterval(-14 * 24 * 60 * 60)
            return item.modifiedDate >= cutoff
        case .genre(let genre):
            return item.displayGenres.contains { $0.caseInsensitiveCompare(genre) == .orderedSame }
        case .director(let director):
            return item.displayDirector.caseInsensitiveCompare(director) == .orderedSame
        case .actor(let actor):
            return item.displayActors.contains { $0.caseInsensitiveCompare(actor) == .orderedSame }
        }
    }

    private func itemMatchesSearch(_ item: LibraryItem, query: String) -> Bool {
        let technicalValues = item.movies.flatMap { movie in
            [
                movie.technicalInfo?.durationText,
                movie.technicalInfo?.resolutionText,
                movie.technicalInfo?.primaryAudioText,
                movie.technicalInfo?.extraAudioText,
                movie.technicalInfo?.subtitleText,
                movie.technicalInfo?.videoCodecText
            ].compactMap { $0 }
        }
        let episodeValues = item.series?.sortedEpisodes.flatMap { episode in
            [episode.code, episode.displayTitle, episode.movie.fileName]
        } ?? []
        let haystack = ([item.displayTitle, item.displaySubtitle, item.displayDirector, item.displayYearText] +
            item.displayActors +
            item.displayGenres +
            technicalValues +
            episodeValues)
            .joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(query)
    }

    private func isSeriesEpisode(_ movie: Movie) -> Bool {
        SeriesDetector.episodeInfo(for: movie) != nil
    }

    private func sorter(_ lhs: Movie, _ rhs: Movie) -> Bool {
        switch sortMode {
        case .title:
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        case .newest:
            return (lhs.displayYear ?? Int.min, lhs.displayTitle) > (rhs.displayYear ?? Int.min, rhs.displayTitle)
        case .oldest:
            return (lhs.displayYear ?? Int.max, lhs.displayTitle) < (rhs.displayYear ?? Int.max, rhs.displayTitle)
        case .director:
            let directorOrder = lhs.displayDirector.localizedCaseInsensitiveCompare(rhs.displayDirector)
            if directorOrder != .orderedSame { return directorOrder == .orderedAscending }
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        case .recentlyModified:
            return lhs.modifiedDate > rhs.modifiedDate
        case .largest:
            return lhs.fileSize > rhs.fileSize
        }
    }

    private func updateMetadata(for id: String, mutate: (inout MovieMetadata) -> Void) {
        var metadata = metadataStore.metadata(for: id)
        mutate(&metadata)
        metadataStore.update(metadata, for: id)
    }

    private func markOnlineLookupFailed(for movie: Movie) {
        let failedAt = Date()
        updateMetadata(for: movie.id) { metadata in
            metadata.onlineLookupSignature = movie.fileSignature
            metadata.onlineLookupFailedAt = failedAt
            metadata.fileIdentity = movie.fileIdentity
        }
        updateMovie(movie.id) {
            $0.onlineLookupSignature = movie.fileSignature
            $0.onlineLookupFailedAt = failedAt
        }
    }

    private func markSubtitleLookupFailed(for movie: Movie) {
        updateMetadata(for: movie.id) { metadata in
            metadata.subtitleLookupSignature = subtitleLookupSignature(for: movie)
            metadata.subtitleLookupFailedAt = Date()
        }
    }

    private func subtitleLookupSignature(for movie: Movie) -> String {
        "it:v1:\(movie.fileIdentity)"
    }

    private func publishScannedMovies(_ movies: [Movie]) {
        allMovies = movies
        rebuildLibraryItems()
        if let selected = selectedMovieID, libraryItems.contains(where: { $0.id == selected }) {
            selectedMovieID = selected
        } else {
            selectedMovieID = libraryItems.first?.id
        }
    }

    private func updateMovie(_ id: String, mutate: (inout Movie) -> Void) {
        guard let index = allMovies.firstIndex(where: { $0.id == id }) else { return }
        mutate(&allMovies[index])
        rebuildLibraryItems()
    }

    private func rebuildLibraryItems() {
        let seriesMetadata = metadataStore.items.compactMapValues { $0.online }
        libraryItems = LibraryItemBuilder.build(from: allMovies, seriesMetadata: seriesMetadata)
    }

    private nonisolated static func cleanGenericContainerTitles(in movies: [Movie], metadataStore: MetadataStore) -> Int {
        var cleanedCount = 0

        for movie in movies {
            var metadata = metadataStore.metadata(for: movie.id)
            let signature = containerTitleCleanSignature(for: movie)
            guard metadata.containerTitleSignature != signature else { continue }

            guard let changed = VideoMetadataCleaner.cleanGenericContainerTitleIfPossible(
                fileURL: movie.fileURL,
                title: movie.displayTitle
            ) else {
                continue
            }
            metadata.containerTitleSignature = signature
            if changed {
                metadata.technicalSignature = nil
                cleanedCount += 1
            }
            metadataStore.update(metadata, for: movie.id)
        }

        return cleanedCount
    }

    private nonisolated static func containerTitleCleanSignature(for movie: Movie) -> String {
        "v3:\(movie.fileIdentity)"
    }

    private nonisolated static func repairIncompatibleOnlineMetadata(in movies: [Movie], metadataStore: MetadataStore) -> Int {
        var repairedCount = 0
        for movie in movies {
            guard let online = movie.onlineMetadata else {
                continue
            }

            var metadata = metadataStore.metadata(for: movie.id)

            if OnlineMetadataService.hasHardIdentityMismatch(online, with: movie) || hasKnownFalseOnlineMetadata(online, for: movie) {
                metadata.online = nil
                metadata.onlineLookupSignature = nil
                metadata.onlineLookupFailedAt = nil
                metadataStore.update(metadata, for: movie.id)
                repairedCount += 1
                continue
            }

            var completed = OnlineMetadataService.completedWithLocalCorrections(online, for: movie)
            if hasIncompleteSavedOnlineMetadata(completed) {
                completed.fetchedAt = nil
            }

            if completed != online || metadata.onlineLookupFailedAt != nil {
                metadata.online = completed
                metadata.onlineLookupFailedAt = nil
                metadataStore.update(metadata, for: movie.id)
                repairedCount += 1
            }
        }
        return repairedCount
    }

    private nonisolated static func hasIncompleteSavedOnlineMetadata(_ online: OnlineMovieMetadata) -> Bool {
        online.title?.nilIfBlank == nil ||
            online.releaseYear == nil ||
            (online.directors ?? []).isEmpty ||
            (online.cast ?? []).isEmpty ||
            (online.genres ?? []).isEmpty ||
            OnlineMetadataService.hasWeakOverview(online.overview)
    }

    private nonisolated static func hasKnownFalseOnlineMetadata(_ online: OnlineMovieMetadata, for movie: Movie) -> Bool {
        let titleKey = ManualMovieCorrections.normalized(movie.title)
        let overviewKey = ManualMovieCorrections.normalized(online.overview ?? "")
        let sourceURL = online.sourceURL ?? ""

        if titleKey == ManualMovieCorrections.normalized("La grande partita"),
           sourceURL.contains("245698") || overviewKey.contains("bobby fischer") {
            return movie.year != 2014 && movie.year != 2015
        }

        return false
    }
}
