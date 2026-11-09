import ActivityKit
import Foundation
import Combine

@MainActor
final class LiveActivityController: ObservableObject {
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var activityID: String?
    @Published private(set) var message = "Prêt pour une démonstration locale."
    @Published private(set) var busy = false
    @Published private(set) var enabled = ActivityAuthorizationInfo().areActivitiesEnabled
    private var activity: Activity<LyricAttributes>?
    private var playbackTask: Task<Void, Never>?
    private var foreground = true

    var lineIndex: Int { DemoSong.index(at: elapsed) }
    var currentLine: String { DemoSong.lines[lineIndex] }
    var nextLine: String { lineIndex + 1 < DemoSong.lines.count ? DemoSong.lines[lineIndex + 1] : "Fin de la démonstration" }
    private var state: LyricAttributes.ContentState {
        .init(line: currentLine, nextLine: nextLine, lineNumber: lineIndex + 1, isPlaying: isPlaying)
    }
    private var content: ActivityContent<LyricAttributes.ContentState> {
        .init(state: state, staleDate: Date().addingTimeInterval(60))
    }
    private var isActive: Bool {
        guard let activity else { return false }
        return activity.activityState == .active || activity.activityState == .stale
    }

    func refresh() {
        enabled = ActivityAuthorizationInfo().areActivitiesEnabled
        if !isActive {
            playbackTask?.cancel()
            playbackTask = nil
            isPlaying = false
            activity = Activity<LyricAttributes>.activities.first {
                $0.activityState == .active || $0.activityState == .stale
            }
            if let activity {
                elapsed = Double(max(0, min(activity.content.state.lineNumber - 1, DemoSong.lines.count - 1))) * 6
                message = "Live Activity retrouvée. Lecture de démo en pause."
            }
        }
        activityID = activity?.id
    }

    func start() async {
        guard !busy, foreground else { return }
        busy = true
        defer { busy = false }
        refresh()
        guard enabled else {
            message = "Active les activités en direct dans les réglages iOS de LyricLive."
            return
        }
        if isActive {
            await publish()
            message = "L’activité existe déjà. Utilise Lecture ou Ligne suivante."
            return
        }
        elapsed = 0
        isPlaying = false
        do {
            activity = try Activity.request(
                attributes: LyricAttributes(title: DemoSong.title, artist: DemoSong.artist),
                content: content, pushType: nil)
            activityID = activity?.id
            message = "Live Activity créée. Vérifie l’écran verrouillé ou le tableau de bord CarPlay."
        } catch { message = "Création impossible : \(error.localizedDescription)" }
    }

    func nextLine() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        stopClock()
        elapsed = Double((lineIndex + 1) % DemoSong.lines.count) * 6
        await publish()
    }

    func previousLine() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        stopClock()
        elapsed = Double(max(0, lineIndex - 1)) * 6
        await publish()
    }

    func togglePlayback() async {
        guard !busy, foreground else { return }
        busy = true
        defer { busy = false }
        guard isActive else {
            refresh()
            message = "Démarre une Live Activity avant la lecture."
            return
        }
        if isPlaying {
            stopClock()
            await publish()
            return
        }
        if elapsed >= DemoSong.duration { elapsed = 0 }
        isPlaying = true
        await publish()
        guard foreground, isActive else { stopClock(); return }
        let baseElapsed = elapsed
        let started = ProcessInfo.processInfo.systemUptime
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { return }
                guard let self, self.foreground, self.isPlaying, !Task.isCancelled else { return }
                guard self.isActive else {
                    self.stopClock()
                    self.activity = nil
                    self.activityID = nil
                    self.message = "L’activité a été fermée par le système ou l’utilisateur."
                    return
                }
                let oldIndex = self.lineIndex
                self.elapsed = min(DemoSong.duration, baseElapsed + ProcessInfo.processInfo.systemUptime - started)
                if self.elapsed >= DemoSong.duration {
                    self.isPlaying = false
                    await self.publish()
                    self.message = "Fin de la démonstration. L’activité reste visible jusqu’à Arrêter."
                    return
                }
                if self.lineIndex != oldIndex { await self.publish() }
            }
        }
        message = "Défilement de démonstration au premier plan ; aucun audio n’est lu."
    }

    func setForeground(_ value: Bool) async {
        foreground = value
        if value {
            refresh()
            // An activity restored after process termination must not claim playback continues.
            if !isPlaying, isActive { await publish() }
        } else {
            stopClock()
            if isActive { await publish() }
            message = "Démo en pause hors premier plan. Pas de synchronisation d’arrière-plan simulée."
        }
    }

    func end() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        stopClock()
        // Clean up all restored instances of our own attributes type.
        for item in Activity<LyricAttributes>.activities {
            await item.end(content, dismissalPolicy: .immediate)
        }
        activity = nil
        activityID = nil
        message = "Toutes les Live Activities de LyricLive ont été arrêtées."
    }

    private func stopClock() {
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
    }

    private func publish() async {
        guard isActive, let activity else {
            activityID = nil
            message = "Aucune activité active. Appuie sur Démarrer."
            return
        }
        // No alertConfiguration: request a content update without an alert sound.
        await activity.update(content)
    }
}
