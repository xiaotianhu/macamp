import Foundation

struct WebDAVClient {
    let source: LibrarySource

    func listAudioFiles(maxDepth: Int = 6) async throws -> [URL] {
        var visited = Set<URL>()
        return try await list(source.url, depth: 0, maxDepth: maxDepth, visited: &visited)
    }

    private func list(_ url: URL, depth: Int, maxDepth: Int, visited: inout Set<URL>) async throws -> [URL] {
        guard depth <= maxDepth, !visited.contains(url) else { return [] }
        visited.insert(url)

        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8" ?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:resourcetype/>
          </D:prop>
        </D:propfind>
        """.utf8)

        if let username = source.username, let password = source.password {
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let parser = WebDAVParser(baseURL: url)
        let entries = parser.parse(data: data)
        var files: [URL] = []

        for entry in entries where entry.url != url {
            if entry.isCollection {
                files.append(contentsOf: try await list(entry.url, depth: depth + 1, maxDepth: maxDepth, visited: &visited))
            } else if AudioFile.isSupported(entry.url) {
                files.append(entry.url)
            }
        }

        return files
    }
}

private final class WebDAVParser: NSObject, XMLParserDelegate {
    struct Entry {
        let url: URL
        let isCollection: Bool
    }

    private let baseURL: URL
    private var entries: [Entry] = []
    private var currentHref = ""
    private var currentIsCollection = false
    private var currentElement = ""
    private var insideResponse = false

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    func parse(data: Data) -> [Entry] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        currentElement = elementName
        if elementName.hasSuffix("response") {
            insideResponse = true
            currentHref = ""
            currentIsCollection = false
        } else if insideResponse && elementName.hasSuffix("collection") {
            currentIsCollection = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard insideResponse, currentElement.hasSuffix("href") else { return }
        currentHref += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.hasSuffix("response") {
            let href = currentHref.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: href, relativeTo: baseURL)?.absoluteURL {
                entries.append(Entry(url: url, isCollection: currentIsCollection))
            }
            insideResponse = false
        }
        currentElement = ""
    }
}
