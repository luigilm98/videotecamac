# VideotecaMac

VideotecaMac is a 100% vibecoded native macOS SwiftUI application for managing an offline personal film and TV library stored on local disks or removable drives. It scans video folders, normalizes noisy release names, preserves local metadata across file moves, enriches titles from public online sources, generates or reuses poster artwork, groups TV episodes, and opens media with VLC or the system default player.

From a software-engineering perspective, this repository is a compact case study in local-first personal information management: most value comes from reconciling unreliable filesystem data, user corrections, online metadata, technical media probes, and safe physical file organization.

## Product Scope

The application manages local media rather than streaming content. It does not upload video files; enrichment requests disclose title/search metadata to external services. Scanning can initiate network requests, and automatic organization is enabled by default in `OnlineSettings`.

Main user-facing capabilities include:

- scan multiple user-configurable library roots
- detect video files with extensions such as `mkv`, `mp4`, `avi`, `mov`, `m4v`, `mpg`, and `mpeg`
- parse titles, years, directors, cast hints, and release-noise markers from filenames and folder names
- detect TV episodes from season folders, `SxxExx`, `1x02`, and numbered-episode conventions
- browse films and TV series separately, with searchable genre, director, and cast indexes
- preserve metadata when files are renamed or moved
- generate covers with `ffmpeg` or reuse sidecar images such as `cover.jpg`, `poster.png`, or `<movie-name>.jpg`
- enrich movie metadata from TMDb, public TMDb pages, Wikipedia, Wikidata, Apple Search, and web-poster fallbacks
- enrich TV-series metadata from TMDb TV API or public TMDb TV pages
- optionally download Italian subtitles from OpenSubtitles
- organize movie files into canonical director/title/year folders while moving relevant sidecars
- open files in VLC when available and reveal files in Finder

## Architecture

The codebase is intentionally small and mostly organized as Swift files in `Sources/`.

| Module | Responsibility |
| --- | --- |
| `VideotecaApp.swift` | SwiftUI application entry point. |
| `Views.swift` | User interface, panels, controls, cards, detail views, and library interaction surfaces. |
| `LibraryViewModel.swift` | Main `@MainActor` orchestration layer for scanning, filtering, sorting, metadata refresh, organization, subtitle download, and UI state. |
| `CatalogClassification.swift` | Normalizes genre labels and person credits and indexes catalog filters by title. |
| `Models.swift` | Core domain model: movies, metadata, online metadata, technical tracks, series episodes, series groups, filters, and sort modes. |
| `MovieScanner.swift` | Filesystem traversal, video discovery, release-name parsing, sidecar/extras association, identity generation, and metadata adoption hooks. |
| `MetadataStore.swift` | JSON persistence for per-file metadata and migration/adoption when file identity survives path changes. |
| `LibrarySource.swift` | Source-root persistence and normalization. |
| `OnlineSettings.swift` | Local settings for TMDb, OpenSubtitles, auto-organization, thumbnail width, and subtitle behavior. |
| `OnlineMetadataService.swift` | Multi-source movie enrichment, candidate scoring, poster scoring, title compatibility checks, and local correction integration. |
| `SeriesDetector.swift` | Heuristics for identifying episodic media and extracting series title, season number, episode number, and episode title. |
| `SeriesOnlineMetadataService.swift` | TV-series metadata enrichment from TMDb API and public TMDb pages. |
| `VideoProbe.swift` | `ffprobe` integration for duration, resolution, codecs, audio tracks, embedded subtitles, and external subtitle sidecars. |
| `CoverGenerator.swift` | Sidecar cover detection and `ffmpeg` thumbnail generation at multiple offsets. |
| `MovieOrganizer.swift` | Canonical physical organization, file moves, sidecar moves, cached-cover relocation, and JSONL organization logging. |
| `SubtitleDownloadService.swift` | OpenSubtitles login, hash/query search, scoring, SRT normalization, and sidecar writing. |
| `ManualMovieCorrections.swift` | Curated correction table for difficult titles and noisy filenames. |
| `VideoMetadataCleaner.swift` | Cleanup of generic container metadata titles when possible. |
| `PlayerLauncher.swift` | VLC/system-player launch and Finder reveal integration. |

## Data Model

`Movie` combines file-derived identity with user metadata and online enrichment. Important design choices:

- File identity uses file size and modification date so metadata can be adopted after moves or renames. This is a heuristic fingerprint, not a collision-resistant content hash.
- User metadata and online metadata are kept separate. The app can show online values while preserving user edits.
- Metadata quality is explicit: titles can be local, parsed, manually corrected, or enriched.
- Technical metadata is optional and refreshed when the technical signature changes.
- Series are represented as `SeriesEpisode` and grouped into `SeriesGroup` values by `LibraryItemBuilder`.

The app stores local JSON files under macOS Application Support, typically in a `Videoteca Offline` folder:

- `metadata.json` for per-file metadata
- `sources.json` for library roots
- `online-settings.json` for optional service credentials/settings
- cover-cache directory for generated thumbnails
- artwork directory for downloaded posters
- `organization-log.jsonl` for physical move attempts

Library state normally lives outside the checkout. The tracked ignore rules cover build and macOS artifacts; they do not guarantee exclusion of arbitrary private metadata copied into the repository.

## Scan Pipeline

The main scan pipeline in `LibraryViewModel` follows this shape:

1. Load configured source roots.
2. Traverse source folders while skipping hidden entries, symlinks, sample/trailer/extras directories, and non-video files.
3. Parse local filenames and folder names into candidate movie metadata.
4. Attach extras to the best matching main movie by path/title/year scoring.
5. Adopt legacy metadata when a file identity matches a previous file at a different path.
6. Prune metadata for files no longer present under mounted source roots.
7. Build the mixed movie/series library view.
8. Optionally organize movies into canonical folder/file names.
9. Probe technical metadata with `ffprobe`.
10. Generate missing covers with `ffmpeg`.
11. Enrich missing or weak online metadata.
12. Optionally download Italian subtitles when OpenSubtitles credentials are configured.

This sequence is designed to tolerate partially mounted drives and incomplete online access. The UI can still show local data if enrichment fails.

## Online Metadata Strategy

The movie metadata service merges several sources:

- authenticated TMDb API when a token is configured
- public TMDb pages as a token-free fallback
- Wikipedia summaries and page text
- Wikidata SPARQL data
- Apple Search API
- poster-like images found through web metadata

Candidates are filtered by normalized title compatibility, year proximity, chapter/part markers, and poster aspect ratio. Overviews and posters are scored so weak or truncated data does not override better sources. Manual corrections can fill gaps for known difficult titles.

For TV series, `SeriesOnlineMetadataService` first uses TMDb TV API when available, then falls back to public TMDb TV pages.

## Physical Organization

`MovieOrganizer` can move movie files into a canonical structure:

```text
<library-root>/<Director>/<Director> - <Title> (<Year>) - <Actor 1>, <Actor 2>.<ext>
```

When a file moves, the organizer also attempts to move sidecars with matching basenames, including subtitles, posters, and `.nfo` files. Cached covers are relocated to match the new path-derived cache key, and each planned/moved/failed action is appended to a JSONL log.

The organizer intentionally skips detected TV episodes, trailers, samples, featurettes, and extras-style paths. It also avoids overwriting existing files by generating unique destination names.

## External Dependencies

Runtime integrations are optional but improve the experience:

- `ffmpeg` for thumbnail extraction
- `ffprobe` for media technical metadata
- `mkvpropedit` from MKVToolNix for in-place container-title edits
- VLC at `/Applications/VLC.app` for preferred playback
- TMDb token for higher-quality movie and TV metadata
- OpenSubtitles API key, username, and password for automatic Italian subtitles

If `ffmpeg` or `ffprobe` is not available, the app keeps working with reduced cover/technical metadata functionality.

## Build Notes

The repository contains the Swift source files and assets, but no generated build products. A local macOS build can be assembled with an Xcode project or a lightweight Swift build wrapper that includes the files under `Sources/` and the icon assets under `Assets/`.

Generated app bundles, derived data, AppleDouble files, `.DS_Store`, local caches, and media-library data should remain outside Git.

## Privacy

Online service credentials are stored in plaintext in `online-settings.json` under Application Support. The implementation does not use Keychain. Local settings, metadata, and organization logs can reveal credentials, viewing preferences, and filesystem paths; exclude them from shared debugging artifacts.

The repository should not contain private media files, generated covers, downloaded artwork, subtitle downloads, or local metadata databases.

## Research Notes

VideotecaMac illustrates several engineering problems that appear simple at UI level but are interesting in practice:

- robust identity tracking for mutable filesystem objects
- metadata reconciliation across local heuristics, user edits, and multiple online sources
- deterministic parsing of noisy, community-style release filenames
- human-correction tables as lightweight domain knowledge
- offline-first UX with opportunistic network enrichment
- safe file organization with sidecar migration and audit logging
- quality scoring for incomplete external metadata

## Known Limits And Reproducibility

- There is no tracked Xcode project, Swift package manifest, automated test target, or CI configuration. Native compilation was not verified on the Windows host used for this documentation update; the minimum supported macOS/Swift versions are not declared.
- Metadata is stored in path-keyed JSON; there is no multi-process conflict protocol. File size/modification-time identity can collide or change after editing.
- Metadata providers are merged by hand-written rules. HTML scraping, title token overlap, and curated corrections can fail on remakes, translations, and ambiguous titles. Some errors are suppressed with `try?`.
- File organization is a sequence of filesystem operations, not a transaction. Main-file moves, sidecar moves, metadata writes, and logs can succeed independently. Matching-basename sidecars are moved, but language-suffixed sidecars are not universally covered.
- Organization logging is not an automatic undo system. Empty-folder cleanup and orphan-folder relocation currently return immediately without doing work.
- Container-title cleaning can modify MKV/WebM files in place. The implementation tries to preserve the original modification date. This is an additional side effect beyond renaming.
- Automatic organization defaults to enabled. For experiments, use copied media under disposable source roots and inspect settings before the initial scan.

## Suggested Experiments

| Research question | Evaluation |
| --- | --- |
| How robust is filename parsing? | Labeled filename/folder fixtures; measure title/year and episode-detection accuracy by naming convention. |
| Does multi-source enrichment improve identity accuracy? | Compare local-only and provider ablations; measure wrong-title rate separately from metadata completeness. |
| Does metadata survive file changes? | Rename/move, unmount/remount, same-size timestamp collisions, and subtitle-sidecar mutations; check preserved edits. |
| Is organization recoverable? | Inject failures between filesystem steps; compare actual files, metadata, and JSONL log after restart. |
| What dominates scan latency? | Report cold/warm cache time, network calls, external-tool processes, and UI responsiveness by library size. |

Use synthetic filenames and redistributable test clips, separate curated-correction titles from held-out titles, and record commit, macOS/Swift versions, external-tool versions, cache state, and provider responses. These are proposed evaluations, not reported benchmark results. Verify code licensing and external-service/media permissions before redistributing a research artifact.

## Istruzioni per agenti AI (Codex e Copilot)

Le modifiche proposte da Codex, Copilot e altri agenti devono seguire [AGENTS.md](AGENTS.md): semplicità, modello mentale dell'architettura, test di integrazione, reversibilità delle scelte, riduzione del debito tecnico, comunicazione e tutela dei dati privati. GitHub Copilot usa inoltre [.github/copilot-instructions.md](.github/copilot-instructions.md), che rinvia alla guida comune senza duplicarla.
