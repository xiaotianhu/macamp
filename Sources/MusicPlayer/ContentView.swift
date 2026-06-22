import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @State private var showingWebDAV = false
    @State private var isPlaylistExpanded = true

    private var windowSize: CGSize {
        isPlaylistExpanded ? WinampWindowMetrics.expandedSize : WinampWindowMetrics.collapsedSize
    }

    var body: some View {
        VStack(spacing: 0) {
            WinampTopDeck()
                .frame(height: WinampWindowMetrics.topDeckHeight)
            DividerLine()
            WinampPlaylist(showingWebDAV: $showingWebDAV, isExpanded: $isPlaylistExpanded)
                .frame(height: WinampWindowMetrics.playlistHeight(expanded: isPlaylistExpanded), alignment: .top)
                .clipped()
        }
        .frame(width: windowSize.width, height: windowSize.height)
        .background(WinampColor.shell.opacity(0.96), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(WinampColor.stroke.opacity(0.82), lineWidth: 1)
        )
        .background(WindowConfigurator(size: windowSize))
        .foregroundStyle(WinampColor.text)
        .animation(.easeInOut(duration: 0.26), value: isPlaylistExpanded)
        .onChange(of: library.tracks) { _, tracks in
            player.refreshMetadata(from: tracks)
            player.tryRestore(from: tracks)
        }
        .sheet(isPresented: $showingWebDAV) {
            WebDAVSheet()
                .environmentObject(library)
        }
        .alert("Library Error", isPresented: Binding(get: { library.errorMessage != nil }, set: { _ in library.errorMessage = nil })) {
            Button("OK", role: .cancel) { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }
}

private enum WinampWindowMetrics {
    static let width: CGFloat = 560
    static let topDeckHeight: CGFloat = 262
    static let dividerHeight: CGFloat = 1
    static let collapsedPlaylistHeight: CGFloat = 44
    static let expandedHeight: CGFloat = 720
    static let collapsedHeight: CGFloat = topDeckHeight + dividerHeight + collapsedPlaylistHeight
    static let expandedSize = CGSize(width: width, height: expandedHeight)
    static let collapsedSize = CGSize(width: width, height: collapsedHeight)

    static func playlistHeight(expanded: Bool) -> CGFloat {
        expanded ? expandedHeight - topDeckHeight - dividerHeight : collapsedPlaylistHeight
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    let size: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.styleMask = [.borderless]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.minSize = size
        window.maxSize = size
        let currentFrame = window.frame
        let newFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        window.setFrame(newFrame, display: true, animate: false)
    }
}

private struct WinampTopDeck: View {
    @EnvironmentObject private var player: PlayerEngine

    var body: some View {
        VStack(spacing: 0) {
            WindowChrome()
                .padding(.horizontal, -18)
                .padding(.bottom, 12)

            HStack(spacing: 16) {
                MeterPanel()
                    .frame(width: 158, height: 96)

                VStack(alignment: .leading, spacing: 10) {
                    ScrollingTitleText(text: "1. \(player.currentTrack?.artistTitle ?? "No Track Selected")")
                        .frame(height: 21)

                    HStack(spacing: 14) {
                        Badge(player.currentTrack?.bitRateText ?? "128 kbps")
                        Badge(player.currentTrack?.sampleRateText ?? "44 kHz")
                        Spacer()
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))

                    HStack(spacing: 16) {
                        SliderReadout(title: "Volume", value: player.volume, accent: WinampColor.blue) { value in
                            player.setVolume(value)
                        }
                            .frame(width: 116)
                        Spacer()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 104, alignment: .top)

            VStack(spacing: 0) {
                Color.clear.frame(height: 38)
                ProgressStrip(value: progress) { value in
                    player.seek(to: value)
                }
            }
            .frame(height: 45)
            .padding(.bottom, 14)

            HStack(spacing: 14) {
                TransportButton(systemName: "backward.end.fill") { player.previous() }
                TransportButton(systemName: player.isPlaying ? "pause.fill" : "play.fill", primary: true) { player.togglePlayPause() }
                TransportButton(systemName: "stop.fill") { player.stop() }
                TransportButton(systemName: "forward.end.fill") { player.next() }
                TransportButton(systemName: "eject.fill") {}
                Spacer()
                SmallLampButton(title: "SHUFFLE", systemName: "shuffle", isActive: player.isShuffleEnabled) {
                    player.toggleShuffle()
                }
                SmallLampButton(title: "REPEAT", systemName: "repeat", isActive: player.isRepeatEnabled) {
                    player.toggleRepeat()
                }
                Image(systemName: "bolt.fill")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(.white)
                    .shadow(color: .white.opacity(0.4), radius: 5)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .background(
            LinearGradient(
                colors: [WinampColor.titleBand, WinampColor.panel.opacity(0.86)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var progress: Double {
        guard let duration = player.currentTrack?.duration, duration > 0 else { return 0.08 }
        return min(1, max(0, player.elapsed / duration))
    }
}

private struct WindowChrome: View {
    var body: some View {
        HStack {
            Color.clear.frame(width: 156)
            Spacer()
            Text("MACAMP")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Spacer()
            TopRightIconButton(systemName: "xmark", rotation: .zero) {
                NSApp.terminate(nil)
            }
            .frame(width: 156)
        }
        .frame(height: 18)
        .background(alignment: .center) {
            WindowDragArea()
                .padding(.trailing, 34)
        }
    }
}

private struct TopRightIconButton: View {
    let systemName: String
    let rotation: Angle
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(.white)
                .rotationEffect(rotation)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
        }
        .padding(.trailing, 10)
    }
}

private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowDragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

private struct MeterPanel: View {
    @EnvironmentObject private var player: PlayerEngine

    var body: some View {
        VStack(spacing: 9) {
            Text(player.elapsedText)
                .font(.system(size: 42, weight: .light, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .center)
                .contentTransition(.numericText())

            SpectrumBars(levels: player.spectrumLevels)
                .frame(width: 140, height: 44, alignment: .bottomTrailing)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .background(
            LinearGradient(colors: [WinampColor.recessTop, WinampColor.recess], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }
}

private struct SpectrumBars: View {
    let levels: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.92), .white.opacity(0.38)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 4, height: 6 + level * 35)
            }
        }
        .frame(width: 140, height: 44, alignment: .bottomTrailing)
        .clipped()
    }
}

private struct Badge: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(WinampColor.recess, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(.white.opacity(0.04), lineWidth: 1)
            )
    }
}

private struct ScrollingTitleText: View {
    let text: String
    private let speed: Double = 34
    private let pause: Double = 1

    var body: some View {
        GeometryReader { proxy in
            let estimatedTextWidth = max(proxy.size.width, Double(text.count) * 8.4)
            let overflow = max(0, estimatedTextWidth - proxy.size.width)

            if overflow < 6 {
                Text(text)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let travelDuration = overflow / speed
                    let cycleDuration = travelDuration + pause
                    let time = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycleDuration)
                    let offset = time < pause ? 0 : min(overflow, (time - pause) * speed)

                    Text(text)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .offset(x: -offset)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }
        }
    }
}

private struct SliderReadout: View {
    let title: String
    var trailing: String?
    let value: Double
    let accent: Color
    let onChange: (Double) -> Void

    init(title: String, trailing: String? = nil, value: Double, accent: Color, onChange: @escaping (Double) -> Void = { _ in }) {
        self.title = title
        self.trailing = trailing
        self.value = value
        self.accent = accent
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MiniDragSlider(value: value, accent: accent, onChange: onChange)
            HStack {
                Text(title)
                Spacer()
                if let trailing {
                    Text(trailing)
                } else {
                    Text("\(Int(value * 100))%")
                }
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
        }
    }
}

private struct ProgressStrip: View {
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.22))
                    .frame(height: 7)
                Capsule()
                    .fill(.white)
                    .frame(width: max(38, proxy.size.width * value), height: 7)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        onChange(min(1, max(0, gesture.location.x / max(proxy.size.width, 1))))
                    }
            )
        }
        .frame(height: 7)
    }
}

private struct MiniDragSlider: View {
    let value: Double
    let accent: Color
    let onChange: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(WinampColor.recess)
                    .frame(height: 4)
                Capsule()
                    .fill(accent)
                    .frame(width: max(8, proxy.size.width * value), height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: 11, height: 11)
                    .offset(x: min(max(0, proxy.size.width - 11), max(0, proxy.size.width * value - 5.5)))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        onChange(min(1, max(0, gesture.location.x / max(proxy.size.width, 1))))
                    }
            )
        }
        .frame(height: 14)
    }
}

private struct TransportButton: View {
    let systemName: String
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: primary ? 22 : 20, weight: .black))
                .frame(width: primary ? 34 : 28, height: 34)
        }
        .buttonStyle(TransportButtonStyle(primary: primary))
    }
}

private struct TransportButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: primary ? 7 : 5, style: .continuous)
                    .fill(configuration.isPressed ? .white.opacity(0.18) : .clear)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

private struct SmallLampButton: View {
    let title: String
    let systemName: String
    var isActive = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Circle()
                    .fill(isActive ? WinampColor.green : WinampColor.dim.opacity(0.42))
                    .frame(width: 5, height: 5)
                    .shadow(color: isActive ? WinampColor.green.opacity(0.75) : .clear, radius: 4)
                Text(title)
                    .lineLimit(1)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7)
            .frame(height: 24)
        }
        .buttonStyle(SmallBezelButtonStyle())
        .help(systemName)
    }
}

private struct WinampPlaylist: View {
    @EnvironmentObject private var library: LibraryStore
    @Binding var showingWebDAV: Bool
    @Binding var isExpanded: Bool
    @State private var expandedFolderIDs = Set<String>()
    @State private var cachedFolderTrees: [FolderNode] = []

    var body: some View {
        VStack(spacing: 0) {
            PlaylistTitleBar(isExpanded: $isExpanded)

            if isExpanded {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(cachedFolderTrees) { node in
                            FolderTreeRow(node: node, depth: 0, expandedFolderIDs: $expandedFolderIDs)
                        }
                    }
                    .padding(.vertical, 7)
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(WinampColor.listBackground.opacity(0.92))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(.white.opacity(0.035), lineWidth: 1)
                )
                .overlay(alignment: .center) {
                    if library.isScanning && library.tracks.isEmpty {
                        ProgressView("Scanning")
                            .padding(14)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    } else if !library.isScanning && library.tracks.isEmpty {
                        Text("ADD LOCAL FOLDER OR WEBDAV SOURCE")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(WinampColor.dim)
                    }
                }
                .padding(.horizontal, 17)
                .padding(.bottom, 10)
                .transition(.opacity)
            }

            if isExpanded {
                PlaylistFooter(showingWebDAV: $showingWebDAV)
                    .transition(.opacity)
            }
        }
        .background(WinampColor.panel.opacity(0.62))
        .animation(.easeInOut(duration: 0.26), value: isExpanded)
        .onAppear {
            rebuildTree()
            initializeExpansionIfNeeded()
        }
        .onChange(of: library.tracks.map(\.id)) { _, _ in
            rebuildTree()
        }
        .onChange(of: library.sources.map(\.id)) { _, _ in
            rebuildTree()
        }
    }

    private func rebuildTree() {
        cachedFolderTrees = FolderNode.makeTrees(sources: library.sources, tracks: library.tracks)
        initializeExpansionIfNeeded()
    }

    private func initializeExpansionIfNeeded() {
        expandedFolderIDs.formUnion(cachedFolderTrees.map(\.id))
    }
}

private struct PlaylistTitleBar: View {
    @Binding var isExpanded: Bool

    var body: some View {
        HStack {
            Color.clear.frame(width: 156)
            Spacer()
            Text("PLAYLIST")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .tracking(1.2)
                .foregroundStyle(.white)
            Spacer()
            TopRightIconButton(
                systemName: "chevron.down",
                rotation: .degrees(isExpanded ? 0 : -90)
            ) {
                isExpanded.toggle()
            }
            .frame(width: 156)
        }
        .frame(height: 44)
    }
}

private struct FolderTreeRow: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var library: LibraryStore
    let node: FolderNode
    let depth: Int
    @Binding var expandedFolderIDs: Set<String>

    private var isExpanded: Bool {
        expandedFolderIDs.contains(node.id)
    }

    private var canExpand: Bool {
        !node.children.isEmpty || !node.files.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .black))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.white)
                    .opacity(canExpand ? 1 : 0.25)
                    .frame(width: 28, height: 30)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if canExpand {
                            toggle()
                        }
                    }

                HStack(spacing: 7) {
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(WinampColor.dim)

                    Text(node.name)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("\(node.tracks.count)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(WinampColor.dim)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    playFolder()
                }
            }
            .font(.system(size: depth == 0 ? 14 : 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.leading, 1 + CGFloat(depth * 18))
            .padding(.trailing, 12)
            .frame(height: 30)
            .background(currentTrackIsInside ? WinampColor.green.opacity(0.10) : .clear)
            .contextMenu {
                if let sourceID = node.sourceID {
                    Button(role: .destructive) {
                        if node.tracks.contains(where: { $0 == player.currentTrack }) {
                            player.clearPlayback()
                        }
                        library.removeSource(id: sourceID)
                    } label: {
                        Label("Delete from Playlist", systemImage: "trash")
                    }
                }
            }

            if isExpanded {
                ForEach(node.children) { child in
                    FolderTreeRow(node: child, depth: depth + 1, expandedFolderIDs: $expandedFolderIDs)
                }

                ForEach(Array(node.files.enumerated()), id: \.element.id) { index, track in
                    FolderTrackRow(index: index + 1, track: track, selected: player.currentTrack == track, depth: depth + 1)
                        .onTapGesture(count: 2) {
                            let queue = node.playQueue(startingAt: track)
                            player.play(track, in: queue)
                            library.loadMetadata(for: node.tracks)
                        }
                }
            }
        }
    }

    private var currentTrackIsInside: Bool {
        guard let currentTrack = player.currentTrack else { return false }
        return node.containsTrack(currentTrack.id)
    }

    private func toggle() {
        if expandedFolderIDs.contains(node.id) {
            expandedFolderIDs.remove(node.id)
        } else {
            expandedFolderIDs.insert(node.id)
        }
    }

    private func playFolder() {
        guard let first = node.tracks.first else { return }
        player.play(first, in: node.tracks)
        library.loadMetadata(for: node.tracks)
    }
}

private struct FolderTrackRow: View {
    let index: Int
    let track: Track
    let selected: Bool
    let depth: Int

    var body: some View {
        HStack(spacing: 7) {
            Text("\(index).")
                .frame(width: 24, alignment: .trailing)
                .foregroundStyle(selected ? WinampColor.green : .white.opacity(0.68))

            Image(systemName: "music.note")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(selected ? WinampColor.green : WinampColor.dim)

            Text(track.title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(track.durationText)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.86))
                .frame(width: 46, alignment: .trailing)
        }
        .font(.system(size: 13, weight: selected ? .semibold : .regular, design: .rounded))
        .foregroundStyle(selected ? WinampColor.green : .white.opacity(0.92))
        .padding(.leading, 10 + CGFloat(depth * 18))
        .padding(.trailing, 12)
        .frame(height: 28)
        .background(selected ? WinampColor.green.opacity(0.14) : .clear)
        .contentShape(Rectangle())
    }
}

private struct PlaylistFooter: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @Binding var showingWebDAV: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button("LOCAL") { library.addLocalFolder() }
                .buttonStyle(SmallBezelButtonStyle())

            Button("WEBDAV") { showingWebDAV = true }
                .buttonStyle(SmallBezelButtonStyle())

            Button("CLEAR") {
                player.stop()
                library.clearLibrary()
            }
            .buttonStyle(SmallBezelButtonStyle())

            Spacer()

            if library.isScanning && !library.tracks.isEmpty {
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 12, height: 12)
                    Text("Refresh")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(WinampColor.dim)
                }
            }

            Text("\(library.tracks.count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(WinampColor.dim)
                .frame(width: 58, alignment: .trailing)
        }
        .padding(.horizontal, 17)
        .padding(.bottom, 14)
    }
}

private struct SmallBezelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 8)
            .frame(height: 25)
            .background(
                LinearGradient(
                    colors: [
                        .white.opacity(configuration.isPressed ? 0.05 : 0.12),
                        .black.opacity(configuration.isPressed ? 0.18 : 0.32)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct WebDAVSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @State private var urlText = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add WebDAV Source")
                .font(.headline)
            TextField("https://example.com/dav/music", text: $urlText)
            TextField("Username", text: $username)
            SecureField("Password", text: $password)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    if let url = URL(string: urlText) {
                        library.addWebDAV(url: url, username: username, password: password)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

private struct DividerLine: View {
    var body: some View {
        Rectangle()
            .fill(WinampColor.stroke.opacity(0.45))
            .frame(height: 1)
    }
}

private struct WinampBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.13, blue: 0.20),
                    Color(red: 0.04, green: 0.06, blue: 0.10),
                    Color(red: 0.10, green: 0.11, blue: 0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [Color(red: 0.25, green: 0.37, blue: 0.52).opacity(0.4), .clear],
                center: .topTrailing,
                startRadius: 60,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

private enum WinampColor {
    static let shell = Color(red: 0.11, green: 0.13, blue: 0.16)
    static let panel = Color(red: 0.14, green: 0.17, blue: 0.20)
    static let titleBand = Color(red: 0.10, green: 0.13, blue: 0.16)
    static let recess = Color(red: 0.08, green: 0.10, blue: 0.12)
    static let recessTop = Color(red: 0.13, green: 0.15, blue: 0.18)
    static let listBackground = Color(red: 0.12, green: 0.15, blue: 0.16)
    static let stroke = Color(red: 0.32, green: 0.37, blue: 0.40)
    static let text = Color(red: 0.88, green: 0.91, blue: 0.88)
    static let dim = Color(red: 0.48, green: 0.53, blue: 0.55)
    static let green = Color(red: 0.20, green: 1.00, blue: 0.64)
    static let blue = Color(red: 0.24, green: 0.45, blue: 1.00)
}

private struct FolderNode: Identifiable, Equatable {
    let id: String
    let name: String
    let sourceID: UUID?
    let children: [FolderNode]
    let files: [Track]
    let tracks: [Track]
    let trackIDs: Set<String>

    func playQueue(startingAt track: Track) -> [Track] {
        guard let index = tracks.firstIndex(of: track) else { return tracks }
        return Array(tracks[index...]) + Array(tracks[..<index])
    }

    func containsTrack(_ trackID: String) -> Bool {
        trackIDs.contains(trackID)
    }

    static func makeTrees(sources: [LibrarySource], tracks: [Track]) -> [FolderNode] {
        sources.map { source in
            let sourceTracks = tracks
                .filter { $0.sourceID == source.id }
                .sortedByPlaybackPath()
            let builder = FolderNodeBuilder(id: source.id.uuidString, name: source.title, sourceID: source.id)
            for track in sourceTracks {
                builder.insert(track, components: relativeComponents(for: track, source: source))
            }
            return builder.node()
        }
        .filter { !$0.tracks.isEmpty }
    }

    private static func relativeComponents(for track: Track, source: LibrarySource) -> [String] {
        let rootPath = normalizedPath(source.url)
        let trackPath = normalizedPath(track.url)
        let relativePath: String

        if trackPath.hasPrefix(rootPath) {
            relativePath = String(trackPath.dropFirst(rootPath.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            relativePath = track.url.lastPathComponent.removingPercentEncoding ?? track.url.lastPathComponent
        }

        let components = relativePath
            .split(separator: "/")
            .map { String($0).removingPercentEncoding ?? String($0) }
        return components.isEmpty ? [track.url.lastPathComponent] : components
    }

    private static func normalizedPath(_ url: URL) -> String {
        let path = url.isFileURL ? url.standardizedFileURL.path : url.path
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private final class FolderNodeBuilder {
    let id: String
    let name: String
    let sourceID: UUID?
    private var childrenByName: [String: FolderNodeBuilder] = [:]
    private var files: [Track] = []

    init(id: String, name: String, sourceID: UUID? = nil) {
        self.id = id
        self.name = name
        self.sourceID = sourceID
    }

    func insert(_ track: Track, components: [String]) {
        guard components.count > 1 else {
            files.append(track)
            return
        }

        let folderName = components[0]
        let child = childrenByName[folderName] ?? {
            let child = FolderNodeBuilder(id: id + "/" + folderName, name: folderName)
            childrenByName[folderName] = child
            return child
        }()
        child.insert(track, components: Array(components.dropFirst()))
    }

    func node() -> FolderNode {
        let children = childrenByName.values
            .map { $0.node() }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let sortedFiles = files.sortedByPlaybackPath()
        let tracks = (children.flatMap(\.tracks) + sortedFiles).sortedByPlaybackPath()
        return FolderNode(
            id: id, name: name, sourceID: sourceID,
            children: children, files: sortedFiles, tracks: tracks,
            trackIDs: Set(tracks.map(\.id))
        )
    }
}

private extension Array where Element == Track {
    func sortedByPlaybackPath() -> [Track] {
        sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }
}

private extension Track {
    var artistTitle: String {
        if artist.isEmpty {
            return title
        }
        return "\(artist) — \(title)"
    }

    var bitRateText: String {
        guard let bitRate else { return "128 kbps" }
        return "\(bitRate / 1000) kbps"
    }

    var sampleRateText: String {
        guard let sampleRate else { return "44 kHz" }
        return "\(sampleRate / 1000) kHz"
    }
}
