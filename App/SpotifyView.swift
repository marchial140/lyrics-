import SwiftUI

struct SpotifyView: View {
    @ObservedObject var client: SpotifyClient
    @AppStorage("spotifyClientID") private var clientID = ""
    @State private var showConfiguration = false
    @State private var connectAfterDismiss = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Spotify").font(.title2.bold())
                Spacer()
                if client.connected {
                    Label("Connecté", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            }
            if !client.connected {
                Button {
                    if clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        showConfiguration = true
                    } else { client.connect(clientID: clientID) }
                } label: {
                    HStack {
                        if client.connecting { ProgressView().tint(.black) }
                        Label(client.connecting ? "Connexion…" : "Connecter Spotify", systemImage: "person.crop.circle.badge.checkmark")
                    }.frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).tint(.green).foregroundStyle(.black)
                .disabled(client.connecting)
                Text("Autorise seulement la lecture du morceau en cours. Aucun contrôle de ta musique n’est demandé.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let playback = client.playback, let item = playback.item, item.type == "track" {
                HStack(alignment: .top, spacing: 14) {
                    AsyncImage(url: item.album?.images.first?.url) { image in
                        image.resizable().scaledToFit()
                    } placeholder: {
                        Image(systemName: "music.note").frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(.white.opacity(0.08))
                    }
                    .frame(width: 84, height: 84)
                    .accessibilityLabel("Pochette de l’album")
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text(item.artists?.map(\.name).joined(separator: ", ") ?? "Artiste indisponible")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Label(playback.is_playing ? "En lecture" : "En pause",
                              systemImage: playback.is_playing ? "waveform" : "pause.fill")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
                if let duration = item.duration_ms, duration > 0 {
                    let progress = min(max(playback.progress_ms ?? 0, 0), duration)
                    ProgressView(value: Double(progress), total: Double(duration))
                        .tint(.green).accessibilityLabel("Progression Spotify")
                    HStack {
                        Text(time(progress))
                        Spacer()
                        Text(time(duration))
                    }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let url = item.external_urls?.spotify, url.scheme == "https" {
                    Link("Écouter sur Spotify", destination: url).font(.callout)
                }
            }
            Text(client.foreground ? client.status : "Actualisation suspendue hors premier plan.")
                .font(.callout).foregroundStyle(.secondary)
                .accessibilityIdentifier("spotifyStatus")
            if let updated = client.lastUpdated {
                Text("Dernière vérification : \(updated.formatted(date: .omitted, time: .standard))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Button("Configurer Spotify") { showConfiguration = true }
                    .disabled(client.connecting)
                Spacer()
                if client.connected || client.connecting {
                    Button(client.connecting ? "Annuler" : "Déconnecter", role: .destructive) {
                        client.disconnect()
                    }
                }
            }.font(.footnote)
        }
        .padding(20).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24))
        .sheet(isPresented: $showConfiguration, onDismiss: {
            if connectAfterDismiss {
                connectAfterDismiss = false
                client.connect(clientID: clientID)
            }
        }) { configuration }
    }

    private var configuration: some View {
        NavigationStack {
            Form {
                Section("Ton application Spotify") {
                    TextField("Client ID Spotify", text: $clientID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .disabled(client.connected || client.connecting)
                    Text("Le Client ID est public. Ne saisis jamais de Client Secret ici.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Pour modifier le Client ID, déconnecte d’abord Spotify.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("À enregistrer dans le tableau de bord Spotify") {
                    LabeledContent("Redirect URI") {
                        Text(SpotifyClient.redirectURI).font(.footnote).textSelection(.enabled)
                    }
                    Text("Ajoute exactement cette adresse aux Redirect URIs de ton app Spotify et ajoute ton compte dans les utilisateurs autorisés du mode développement.")
                    Link("Ouvrir Spotify for Developers", destination: URL(string: "https://developer.spotify.com/dashboard")!)
                }
                Section {
                    Button("Enregistrer et connecter") {
                        connectAfterDismiss = true
                        showConfiguration = false
                    }.disabled(client.connected || client.connecting)
                }
            }
            .navigationTitle("Connexion Spotify").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Fermer") { showConfiguration = false }
            } }
        }.preferredColorScheme(.dark)
    }

    private func time(_ milliseconds: Int) -> String {
        let seconds = max(0, milliseconds / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
