import AVFoundation
import Combine
import CoreAudio
import Foundation

@MainActor
final class PlayerEngine: ObservableObject {
    @Published private(set) var currentTrack: Track?
    @Published private(set) var isPlaying = false
    @Published var elapsed: TimeInterval = 0
    @Published private(set) var volume: Double
    @Published private(set) var isShuffleEnabled = false
    @Published private(set) var isRepeatEnabled = false
    @Published private(set) var spectrumLevels: [Double] = Array(repeating: 0.16, count: 24)

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var queue: [Track] = []
    private var currentIndex: Int?
    private var analysisTask: Task<Void, Never>?
    private var amplitudeEnvelope: [Double] = []
    private let spectrumBarCount = 24
    private let envelopeRate = 30.0

    init() {
        volume = Double(SystemOutputVolume.read() ?? 0.66)
    }

    deinit {
        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }
        analysisTask?.cancel()
    }

    func play(_ track: Track, in tracks: [Track]) {
        queue = tracks
        currentIndex = tracks.firstIndex(of: track)
        currentTrack = track
        elapsed = 0
        amplitudeEnvelope = []
        spectrumLevels = fallbackSpectrum(at: 0)

        if let timeObserver {
            player?.removeTimeObserver(timeObserver)
        }

        let item = makePlayerItem(for: track)
        player = AVPlayer(playerItem: item)
        player?.volume = Float(volume)
        timeObserver = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                self.updateSpectrum()
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
        analyze(track)
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            spectrumLevels = Array(repeating: 0.18, count: spectrumBarCount)
        } else {
            player.play()
            isPlaying = true
        }
    }

    func stop() {
        player?.pause()
        player?.seek(to: .zero)
        isPlaying = false
        elapsed = 0
        spectrumLevels = Array(repeating: 0.18, count: spectrumBarCount)
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
        guard let duration = currentTrack?.duration, duration.isFinite, duration > 0 else { return }
        let seconds = min(duration, max(0, progress * duration))
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        elapsed = seconds
        updateSpectrum()
    }

    func setVolume(_ value: Double) {
        volume = min(1, max(0, value))
        player?.volume = Float(volume)
        SystemOutputVolume.write(Float(volume))
    }

    func toggleShuffle() {
        isShuffleEnabled.toggle()
        if isShuffleEnabled {
            isRepeatEnabled = false
        }
    }

    func toggleRepeat() {
        isRepeatEnabled.toggle()
        if isRepeatEnabled {
            isShuffleEnabled = false
        }
    }

    var remainingText: String {
        guard let duration = currentTrack?.duration, duration.isFinite else { return "(--:--)" }
        let remaining = max(0, duration - elapsed)
        let total = Int(remaining.rounded())
        return "(\(total / 60):\(String(format: "%02d", total % 60)))"
    }

    var elapsedText: String {
        let total = max(0, Int(elapsed.rounded()))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    @objc private func playerDidFinish() {
        if currentIndex == queue.count - 1, !isRepeatEnabled, !isShuffleEnabled {
            stop()
        } else {
            next()
        }
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

    private func analyze(_ track: Track) {
        analysisTask?.cancel()
        let url = track.url
        let authorizationHeader = track.authorizationHeader
        analysisTask = Task.detached(priority: .utility) {
            let envelope = await AudioEnvelopeAnalyzer.analyze(url: url, authorizationHeader: authorizationHeader)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.amplitudeEnvelope = envelope
                self.updateSpectrum()
            }
        }
    }

    private func updateSpectrum() {
        guard isPlaying else { return }
        if amplitudeEnvelope.isEmpty {
            spectrumLevels = fallbackSpectrum(at: elapsed)
            return
        }

        let center = elapsed * envelopeRate
        let targetLevels = (0..<spectrumBarCount).map { index in
            let offset = Double(index - spectrumBarCount / 2) * 0.52
            let amplitude = interpolatedEnvelope(at: center + offset)
            let shaped = pow(amplitude, 0.62)
            let spread = 0.88 + 0.12 * sin(Double(index) * 0.9 + elapsed * 3.2)
            return min(1, max(0.10, shaped * spread))
        }

        spectrumLevels = zip(spectrumLevels, targetLevels).map { current, target in
            current * 0.58 + target * 0.42
        }
    }

    private func interpolatedEnvelope(at position: Double) -> Double {
        guard !amplitudeEnvelope.isEmpty else { return 0 }
        let clamped = min(Double(amplitudeEnvelope.count - 1), max(0, position))
        let lowerIndex = Int(clamped.rounded(.down))
        let upperIndex = min(amplitudeEnvelope.count - 1, lowerIndex + 1)
        let fraction = clamped - Double(lowerIndex)
        let lower = amplitudeEnvelope[lowerIndex]
        let upper = amplitudeEnvelope[upperIndex]
        return lower + (upper - lower) * fraction
    }

    private func fallbackSpectrum(at time: TimeInterval) -> [Double] {
        (0..<spectrumBarCount).map { index in
            let wave = sin(time * 5.4 + Double(index) * 0.56)
            let second = sin(time * 2.1 + Double(index) * 0.18)
            return min(0.72, max(0.10, 0.30 + wave * 0.14 + second * 0.08))
        }
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

private enum AudioEnvelopeAnalyzer {
    static func analyze(url: URL, authorizationHeader: String?) async -> [Double] {
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
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let audioTrack = tracks.first else { return [] }
            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return [] }
            reader.add(output)
            guard reader.startReading() else { return [] }

            var envelope: [Double] = []
            var windowSquares: Double = 0
            var windowSamples = 0
            let samplesPerWindow = 1_470
            let maxWindows = 80_000

            while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let length = CMBlockBufferGetDataLength(blockBuffer)
                var data = Data(count: length)
                data.withUnsafeMutableBytes { rawBuffer in
                    if let baseAddress = rawBuffer.baseAddress {
                        CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: length, destination: baseAddress)
                    }
                }

                data.withUnsafeBytes { rawBuffer in
                    let samples = rawBuffer.bindMemory(to: Float.self)
                    for sample in samples {
                        let value = Double(sample)
                        windowSquares += value * value
                        windowSamples += 1
                        if windowSamples >= samplesPerWindow {
                            envelope.append(sqrt(windowSquares / Double(windowSamples)))
                            windowSquares = 0
                            windowSamples = 0
                            if envelope.count >= maxWindows {
                                reader.cancelReading()
                                break
                            }
                        }
                    }
                }
            }

            if windowSamples > 0 {
                envelope.append(sqrt(windowSquares / Double(windowSamples)))
            }

            let peak = envelope.max() ?? 0
            guard peak > 0 else { return [] }
            return envelope.map { min(1, $0 / peak) }
        } catch {
            return []
        }
    }
}
