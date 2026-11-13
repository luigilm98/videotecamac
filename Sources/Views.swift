import AppKit
import SwiftUI

private enum AppStyle {
    static let window = Color(red: 0.035, green: 0.037, blue: 0.043)
    static let sidebar = Color(red: 0.058, green: 0.061, blue: 0.070)
    static let surface = Color(red: 0.074, green: 0.078, blue: 0.090)
    static let surfaceRaised = Color(red: 0.095, green: 0.100, blue: 0.115)
    static let accent = Color(red: 0.88, green: 0.12, blue: 0.18)
    static let separator = Color.white.opacity(0.08)
}

struct ContentView: View {
    @ObservedObject var model: LibraryViewModel

    var body: some View {
        HSplitView {
            SidebarView(model: model)
                .frame(minWidth: 240, idealWidth: 260, maxWidth: 320)

            LibraryGridView(model: model)
                .frame(minWidth: 620)

            DetailView(model: model)
                .frame(minWidth: 340, idealWidth: 390, maxWidth: 460)
        }
        .background(AppStyle.window)
        .onAppear {
            model.startInitialScanIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSelectedMovie)) { _ in
            model.openSelectedMovie()
        }
        .sheet(isPresented: $model.showingSources) {
            SourceSettingsView(model: model)
                .frame(width: 820, height: 790)
        }
    }
}

struct SidebarView: View {
    @ObservedObject var model: LibraryViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "play.rectangle.on.rectangle.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(AppStyle.accent)

                        Text("Videoteca")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                    }

                    Text(model.countText)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button {
                        model.showingSources = true
                    } label: {
                        Label("Impostazioni", systemImage: "gearshape")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(ModernButtonStyle())
                    .help("Apri sorgenti, metadati e sottotitoli")
                }
                .padding(.top, 20)

                VStack(alignment: .leading, spacing: 6) {
                    SidebarButton(title: "Tutto il catalogo", systemImage: "rectangle.stack", filter: .all, model: model)
                    SidebarButton(title: "Film", systemImage: "film", filter: .movies, model: model)
                    SidebarButton(title: "Serie TV", systemImage: "tv", filter: .series, model: model)
                    SidebarButton(title: "Preferiti", systemImage: "star", filter: .favorites, model: model)
                    SidebarButton(title: "Da vedere", systemImage: "play.circle", filter: .unwatched, model: model)
                }

                SidebarSection(title: "Tecnica") {
                    SidebarButton(title: "Audio italiano", systemImage: "speaker.wave.2", filter: .italianAudio, model: model)
                    SidebarButton(title: "Multi-audio", systemImage: "waveform", filter: .multiAudio, model: model)
                    SidebarButton(title: "Senza sottotitoli", systemImage: "captions.bubble", filter: .noSubtitles, model: model)
                    SidebarButton(title: "1080p", systemImage: "rectangle.inset.filled", filter: .fullHD, model: model)
                    SidebarButton(title: "4K", systemImage: "tv", filter: .fourK, model: model)
                    SidebarButton(title: "Sotto 90 min", systemImage: "clock", filter: .shortMovies, model: model)
                }

                SidebarSection(title: "Generi") {
                    CatalogFacetList(entries: model.genreFacets, icon: "tag", filter: LibraryFilter.genre, model: model)
                    SidebarButton(title: "Senza genere", systemImage: "tag.slash", filter: .withoutGenre, model: model)
                }

                SidebarSection(title: "Registi") {
                    CatalogFacetList(entries: model.directorFacets, icon: "person.crop.rectangle", filter: LibraryFilter.director, model: model)
                }

                SidebarSection(title: "Attori") {
                    CatalogFacetList(entries: model.actorFacets, icon: "person.2", filter: LibraryFilter.actor, model: model)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(AppStyle.sidebar)
    }
}

struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                content
            }
            .padding(.top, 6)
        } label: {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
    }
}

struct CatalogFacetList: View {
    let entries: [CatalogFacet]
    let icon: String
    let filter: (String) -> LibraryFilter
    @ObservedObject var model: LibraryViewModel
    @State private var query = ""
    @State private var expanded = false

    var body: some View {
        let search = CatalogClassification.personKey(query)
        let matches = search.isEmpty ? entries : entries.filter { $0.id.contains(search) }
        let visible = search.isEmpty && !expanded ? Array(matches.prefix(8)) : matches

        TextField("Cerca nell’elenco", text: $query)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Cerca nell’elenco")
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(visible) { entry in
                SidebarButton(title: entry.name, systemImage: icon, filter: filter(entry.name), model: model, count: entry.count)
            }
        }
        if matches.isEmpty {
            Text("Nessun risultato")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if search.isEmpty && entries.count > 8 {
            Button(expanded ? "Mostra meno" : "Mostra tutti (\(entries.count))") {
                expanded.toggle()
            }
            .buttonStyle(.plain)
            .font(.caption)
            .padding(.leading, 10)
        }
    }
}

struct SidebarButton: View {
    let title: String
    let systemImage: String
    let filter: LibraryFilter
    @ObservedObject var model: LibraryViewModel

    var count: Int? = nil

    var isSelected: Bool { model.selectedFilter == filter }

    var body: some View {
        Button {
            model.selectedFilter = filter
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                    .lineLimit(1)
                if let count {
                    Spacer(minLength: 4)
                    Text(count, format: .number)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .background(isSelected ? AppStyle.accent.opacity(0.18) : Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? AppStyle.accent.opacity(0.35) : Color.clear, lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .white : Color.secondary)
    }
}

struct LibraryGridView: View {
    @ObservedObject var model: LibraryViewModel

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: CGFloat(model.thumbnailWidth),
                    maximum: CGFloat(model.thumbnailWidth + 44)
                ),
                spacing: 18
            )
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                if model.filteredItems.isEmpty && !model.isScanning {
                    VStack(spacing: 14) {
                        Image(systemName: "externaldrive.badge.plus")
                            .font(.system(size: 42, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("Nessun film trovato")
                            .font(.title3)
                            .fontWeight(.semibold)
                        Text("Scegli Documenti/film, una cartella video o un hard disk esterno.")
                            .foregroundStyle(.secondary)
                        Button {
                            model.showingSources = true
                        } label: {
                            Label("Scegli cartella / hard disk", systemImage: "folder")
                        }
                        .buttonStyle(ModernButtonStyle(prominent: true))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else {
                    LazyVGrid(columns: columns, spacing: 22) {
                        ForEach(model.filteredItems) { item in
                            LibraryItemCard(item: item, isSelected: model.selectedMovieID == item.id)
                                .onTapGesture {
                                    model.selectedMovieID = item.id
                                }
                                .onTapGesture(count: 2) {
                                    model.open(item: item)
                                }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                }
            }
            .background(AppStyle.window)
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.selectedFilter.title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                    HStack(spacing: 8) {
                        StatusBadge(text: model.countText, systemImage: "film")
                        StatusBadge(text: sourceSummary, systemImage: "folder")
                        StatusBadge(text: model.statusText, systemImage: "checkmark.circle")
                    }
                }

                Spacer()

                if model.isScanning || model.isGeneratingCovers || model.isFetchingOnlineMetadata || model.isEnrichingAllMetadata || model.isDownloadingSubtitles {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    model.showingSources = true
                } label: {
                    Label("Impostazioni", systemImage: "gearshape.fill")
                }
                .buttonStyle(ModernButtonStyle(prominent: true))
                .help("Apri sorgenti, metadati e sottotitoli")

                Button {
                    model.scan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle())
                .help("Riscansiona")
            }

            HStack(spacing: 12) {
                TextField("Cerca titolo, serie, episodio, regista, attore, anno o genere", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Ordina", selection: $model.sortMode) {
                    ForEach(LibrarySortMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .frame(width: 180)

                HStack(spacing: 8) {
                    Image(systemName: "rectangle.grid.2x2")
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { model.thumbnailWidth },
                            set: { model.setThumbnailWidth($0) }
                        ),
                        in: 130...270,
                        step: 10
                    )
                    .frame(width: 170)
                    Image(systemName: "rectangle.grid.1x2")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(AppStyle.surface)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppStyle.separator)
                .frame(height: 1)
        }
    }

    private var sourceSummary: String {
        model.sources.count == 1 ? "1 sorgente" : "\(model.sources.count) sorgenti"
    }
}

struct StatusBadge: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .foregroundStyle(.secondary)
    }
}

struct LibraryItemCard: View {
    let item: LibraryItem
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            PosterView(url: item.posterURL, cacheKey: item.posterCacheKey, title: item.displayTitle)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    if item.isSeries {
                        Text("Serie")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.62))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if item.favorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .padding(8)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.white : Color.white.opacity(0.10), lineWidth: isSelected ? 3 : 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(item.displayTitle)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(item.displaySubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if item.isSeries {
                Text("Apri la scheda per scegliere la puntata")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else if let info = item.movie?.technicalInfo {
                Text([info.resolutionClass, info.primaryAudioText].joined(separator: " - "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(isHovered || isSelected ? 0.28 : 0.10), radius: isHovered || isSelected ? 12 : 4, x: 0, y: 4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? AppStyle.surfaceRaised : (isHovered ? AppStyle.surface : Color.clear))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? AppStyle.accent.opacity(0.55) : Color.white.opacity(isHovered ? 0.10 : 0.0), lineWidth: 1)
            }
    }
}

struct MovieCard: View {
    let movie: Movie
    let isSelected: Bool
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            PosterView(url: movie.posterURL, cacheKey: movie.posterCacheKey, title: movie.displayTitle)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay(alignment: .topTrailing) {
                    if movie.favorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .padding(8)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.white : Color.white.opacity(0.10), lineWidth: isSelected ? 3 : 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(movie.displayTitle)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text([movie.displayYearText, movie.displayDirector].joined(separator: " - "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let info = movie.technicalInfo {
                Text([info.resolutionClass, info.primaryAudioText].joined(separator: " - "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(isHovered || isSelected ? 0.28 : 0.10), radius: isHovered || isSelected ? 12 : 4, x: 0, y: 4)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? AppStyle.surfaceRaised : (isHovered ? AppStyle.surface : Color.clear))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? AppStyle.accent.opacity(0.55) : Color.white.opacity(isHovered ? 0.10 : 0.0), lineWidth: 1)
            }
    }
}

struct PosterView: View {
    let url: URL?
    let cacheKey: String
    let title: String

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let url,
                   let data = try? Data(contentsOf: url),
                   let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                } else {
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.19, blue: 0.22),
                            Color(red: 0.08, green: 0.09, blue: 0.11)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    VStack(spacing: 14) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 42, weight: .light))
                            .foregroundStyle(.white.opacity(0.75))
                        Text(title)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                            .padding(.horizontal, 12)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .id(cacheKey)
        .clipped()
    }
}

struct DetailView: View {
    @ObservedObject var model: LibraryViewModel
    @State private var zoomedPosterMovie: Movie?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item = model.selectedItem {
                ScrollView {
                    if let series = item.series {
                        seriesDetail(series)
                            .padding(20)
                    } else if let movie = item.movie {
                        movieDetail(movie)
                            .padding(20)
                    }
                }
            } else {
                ContentUnavailableView("Nessun film selezionato", systemImage: "film")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppStyle.surface)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(AppStyle.separator)
                .frame(width: 1)
        }
        .sheet(item: $zoomedPosterMovie) { movie in
            PosterZoomView(movie: movie)
                .frame(minWidth: 560, idealWidth: 720, minHeight: 760, idealHeight: 900)
        }
    }

    private func movieDetail(_ movie: Movie) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(movie.displayTitle)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .fontWeight(.bold)
                Text(movie.displayYearText + " - " + movie.displayDirector)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            descriptionBlock(for: movie)

            HStack(spacing: 10) {
                Button {
                    PlayerLauncher.open(movie: movie)
                } label: {
                    Label("Apri con VLC", systemImage: "play.fill")
                }
                .buttonStyle(ModernButtonStyle(prominent: true))
                .keyboardShortcut(.return, modifiers: [])

                Button {
                    PlayerLauncher.reveal(movie: movie)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(IconButtonStyle())
                .help("Mostra nel Finder")
            }

            ZStack(alignment: .topTrailing) {
                PosterView(url: movie.posterURL, cacheKey: movie.posterCacheKey, title: movie.displayTitle)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 8)

                Button {
                    zoomedPosterMovie = movie
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(IconButtonStyle())
                .padding(10)
                .help("Ingrandisci locandina")
            }

            Divider()
            factsBlock(for: movie)
            if !movie.extras.isEmpty {
                Divider()
                extrasBlock(for: movie)
            }
            Divider()
            toggles(for: movie)
            metadataEditor(for: movie)
            Divider()
            infoBlock(for: movie)
        }
    }

    private func seriesDetail(_ series: SeriesGroup) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(series.displayTitle)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .fontWeight(.bold)
                    Text("Serie")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(AppStyle.accent.opacity(0.22))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Text([series.subtitle, series.displayYearText].joined(separator: " - "))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let overview = series.overview {
                Text(overview)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text("Serie raggruppata automaticamente dalla struttura delle cartelle e dai nomi episodio.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let representative = series.representativeMovie {
                ZStack(alignment: .topTrailing) {
                    PosterView(url: series.posterURL, cacheKey: series.posterCacheKey, title: series.title)
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 8)

                    Button {
                        zoomedPosterMovie = representative
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                    }
                    .buttonStyle(IconButtonStyle())
                    .padding(10)
                    .help("Ingrandisci locandina")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Stagioni")
                    .font(.headline)

                ForEach(series.seasons, id: \.self) { season in
                    DisclosureGroup {
                        VStack(spacing: 8) {
                            ForEach(series.sortedEpisodes.filter { $0.seasonNumber == season }) { episode in
                                EpisodeRow(episode: episode)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text("Stagione \(season)")
                            .font(.headline)
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            if !series.displayGenres.isEmpty {
                Divider()
                Text("Generi")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayout(items: series.displayGenres)
            }

            if let source = series.onlineMetadata?.source {
                if let sourceURL = series.onlineMetadata?.sourceURL, let url = URL(string: sourceURL) {
                    Link(destination: url) {
                        Label(source, systemImage: "link")
                    }
                    .buttonStyle(ModernButtonStyle())
                } else {
                    MetadataRow(label: "Fonte", value: source)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("File")
                    .font(.headline)
                Text(series.sizeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(series.episodes.count) file video raggruppati")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func toggles(for movie: Movie) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Preferito", isOn: Binding(
                get: { model.selectedMovie?.favorite ?? movie.favorite },
                set: { model.setFavorite($0, for: movie) }
            ))

            Toggle("Visto", isOn: Binding(
                get: { model.selectedMovie?.watched ?? movie.watched },
                set: { model.setWatched($0, for: movie) }
            ))
        }
    }

    private func metadataEditor(for movie: Movie) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Generi separati da virgola", text: Binding(
                    get: { model.selectedMovie?.userGenres.joined(separator: ", ") ?? movie.userGenres.joined(separator: ", ") },
                    set: { model.updateGenres(for: movie, text: $0) }
                ))
                .textFieldStyle(.roundedBorder)

                TextEditor(text: Binding(
                    get: { model.selectedMovie?.notes ?? movie.notes },
                    set: { model.updateNotes(for: movie, text: $0) }
                ))
                .frame(height: 90)
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.top, 8)
        } label: {
            Label("Modifiche locali", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
    }

    private func descriptionBlock(for movie: Movie) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            technicalBlock(for: movie)

            VStack(alignment: .leading, spacing: 10) {
                Text("Descrizione")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let overview = movie.overview {
                    Text(overview)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text("Descrizione in ricerca automatica.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func technicalBlock(for movie: Movie) -> some View {
        Group {
            if let info = movie.technicalInfo {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 128), spacing: 8, alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    TechnicalPill(systemImage: "clock", label: "Durata", value: info.durationText)
                    TechnicalPill(systemImage: "rectangle.inset.filled", label: "Risoluzione", value: info.resolutionText)
                    TechnicalPill(systemImage: "speaker.wave.2", label: "Lingua", value: info.primaryAudioText)
                    TechnicalPill(systemImage: "waveform", label: "Altre lingue", value: info.extraAudioText)
                    TechnicalPill(systemImage: "captions.bubble", label: "Sottotitoli", value: info.subtitleText)
                }
            } else {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Analisi tecnica del file in corso.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func factsBlock(for movie: Movie) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MetadataRow(label: "Titolo", value: movie.displayTitle)
            MetadataRow(label: "Anno", value: movie.displayYearText)
            MetadataRow(label: "Regia", value: movie.displayDirector)

            if !movie.displayGenres.isEmpty {
                Text("Generi")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayout(items: movie.displayGenres)
            }

            if !movie.displayActors.isEmpty {
                Text("Cast")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                FlowLayout(items: Array(movie.displayActors.prefix(12)))
            }

            if let source = movie.onlineMetadata?.source {
                if let sourceURL = movie.onlineMetadata?.sourceURL, let url = URL(string: sourceURL) {
                    Link(destination: url) {
                        Label(source, systemImage: "link")
                    }
                    .buttonStyle(ModernButtonStyle())
                } else {
                    MetadataRow(label: "Fonte", value: source)
                }
            }
        }
    }

    private func extrasBlock(for movie: Movie) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Versioni ed extra")
                .font(.headline)

            ForEach(movie.extras) { extra in
                ExtraRow(extra: extra)
            }
        }
    }

    private func infoBlock(for movie: Movie) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File")
                .font(.headline)
            Text(movie.fileName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text(movie.sizeText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(movie.fileURL.path)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }
}

struct ExtraRow: View {
    let extra: MovieExtra

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(extra.kind)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(extra.title)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Text([extra.fileName, extra.sizeText].joined(separator: " - "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                PlayerLauncher.open(url: extra.fileURL)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(IconButtonStyle())
            .help("Apri extra con VLC")

            Button {
                PlayerLauncher.reveal(url: extra.fileURL)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(IconButtonStyle())
            .help("Mostra extra nel Finder")
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct EpisodeRow: View {
    let episode: SeriesEpisode

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(episode.code)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(episode.displayTitle)
                    .font(.callout)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Text(episode.movie.fileName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                PlayerLauncher.open(movie: episode.movie)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(IconButtonStyle())
            .help("Apri episodio con VLC")

            Button {
                PlayerLauncher.reveal(movie: episode.movie)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(IconButtonStyle())
            .help("Mostra episodio nel Finder")
        }
        .padding(10)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct PosterZoomView: View {
    let movie: Movie
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: Double = 1.0

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(movie.displayTitle)
                        .font(.title2)
                        .fontWeight(.bold)
                        .lineLimit(2)
                    Text(movie.displayYearText + " - " + movie.displayDirector)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle())
                .help("Chiudi")
            }

            HStack(spacing: 10) {
                Button {
                    zoom = max(1.0, zoom - 0.25)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(IconButtonStyle())
                .help("Riduci zoom")

                Slider(value: $zoom, in: 1.0...3.0, step: 0.05)
                    .frame(maxWidth: 260)

                Button {
                    zoom = min(3.0, zoom + 0.25)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(IconButtonStyle())
                .help("Aumenta zoom")

                Button {
                    zoom = 1.0
                } label: {
                    Text("\(Int(zoom * 100))%")
                        .frame(minWidth: 46)
                }
                .buttonStyle(ModernButtonStyle())
                .help("Reimposta zoom")
            }

            if let url = movie.posterURL,
               let data = try? Data(contentsOf: url),
               let image = NSImage(data: data) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: zoomedWidth(for: image), height: zoomedHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 10)
                        .padding(24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PosterView(url: movie.posterURL, cacheKey: movie.posterCacheKey, title: movie.displayTitle)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.45), radius: 18, x: 0, y: 10)
            }
        }
        .padding(22)
        .background(Color(red: 0.035, green: 0.038, blue: 0.045))
    }

    private var zoomedHeight: CGFloat {
        CGFloat(680 * zoom)
    }

    private func zoomedWidth(for image: NSImage) -> CGFloat {
        guard image.size.height > 0 else { return CGFloat(460 * zoom) }
        return zoomedHeight * image.size.width / image.size.height
    }
}

struct SourceSettingsView: View {
    @ObservedObject var model: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Impostazioni")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Cartella, hard disk, metadati online e sottotitoli.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Chiudi") {
                    dismiss()
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Origine dei film")
                            .font(.headline)
                        Spacer()
                    }

                    Text("Le sorgenti selezionate vengono scansionate all'apertura. I nuovi file sfusi o dentro cartelle col titolo vengono catalogati automaticamente senza sovrascrivere file esistenti.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button {
                            model.replaceWithFolderSource()
                        } label: {
                            Label("Scegli cartella principale", systemImage: "folder")
                        }
                        .buttonStyle(ModernButtonStyle(prominent: true))

                        Button {
                            model.chooseExternalDriveSource()
                        } label: {
                            Label("Aggiungi hard disk", systemImage: "externaldrive")
                        }
                        .buttonStyle(ModernButtonStyle())

                        Button {
                            model.chooseFolderSource()
                        } label: {
                            Label("Aggiungi cartella", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(ModernButtonStyle())
                    }

                    HStack {
                        Button {
                            model.chooseFileSources()
                        } label: {
                            Label("Aggiungi file singoli", systemImage: "film.badge.plus")
                        }
                        .buttonStyle(ModernButtonStyle())

                        Button {
                            model.resetSources()
                        } label: {
                            Label("Ripristina Documenti/film", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(ModernButtonStyle())
                    }
                }
            }

            List {
                ForEach(model.sources, id: \.path) { source in
                    SourceRow(source: source, model: model)
                }
            }
            .frame(minHeight: 190)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Metadati automatici")
                            .font(.headline)
                        Spacer()
                        if model.isEnrichingAllMetadata {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    HStack(spacing: 10) {
                        SecureField("Token TMDb gratuito opzionale", text: $model.tmdbToken)
                            .textFieldStyle(.roundedBorder)

                        Button {
                            model.saveOnlineSettings()
                        } label: {
                            Label("Salva", systemImage: "checkmark")
                        }
                        .buttonStyle(ModernButtonStyle())
                    }

                    Text("All'apertura l'app prova automaticamente a completare schede e copertine mancanti usando fonti gratuite. Il token TMDb resta opzionale.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Sottotitoli automatici")
                            .font(.headline)
                        Spacer()
                        if model.isDownloadingSubtitles {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    HStack(spacing: 10) {
                        SecureField("Api-Key OpenSubtitles", text: $model.openSubtitlesApiKey)
                            .textFieldStyle(.roundedBorder)
                        TextField("Username", text: $model.openSubtitlesUsername)
                            .textFieldStyle(.roundedBorder)
                        SecureField("Password", text: $model.openSubtitlesPassword)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Button {
                            model.saveOnlineSettings()
                        } label: {
                            Label("Salva sottotitoli", systemImage: "checkmark")
                        }
                        .buttonStyle(ModernButtonStyle())

                        Button {
                            Task {
                                await model.downloadMissingItalianSubtitles()
                            }
                        } label: {
                            Label("Cerca ora", systemImage: "captions.bubble")
                        }
                        .buttonStyle(ModernButtonStyle())
                    }

                    Text("I sottotitoli vengono salvati come file esterni .it.srt accanto al film. VLC li carica automaticamente. Il video originale non viene riscritto.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()

                Button {
                    model.scan()
                    dismiss()
                } label: {
                    Label("Scansiona ora", systemImage: "arrow.clockwise")
                }
                .buttonStyle(ModernButtonStyle(prominent: true))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}

struct SourceRow: View {
    let source: LibrarySource
    @ObservedObject var model: LibraryViewModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.isDirectory ? "folder" : "film")
                .foregroundStyle(source.exists ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                    .fontWeight(.semibold)
                Text(source.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(source.exists ? source.kindText : "Non trovato")
                .font(.caption)
                .foregroundStyle(source.exists ? Color.secondary : Color.orange)
            Button {
                model.removeSource(source)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .help("Rimuovi sorgente")
        }
        .padding(.vertical, 5)
    }
}

struct MetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

struct TechnicalPill: View {
    let systemImage: String
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppStyle.accent)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct FlowLayout: View {
    let items: [String]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 88), spacing: 6, alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.white.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

struct ModernButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var prominent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.white.opacity(0.92))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(background(isPressed: configuration.isPressed))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(prominent ? 0.18 : 0.12), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.45)
    }

    private func background(isPressed: Bool) -> some View {
        let opacity = isPressed ? 0.78 : 1.0
        return Group {
            if prominent {
                AppStyle.accent.opacity(opacity)
            } else {
                Color.white.opacity(isPressed ? 0.17 : 0.10)
            }
        }
    }
}

struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.92))
            .frame(width: 34, height: 32)
            .background(Color.white.opacity(configuration.isPressed ? 0.18 : 0.10))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(isEnabled ? 1 : 0.45)
    }
}
