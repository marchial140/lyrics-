import Foundation

struct LyricsTrack: Equatable {
    let key: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
}

struct LyricsDocument: Decodable {
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
}

enum LyricsServiceError: LocalizedError {
    case missing, unavailable, limited(Date)
    var errorDescription: String? {
        switch self {
        case .missing: return "Aucune parole trouvée pour cette version du morceau."
        case .unavailable: return "Le service de paroles est momentanément indisponible."
        case .limited(let until): return "Service de paroles occupé. Réessaie après \(until.formatted(date: .omitted, time: .standard))."
        }
    }
}

actor LyricsService {
    private var cache: [String: LyricsDocument] = [:]
    private var cacheOrder: [String] = []
    private var nextRequest = Date.distantPast

    func load(_ track: LyricsTrack, reload: Bool = false) async throws -> LyricsDocument {
        if !reload, let cached = cache[track.key] { return cached }
        guard Date() >= nextRequest else { throw LyricsServiceError.limited(nextRequest) }
        // Exact title, primary artist and duration; never substitute a fuzzy different song.
        for includeAlbum in [true, false] {
            try Task.checkCancellation()
            let wait = nextRequest.timeIntervalSinceNow
            if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            nextRequest = Date().addingTimeInterval(0.4)
            var url = URLComponents(string: "https://lrclib.net/api/get")!
            url.queryItems = [.init(name: "track_name", value: track.title),
                              .init(name: "artist_name", value: track.artist)]
            if includeAlbum, !track.album.isEmpty { url.queryItems?.append(.init(name: "album_name", value: track.album)) }
            if (1...3600).contains(track.duration) {
                url.queryItems?.append(.init(name: "duration", value: String(track.duration)))
            }
            var request = URLRequest(url: url.url!)
            request.timeoutInterval = 15
            request.setValue("LyricLive/0.3 (https://github.com/marchial140/lyrics-)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw LyricsServiceError.unavailable }
            switch response.statusCode {
            case 200:
                guard data.count <= 1_048_576 else { throw LyricsServiceError.unavailable }
                let document = try JSONDecoder().decode(LyricsDocument.self, from: data)
                cache[track.key] = document
                cacheOrder.removeAll { $0 == track.key }
                cacheOrder.append(track.key)
                if cacheOrder.count > 20 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
                return document
            case 404:
                if !includeAlbum || track.album.isEmpty { throw LyricsServiceError.missing }
            case 429, 503:
                let delay = max(1, Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30)
                nextRequest = Date().addingTimeInterval(delay + Double.random(in: 0...(delay * 0.3)))
                throw LyricsServiceError.limited(nextRequest)
            default: throw LyricsServiceError.unavailable
            }
        }
        throw LyricsServiceError.missing
    }
}
