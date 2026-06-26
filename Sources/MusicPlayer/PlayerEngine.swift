import AVFoundation
import CoreAudio
import Foundation

private struct StoredPlaybackState: Codable {
    var currentTrackID: String
    var queueIDs: [String]
    var isShuffleEnabled: Bool
    var isRepeatEnabled: Bool
}

@MainActor
final class PlaybackClock: ObservableObject {
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var progress: Double = 0

    var elapsedText: String {
        let total = max(0, Int(elapsed.rounded()))
        let minutes = total / 60
        let seconds = total % 60
        if minutes >= 100 {
            return "\(minutes):\(String(format: "%02d", seconds))"
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    func update(elapsed: TimeInterval, progress: Double) {
        self.elapsed = elapsed
        self.progress = progress
    }

    func reset() {
        update(elapsed: 0, progress: 0)
    }
}

@MainActor
final class PlayerEngine: ObservableObject {
    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var volume: Double
    @Published private(set) var isShuffleEnabled = false
    @Published private(set) var isRepeatEnabled = false
    let clock = PlaybackClock()

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var queue: [Track] = []
    private var currentIndex: Int?
    private let playbackRefreshInterval = 1.0
    private var didRestore = false
    private static let playbackStateKey = "MusicPlayer.playbackState.v1"

    init() {
        volume = Double(SystemOutputVolume.read() ?? 0.66)
        loadStateFromDisk()
    }

    deinit {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
    }

    func play(_ track: Track, in tracks: [Track]) {
        queue = tracks
        currentIndex = tracks.firstIndex(of: track)
        currentTrack = track
        clock.reset()

        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }

        let item = makePlayerItem(for: track)
        player = AVPlayer(playerItem: item)
        player?.volume = Float(volume)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: playbackRefreshInterval, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite {
                    let elapsed = max(0, seconds)
                    self.clock.update(elapsed: elapsed, progress: self.progressValue(for: elapsed))
                }
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinish),
            name: .AVPlayerItemDidPlayToEndTime,
            object: item
        )

        player?.play()
        isPlaying = true
        savePlaybackState()
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            syncElapsedFromPlayer()
        } else {
            player.play()
            isPlaying = true
        }
    }

    func stop() {
        player?.pause()
        player?.seek(to: .zero)
        isPlaying = false
        clock.reset()
    }

    func clearPlayback() {
        stop()
        queue = []
        currentIndex = nil
        currentTrack = nil
        clearSavedState()
    }

    func next() {
        guard let currentIndex, !queue.isEmpty else { return }
        let index: Int
        if isShuffleEnabled, queue.count > 1 {
            let candidates = queue.indices.filter { $0 != currentIndex }
            index = candidates.randomElement() ?? currentIndex
        } else if currentIndex == queue.count - 1 {
            index = isRepeatEnabled ? 0 : currentIndex
        } else {
            index = currentIndex + 1
        }
        play(queue[index], in: queue)
    }

    func previous() {
        guard let currentIndex, !queue.isEmpty else { return }
        let index = currentIndex == 0 && isRepeatEnabled ? queue.count - 1 : max(0, currentIndex - 1)
        play(queue[index], in: queue)
    }

    func seek(to progress: Double) {
        guard let duration = playbackDuration, duration.isFinite, duration > 0 else { return }
        let seconds = min(duration, max(0, progress * duration))
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        clock.update(elapsed: seconds, progress: progressValue(for: seconds))
    }

    func setVolume(_ value: Double) {
        volume = min(1, max(0, value))
        player?.volume = Float(volume)
        SystemOutputVolume.write(Float(volume))
    }

    func refreshMetadata(from tracks: [Track]) {
        let tracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        queue = queue.map { tracksByID[$0.id] ?? $0 }

        guard let current = currentTrack,
              let updated = tracksByID[current.id],
              updated != current else {
            return
        }
        currentTrack = updated
        currentIndex = queue.firstIndex(of: updated)
    }

    func toggleShuffle() {
        isShuffleEnabled.toggle()
        if isShuffleEnabled {
            isRepeatEnabled = false
        }
        savePlaybackState()
    }

    func toggleRepeat() {
        isRepeatEnabled.toggle()
        if isRepeatEnabled {
            isShuffleEnabled = false
        }
        savePlaybackState()
    }

    func tryRestore(from tracks: [Track]) {
        guard !didRestore, currentTrack == nil, !tracks.isEmpty else { return }
        guard let data = UserDefaults.standard.data(forKey: Self.playbackStateKey),
              let state = try? JSONDecoder().decode(StoredPlaybackState.self, from: data) else {
            didRestore = true
            return
        }
        let trackByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        guard let target = trackByID[state.currentTrackID] else {
            didRestore = true
            return
        }
        let restoredQueue = state.queueIDs.compactMap { trackByID[$0] }
        guard !restoredQueue.isEmpty else {
            didRestore = true
            return
        }
        didRestore = true
        isShuffleEnabled = state.isShuffleEnabled
        isRepeatEnabled = state.isRepeatEnabled
        play(target, in: restoredQueue)
    }

    private func savePlaybackState() {
        guard let currentTrack else {
            clearSavedState()
            return
        }
        let state = StoredPlaybackState(
            currentTrackID: currentTrack.id,
            queueIDs: queue.map(\.id),
            isShuffleEnabled: isShuffleEnabled,
            isRepeatEnabled: isRepeatEnabled
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.playbackStateKey)
        }
    }

    private func clearSavedState() {
        UserDefaults.standard.removeObject(forKey: Self.playbackStateKey)
    }

    private func loadStateFromDisk() {
        guard let data = UserDefaults.standard.data(forKey: Self.playbackStateKey),
              let state = try? JSONDecoder().decode(StoredPlaybackState.self, from: data) else { return }
        isShuffleEnabled = state.isShuffleEnabled
        isRepeatEnabled = state.isRepeatEnabled
    }

    var remainingText: String {
        guard let duration = playbackDuration, duration.isFinite else { return "(--:--)" }
        let remaining = max(0, duration - clock.elapsed)
        let total = Int(remaining.rounded())
        return "(\(total / 60):\(String(format: "%02d", total % 60)))"
    }

    @objc private func playerDidFinish() {
        if currentIndex == queue.count - 1, !isRepeatEnabled, !isShuffleEnabled {
            stop()
        } else {
            next()
        }
    }

    private func syncElapsedFromPlayer() {
        guard let currentTime = player?.currentTime().seconds, currentTime.isFinite else { return }
        let elapsed = max(0, currentTime)
        clock.update(elapsed: elapsed, progress: progressValue(for: elapsed))
    }

    private func progressValue(for elapsed: TimeInterval) -> Double {
        guard let duration = playbackDuration, duration.isFinite, duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    private var playbackDuration: TimeInterval? {
        if let duration = currentTrack?.duration, duration.isFinite, duration > 0 {
            return duration
        }
        guard let seconds = player?.currentItem?.duration.seconds, seconds.isFinite, seconds > 0 else {
            return nil
        }
        return seconds
    }

    private func makePlayerItem(for track: Track) -> AVPlayerItem {
        guard let authorizationHeader = track.authorizationHeader else {
            return AVPlayerItem(url: track.url)
        }

        let asset = AVURLAsset(
            url: track.url,
            options: [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "Authorization": authorizationHeader
                ]
            ]
        )
        return AVPlayerItem(asset: asset)
    }
}

private enum SystemOutputVolume {
    static func read() -> Float? {
        let device = defaultOutputDevice()
        guard device != kAudioObjectUnknown else { return nil }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return status == noErr ? volume : nil
    }

    static func write(_ volume: Float) {
        let device = defaultOutputDevice()
        guard device != kAudioObjectUnknown else { return }
        var mutableVolume = min(1, max(0, volume))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &mutableVolume)
    }

    private static func defaultOutputDevice() -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }
}
