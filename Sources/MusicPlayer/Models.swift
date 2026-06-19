import Foundation

enum LibrarySourceKind: String, Codable, Hashable {
    case local
    case webDAV
}

struct LibrarySource: Identifiable, Codable, Hashable {
    var id: UUID
    var kind: LibrarySourceKind
    var title: String
    var url: URL
    var username: String?
    var password: String?

    init(id: UUID = UUID(), kind: LibrarySourceKind, title: String, url: URL, username: String? = nil, password: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.url = url
        self.username = username
        self.password = password
    }
}

struct Track: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let year: String
    let duration: TimeInterval?
    let bitRate: Int?
    let sampleRate: Int?
    let url: URL
    let sourceID: UUID
    let authorizationHeader: String?

    var durationText: String {
        guard let duration, duration.isFinite else { return "--:--" }
        let total = max(0, Int(duration.rounded()))
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }

    var infoText: String {
        var parts: [String] = []
        if let bitRate {
            parts.append("\(bitRate / 1000) kbps")
        }
        if let sampleRate {
            parts.append("\(sampleRate / 1000) kHz")
        }
        return parts.isEmpty ? "Audio" : parts.joined(separator: " / ")
    }
}

struct LibraryGroup: Identifiable {
    let id: String
    let artist: String
    let album: String
    let year: String
    let tracks: [Track]
}

enum AudioFile {
    static let extensions: Set<String> = ["aac", "aiff", "alac", "caf", "flac", "m4a", "mp3", "ogg", "wav"]

    static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
