import AVFoundation
import AppKit
import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var sources: [LibrarySource] = []
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isScanning = false
    @Published var searchText = ""
    @Published var selectedSourceID: UUID?
    @Published var errorMessage: String?

    private let sourcesKey = "MusicPlayer.sources.v1"
    private let bookmarkPrefix = "MusicPlayer.bookmark."
    private var didLoad = false
    private var scanGeneration = 0
    private var scanTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?

    var filteredTracks: [Track] {
        let sourceFiltered = selectedSourceID.map { id in tracks.filter { $0.sourceID == id } } ?? tracks
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sourceFiltered }
        return sourceFiltered.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.artist.localizedCaseInsensitiveContains(query) ||
            $0.album.localizedCaseInsensitiveContains(query)
        }
    }

    var groups: [LibraryGroup] {
        Dictionary(grouping: filteredTracks) { "\($0.artist)|\($0.album)|\($0.year)" }
            .map { _, tracks in
                let first = tracks[0]
                return LibraryGroup(
                    id: "\(first.artist)-\(first.album)-\(first.year)",
                    artist: first.artist,
                    album: first.album,
                    year: first.year,
                    tracks: tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                )
            }
            .sorted {
                if $0.artist == $1.artist {
                    return $0.album.localizedStandardCompare($1.album) == .orderedAscending
                }
                return $0.artist.localizedStandardCompare($1.artist) == .orderedAscending
            }
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if let data = UserDefaults.standard.data(forKey: sourcesKey),
           let decoded = try? JSONDecoder().decode([LibrarySource].self, from: data) {
            sources = decoded
        }
        rescanInBackground()
    }

    func addLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"

        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let source = LibrarySource(kind: .local, title: url.lastPathComponent, url: url)
            do {
                let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                UserDefaults.standard.set(bookmark, forKey: bookmarkPrefix + source.id.uuidString)
            } catch {
                errorMessage = error.localizedDescription
            }
            sources.append(source)
        }
        persistSources()
        rescanInBackground()
    }

    func addWebDAV(url: URL, username: String, password: String) {
        sources.append(
            LibrarySource(
                kind: .webDAV,
                title: url.host(percentEncoded: false) ?? "WebDAV",
                url: url,
                username: username.isEmpty ? nil : username,
                password: password.isEmpty ? nil : password
            )
        )
        persistSources()
        rescanInBackground()
    }

    func removeSources(at offsets: IndexSet) {
        for index in offsets {
            UserDefaults.standard.removeObject(forKey: bookmarkPrefix + sources[index].id.uuidString)
        }
        sources.remove(atOffsets: offsets)
        persistSources()
        rescanInBackground()
    }

    func removeSource(id sourceID: UUID) {
        guard sources.contains(where: { $0.id == sourceID }) else { return }
        scanTask?.cancel()
        metadataTask?.cancel()
        UserDefaults.standard.removeObject(forKey: bookmarkPrefix + sourceID.uuidString)
        sources.removeAll { $0.id == sourceID }
        tracks.removeAll { $0.sourceID == sourceID }
        if selectedSourceID == sourceID {
            selectedSourceID = nil
        }
        persistSources()
    }

    func clearLibrary() {
        scanTask?.cancel()
        metadataTask?.cancel()
        for source in sources {
            UserDefaults.standard.removeObject(forKey: bookmarkPrefix + source.id.uuidString)
        }
        sources.removeAll()
        tracks.removeAll()
        searchText = ""
        selectedSourceID = nil
        persistSources()
    }

    private func rescanInBackground() {
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        isScanning = true
        scanTask = Task { [weak self] in
            await self?.rescan(generation: generation)
        }
    }

    private func rescan(generation: Int) async {
        let scanSources = sources
        isScanning = true
        metadataTask?.cancel()
        defer {
            if generation == scanGeneration {
                isScanning = false
            }
        }

        var all: [Track] = []
        for source in scanSources {
            guard generation == scanGeneration, !Task.isCancelled else { return }
            do {
                switch source.kind {
                case .local:
                    all.append(contentsOf: await scanLocal(source))
                case .webDAV:
                    all.append(contentsOf: try await scanWebDAVFast(source))
                }
            } catch {
                if !Task.isCancelled, (error as? URLError)?.code != .cancelled {
                    errorMessage = error.localizedDescription
                }
            }
        }
        guard generation == scanGeneration, !Task.isCancelled else { return }
        tracks = all.sorted {
            [$0.artist, $0.album, $0.title].joined(separator: "\u{0}")
                .localizedStandardCompare([$1.artist, $1.album, $1.title].joined(separator: "\u{0}")) == .orderedAscending
        }
    }

    private func persistSources() {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: sourcesKey)
        }
    }

    private nonisolated func scanLocal(_ source: LibrarySource) async -> [Track] {
        await Task.detached(priority: .utility) {
            let bookmarkKey = "MusicPlayer.bookmark." + source.id.uuidString
            var scopedURL = source.url
            var didStartScope = false
            var isStale = false
            if let data = UserDefaults.standard.data(forKey: bookmarkKey),
               let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale) {
                scopedURL = resolved
                didStartScope = resolved.startAccessingSecurityScopedResource()
            }
            defer {
                if didStartScope {
                    scopedURL.stopAccessingSecurityScopedResource()
                }
            }

            guard let enumerator = FileManager.default.enumerator(
                at: scopedURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return []
            }

            var tracks: [Track] = []
            while let item = enumerator.nextObject() {
                guard let url = item as? URL, AudioFile.isSupported(url) else { continue }
                tracks.append(await makeTrack(url: url, source: source))
            }
            return tracks
        }.value
    }

    private nonisolated func scanWebDAVFast(_ source: LibrarySource) async throws -> [Track] {
        let urls = try await WebDAVClient(source: source).listAudioFiles()
        return urls.map { url in makeBareTrack(url: url, source: source) }
    }

    func loadMetadata(for selectedTracks: [Track]) {
        let selectedIDs = Set(selectedTracks.map(\.id))
        let pending = tracks
            .filter { selectedIDs.contains($0.id) && ($0.duration == nil || $0.bitRate == nil || $0.sampleRate == nil) }
            .map { (id: $0.id, url: $0.url, authHeader: $0.authorizationHeader) }
        guard !pending.isEmpty else { return }

        metadataTask?.cancel()
        metadataTask = Task.detached(priority: .background) { [weak self] in
            for item in pending {
                guard !Task.isCancelled else { break }
                let metadata = await AudioMetadataReader.read(url: item.url, authorizationHeader: item.authHeader)
                guard !Task.isCancelled else { break }
                await MainActor.run { [weak self] in
                    self?.updateTrackMetadata(id: item.id, metadata: metadata)
                }
            }
        }
    }

    private func updateTrackMetadata(id: String, metadata: AudioMetadataReader.Metadata) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        let old = tracks[index]
        tracks[index] = Track(
            id: old.id,
            title: old.title,
            artist: old.artist,
            album: old.album,
            year: old.year,
            duration: metadata.duration,
            bitRate: metadata.bitRate,
            sampleRate: metadata.sampleRate,
            url: old.url,
            sourceID: old.sourceID,
            authorizationHeader: old.authorizationHeader
        )
    }
}

private nonisolated func makeBareTrack(url: URL, source: LibrarySource) -> Track {
    let cleanTitle = url.deletingPathExtension().lastPathComponent
    let authorizationHeader: String?
    if let username = source.username, let password = source.password {
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        authorizationHeader = "Basic \(token)"
    } else {
        authorizationHeader = nil
    }

    return Track(
        id: "\(source.id.uuidString)-\(url.absoluteString)",
        title: cleanTitle,
        artist: source.title,
        album: url.deletingLastPathComponent().lastPathComponent.isEmpty ? source.title : url.deletingLastPathComponent().lastPathComponent,
        year: "",
        duration: nil,
        bitRate: nil,
        sampleRate: nil,
        url: url,
        sourceID: source.id,
        authorizationHeader: authorizationHeader
    )
}

private nonisolated func makeTrack(url: URL, source: LibrarySource) async -> Track {
    let cleanTitle = url.deletingPathExtension().lastPathComponent
    let authorizationHeader: String?
    if let username = source.username, let password = source.password {
        let token = Data("\(username):\(password)".utf8).base64EncodedString()
        authorizationHeader = "Basic \(token)"
    } else {
        authorizationHeader = nil
    }
    let metadata = await AudioMetadataReader.read(url: url, authorizationHeader: authorizationHeader)

    return Track(
        id: "\(source.id.uuidString)-\(url.absoluteString)",
        title: cleanTitle,
        artist: source.title,
        album: url.deletingLastPathComponent().lastPathComponent.isEmpty ? source.title : url.deletingLastPathComponent().lastPathComponent,
        year: "",
        duration: metadata.duration,
        bitRate: metadata.bitRate,
        sampleRate: metadata.sampleRate,
        url: url,
        sourceID: source.id,
        authorizationHeader: authorizationHeader
    )
}

private enum AudioMetadataReader {
    struct Metadata {
        let duration: TimeInterval?
        let bitRate: Int?
        let sampleRate: Int?
    }

    static func read(url: URL, authorizationHeader: String?) async -> Metadata {
        let asset: AVURLAsset
        if let authorizationHeader {
            asset = AVURLAsset(
                url: url,
                options: [
                    "AVURLAssetHTTPHeaderFieldsKey": [
                        "Authorization": authorizationHeader
                    ]
                ]
            )
        } else {
            asset = AVURLAsset(url: url)
        }

        do {
            async let durationValue = asset.load(.duration)
            async let audioTracks = asset.loadTracks(withMediaType: .audio)
            let duration = try await durationValue
            let tracks = try await audioTracks
            let audioTrack = tracks.first
            let bitRate = try await audioTrack?.load(.estimatedDataRate)
            let sampleRate = sampleRate(from: audioTrack)
            return Metadata(
                duration: duration.seconds.isFinite ? duration.seconds : nil,
                bitRate: bitRate.map { Int($0) },
                sampleRate: sampleRate
            )
        } catch {
            return Metadata(duration: nil, bitRate: nil, sampleRate: nil)
        }
    }

    private static func sampleRate(from track: AVAssetTrack?) -> Int? {
        guard let formatDescription = track?.formatDescriptions.first else { return nil }
        let audioDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription as! CMAudioFormatDescription)
        guard let sampleRate = audioDescription?.pointee.mSampleRate, sampleRate > 0 else { return nil }
        return Int(sampleRate.rounded())
    }
}
