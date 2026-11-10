import ActivityKit
import Combine
import Foundation

@MainActor
final class LyricsController: ObservableObject {
    @Published private(set) var track: LyricsTrack?
    @Published private(set) var lines: [TimedLyric] = []
    @Published private(set) var plainLyrics = ""
    @Published private(set) var activeIndex: Int?
    @Published private(set) var message = "Lance un morceau dans Spotify."
    @Published private(set) var loading = false
    @Published private(set) var liveEnabled = false
    @Published private(set) var liveMessage = ""
    @Published private(set) var playing = false
    @Published private(set) var foreground = false
    private let service = LyricsService()
    private var loadTask: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var revision = UUID()
    private var hasFreshSnapshot = false
    private var samplePosition: TimeInterval = 0
    private var sampleUptime = ProcessInfo.processInfo.systemUptime
    private var activity: Activity<LyricAttributes>?
    private var remoteEnabled = BackgroundSyncClient.shared.enabled
    private var activityUsesPush = false
    private var activityKey: String?
    private var publishing: Task<Void, Never>?
    private var publicationNeeded = false
    private var publishedState: LyricAttributes.ContentState?
    private var publishedUptime: TimeInterval = 0

    var currentLine: String {
        if let activeIndex { return lines[activeIndex].text.isEmpty ? "♪" : lines[activeIndex].text }
        return lines.isEmpty ? message : "♪"
    }
    var nextLine: String {
        let next = (activeIndex ?? -1) + 1
        return lines.indices.contains(next) ? lines[next].text : ""
    }

    func accept(_ playback: SpotifyPlayback?) {
        guard let playback, let item = playback.item, item.type == "track" else {
            clear(); return
        }
        let artist = item.artists?.first?.name ?? ""
        let duration = Double(item.duration_ms ?? 0) / 1000
        let key = item.id ?? item.uri ?? "\(item.name)|\(artist)|\(duration)"
        let incoming = LyricsTrack(key: key, title: item.name, artist: artist,
            album: item.album?.name ?? "", duration: duration)
        let changed = track?.key != key
        samplePosition = Double(playback.progress_ms ?? 0) / 1000
        sampleUptime = ProcessInfo.processInfo.systemUptime
        playing = playback.is_playing
        hasFreshSnapshot = foreground
        if changed {
            revision = UUID()
            loadTask?.cancel(); loadTask = nil
            track = incoming
            lines = []; plainLyrics = ""; activeIndex = nil
            loading = true
            message = "Recherche des paroles…"
            if foreground { fetch() }
        }
        updatePosition()
        startClock()
        requestPublication()
    }

    func setRemoteEnabled(_ enabled: Bool) {
        remoteEnabled = enabled
        requestPublication()
    }

    func setForeground(_ active: Bool) {
        let resumed = active && !foreground
        foreground = active
        if resumed { hasFreshSnapshot = false }
        if active {
            if remoteEnabled, activity == nil,
               let restored = Activity<LyricAttributes>.activities.first(where: {
                   $0.attributes.serverManaged == true && ($0.activityState == .active || $0.activityState == .stale)
               }) {
                activity = restored; activityUsesPush = true; liveEnabled = true
                BackgroundSyncClient.shared.bind(restored)
            }
            if loading, loadTask == nil { fetch() }
            startClock()
        } else {
            clock?.cancel(); clock = nil
            loadTask?.cancel(); loadTask = nil
        }
        requestPublication()
    }

    func reload() {
        guard foreground, track != nil else { return }
        revision = UUID()
        loadTask?.cancel(); loadTask = nil
        lines = []; plainLyrics = ""; activeIndex = nil
        loading = true; message = "Recherche des paroles…"
        requestPublication()
        fetch(reload: true)
    }

    func setLiveEnabled(_ enabled: Bool) {
        liveEnabled = enabled
        if !enabled { BackgroundSyncClient.shared.unbind() }
        requestPublication()
    }

    private func fetch(reload: Bool = false) {
        guard let track, foreground else { return }
        let expected = revision
        loading = true
        loadTask = Task { [weak self, service] in
            do {
                let document = try await service.load(track, reload: reload)
                try Task.checkCancellation()
                guard let self, self.revision == expected else { return }
                self.loading = false
                self.loadTask = nil
                self.lines = LyricsTimeline.parse(document.syncedLyrics ?? "")
                self.plainLyrics = document.plainLyrics ?? ""
                if document.instrumental {
                    self.lines = []; self.plainLyrics = ""
                    self.message = "Morceau instrumental · Aucune parole"
                } else if !self.lines.isEmpty {
                    self.message = "Paroles synchronisées · LRCLIB"
                } else if !self.plainLyrics.isEmpty {
                    self.message = "Paroles disponibles sans synchronisation · LRCLIB"
                } else { self.message = "Paroles indisponibles pour ce morceau." }
                self.updatePosition()
                self.requestPublication()
            } catch is CancellationError { return }
            catch {
                guard let self, self.revision == expected, !Task.isCancelled else { return }
                self.loading = false; self.loadTask = nil
                self.message = (error as? LyricsServiceError)?.localizedDescription ?? "Impossible de charger les paroles. Vérifie la connexion et réessaie."
                self.requestPublication()
            }
        }
    }

    private func startClock() {
        guard foreground, hasFreshSnapshot, track != nil, clock == nil else { return }
        clock = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self, self.foreground else { return }
                self.updatePosition()
            }
        }
    }

    private func updatePosition() {
        guard hasFreshSnapshot else { return }
        let estimated = samplePosition + (playing && foreground ? max(0, ProcessInfo.processInfo.systemUptime - sampleUptime) : 0)
        let duration = track?.duration ?? 0
        let limit = duration > 0 ? duration : max(0, estimated)
        let bounded = min(max(0, estimated), limit)
        let index = LyricsTimeline.index(at: bounded, in: lines)
        if index != activeIndex { activeIndex = index; requestPublication() }
    }

    private func clear() {
        guard track != nil else { return }
        revision = UUID()
        loadTask?.cancel(); loadTask = nil
        clock?.cancel(); clock = nil
        track = nil; lines = []; plainLyrics = ""; activeIndex = nil
        loading = false; playing = false; message = "Aucun morceau disponible dans Spotify."
        requestPublication()
    }

    private func requestPublication() {
        publicationNeeded = true
        guard publishing == nil else { return }
        publishing = Task { [weak self] in
            guard let self else { return }
            defer { self.publishing = nil }
            while self.publicationNeeded {
                self.publicationNeeded = false
                await self.publishLatest()
            }
        }
    }

    private func publishLatest() async {
        if liveEnabled, remoteEnabled, activityUsesPush, let activity,
           activity.activityState == .active || activity.activityState == .stale {
            BackgroundSyncClient.shared.bind(activity)
            return // The server is the only writer, including while iOS suspends the app.
        }
        guard liveEnabled, let track else {
            if let activity { await activity.end(nil, dismissalPolicy: .immediate) }
            activity = nil; activityKey = nil
            return
        }
        let expected = revision
        let state = LyricAttributes.ContentState(
            line: String(currentLine.prefix(300)), nextLine: String(nextLine.prefix(300)),
            lineNumber: (activeIndex ?? -1) + 1, isPlaying: playing,
            status: !foreground ? "Suivi suspendu · Ouvre LyricLive" : (!hasFreshSnapshot ? "Actualisation Spotify…" : (playing ? "En lecture · LRCLIB" : "Spotify en pause · LRCLIB")),
            trackTitle: track.title, trackArtist: track.artist)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(foreground ? 30 : 1))
        if let activity, activityKey == track.key, activityUsesPush == remoteEnabled,
           activity.activityState == .active || activity.activityState == .stale {
            let now = ProcessInfo.processInfo.systemUptime
            guard state != publishedState || now - publishedUptime >= 15 else { return }
            publishedState = state; publishedUptime = now
            await activity.update(content)
            return
        }
        guard foreground else { return }
        // A title belongs to immutable ActivityAttributes: recreate on track change.
        for previous in Activity<LyricAttributes>.activities {
            await previous.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil; activityKey = nil
        guard expected == revision, liveEnabled, foreground else { publicationNeeded = true; return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            liveMessage = "Active les activités en direct dans les réglages iOS."
            liveEnabled = false
            return
        }
        do {
            activity = try Activity.request(attributes: LyricAttributes(
                title: String(track.title.prefix(100)), artist: String(track.artist.prefix(100)), source: "LRCLIB", serverManaged: remoteEnabled), content: content, pushType: remoteEnabled ? .token : nil)
            activityKey = track.key
            activityUsesPush = remoteEnabled
            if remoteEnabled, let activity { BackgroundSyncClient.shared.bind(activity) }
            publishedState = state; publishedUptime = ProcessInfo.processInfo.systemUptime
            liveMessage = "Live Activity activée. Présentation gérée par iOS."
        } catch {
            liveEnabled = false
            liveMessage = "Impossible de créer la Live Activity : \(error.localizedDescription)"
        }
    }
}
