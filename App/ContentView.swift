import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var controller = LiveActivityController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Label("LIVE ACTIVITY · CARPLAY", systemImage: "waveform")
                        .font(.caption.weight(.bold)).foregroundStyle(.mint)
                    Text("Tes paroles,\nau bon endroit.")
                        .font(.largeTitle.bold())
                    Text("Prototype local · Texte original · Sans audio")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 16) {
                        Label(DemoSong.title, systemImage: "music.note")
                            .font(.headline).foregroundStyle(.mint)
                        Text(controller.currentLine)
                            .font(.title2.bold()).fixedSize(horizontal: false, vertical: true)
                        Text(controller.nextLine).foregroundStyle(.secondary)
                        ProgressView(value: controller.elapsed, total: DemoSong.duration)
                            .tint(.mint).accessibilityLabel("Progression de démonstration")
                        Text("Ligne \(controller.lineIndex + 1) sur \(DemoSong.lines.count) · \(Int(controller.elapsed)) / 30 s")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))

                    Button { Task { await controller.start() } } label: {
                        Label("Démarrer la Live Activity", systemImage: "play.rectangle.on.rectangle")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)

                    VStack(spacing: 12) {
                        Button(controller.isPlaying ? "Pause" : "Lire la démo de 30 secondes") {
                            Task { await controller.togglePlayback() }
                        }.buttonStyle(.bordered)
                        HStack {
                            Button { Task { await controller.previousLine() } } label: {
                                Label("Précédente", systemImage: "backward.end.fill")
                            }
                            Spacer()
                            Button { Task { await controller.nextLine() } } label: {
                                Label("Suivante", systemImage: "forward.end.fill")
                            }
                        }.buttonStyle(.bordered)
                        Button("Arrêter et retirer l’activité", role: .destructive) {
                            Task { await controller.end() }
                        }.buttonStyle(.bordered)
                    }
                    Text(controller.message).font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("activityStatus")
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tester dans ton auto").font(.headline)
                        Text("À l’arrêt, connecte ton iPhone sous iOS 26 ou plus récent à CarPlay. Démarre l’activité, puis ouvre le tableau de bord CarPlay. L’affichage est géré par iOS et les réglages de ton auto.")
                        Text("Le défilement automatique s’arrête lorsque l’app quitte le premier plan. La dernière ligne peut rester visible, avec l’indication Pause. Ce prototype ne se connecte pas à Spotify.")
                        Button("Réglages iOS") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        Text(controller.enabled ? "Activités en direct autorisées" : "Activités en direct désactivées")
                            .font(.caption).foregroundStyle(.secondary)
                        if let id = controller.activityID {
                            Text("ID : \(id)").font(.caption2).textSelection(.enabled)
                        }
                    }.font(.callout)
                }.padding(24).disabled(controller.busy)
            }.background(Color(red: 0.025, green: 0.045, blue: 0.055))
                .navigationTitle("LyricLive").navigationBarTitleDisplayMode(.inline)
                .task { await controller.setForeground(scenePhase == .active) }
                .onChange(of: scenePhase) { _, phase in
                    Task { await controller.setForeground(phase == .active) }
                }
        }
    }
}
