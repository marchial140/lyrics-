import SwiftUI

struct ContentView: View {
    @ObservedObject var spotify: SpotifyClient
    @StateObject private var lyrics = LyricsController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    SpotifyView(client: spotify)
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Label("Paroles", systemImage: "text.quote").font(.title2.bold())
                            Spacer()
                            if lyrics.loading { ProgressView() }
                        }
                        if let track = lyrics.track {
                            Text(track.title).font(.headline)
                            Text(track.artist).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(lyrics.message).font(.callout).foregroundStyle(.secondary)
                            .accessibilityIdentifier("lyricsStatus")
                        if !lyrics.lines.isEmpty {
                            timedLyrics
                        } else if !lyrics.plainLyrics.isEmpty {
                            Text(lyrics.plainLyrics).font(.title3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if lyrics.track != nil {
                            Button("Rechercher à nouveau") { lyrics.reload() }
                                .disabled(lyrics.loading || !lyrics.foreground)
                        }
                        Link("Source : LRCLIB", destination: URL(string: "https://lrclib.net")!)
                            .font(.footnote)
                    }
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24))

                    Button {
                        lyrics.setLiveEnabled(!lyrics.liveEnabled)
                    } label: {
                        Label(lyrics.liveEnabled ? "Arrêter la Live Activity" : "Afficher les paroles dans la Live Activity",
                              systemImage: lyrics.liveEnabled ? "stop.circle" : "rectangle.on.rectangle")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(.black)
                    .disabled(lyrics.track == nil && !lyrics.liveEnabled)
                    Text(lyrics.liveMessage).font(.footnote).foregroundStyle(.secondary)
                    Text("Le suivi se met à jour lorsque LyricLive reste au premier plan. Hors de l’app, la Live Activity indique que le suivi est suspendu. L’affichage CarPlay est géré par iOS.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding(24)
            }
            .background(Color(red: 0.025, green: 0.045, blue: 0.055))
            .navigationTitle("LyricLive").navigationBarTitleDisplayMode(.inline)
            .onReceive(spotify.$playback) { lyrics.accept($0) }
            .task {
                lyrics.setForeground(scenePhase == .active)
                spotify.setForeground(scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, phase in
                lyrics.setForeground(phase == .active)
                spotify.setForeground(phase == .active)
            }
        }
    }

    private var timedLyrics: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.title3.weight(index == lyrics.activeIndex ? .bold : .regular))
                            .foregroundStyle(index == lyrics.activeIndex ? Color.mint : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }.padding(.vertical, 16)
            }
            .frame(height: 380)
            .onChange(of: lyrics.activeIndex) { _, index in
                if let index {
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(index, anchor: .center) }
                }
            }
        }
    }
}
