import Combine
import Foundation
import Security
import UIKit

struct SpotifyPlayback: Decodable {
    struct Item: Decodable {
        struct Artist: Decodable { let name: String }
        struct Image: Decodable { let url: URL }
        struct Album: Decodable { let images: [Image]; let name: String? }
        struct Links: Decodable { let spotify: URL? }
        let name: String
        let type: String
        let id: String?
        let uri: String?
        let duration_ms: Int?
        let artists: [Artist]?
        let album: Album?
        let external_urls: Links?
    }
    let is_playing: Bool
    let progress_ms: Int?
    let item: Item?
    let currently_playing_type: String?
}

struct SpotifyTokens: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let clientID: String
}

private enum TokenVault {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "LyricLive") + ".spotify",
         kSecAttrAccount as String: "oauth"]
    }
    static func load() throws -> SpotifyTokens? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw SpotifyError.storage }
        return try JSONDecoder().decode(SpotifyTokens.self, from: data)
    }
    static func save(_ tokens: SpotifyTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw SpotifyError.storage }
        } else if status != errSecSuccess { throw SpotifyError.storage }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SpotifyError.storage }
    }
}

private enum SpotifyError: LocalizedError {
    case configuration, callback, authorization, storage, expired, forbidden, network(Int), rateLimit(TimeInterval)
    var errorDescription: String? {
        switch self {
        case .configuration: return "La connexion Spotify n’est pas encore configurée pour cette version de LyricLive. Le développeur doit ajouter son Client ID Spotify."
        case .callback: return "Retour Spotify invalide. Vérifie le Redirect URI et réessaie."
        case .authorization: return "Connexion Spotify refusée ou impossible. Vérifie le Client ID et les utilisateurs autorisés."
        case .storage: return "Impossible d’accéder au trousseau sécurisé. Déverrouille l’iPhone et réessaie."
        case .expired: return "Session Spotify expirée ou révoquée. Reconnecte-toi."
        case .forbidden: return "Accès Spotify refusé (403). Vérifie le compte de test, les autorisations et le mode développement."
        case .network(let code): return "Spotify est indisponible (HTTP \(code)). Nouvelle tentative automatique."
        case .rateLimit: return "Limite Spotify atteinte. Les requêtes reprendront après le délai demandé par Spotify."
        }
    }
}

@MainActor
final class SpotifyClient: NSObject, ObservableObject {
    static let callbackScheme = "com.lyriclive.spotify"
    static let redirectURI = "com.lyriclive.spotify://callback"
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var playback: SpotifyPlayback?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var status = "Connecte Spotify pour voir ce que tu écoutes."
    @Published private(set) var foreground = false
    @Published private(set) var backgroundBusy = false
    private var tokens: SpotifyTokens?
    private let appAuthentication = SpotifyAppAuthentication()
    private var polling: Task<Void, Never>?
    private var authentication: Task<Void, Never>?
    private var generation = UUID()
    private var pollID = UUID()
    private var nextAllowedRequest = Date.distantPast

    override init() {
        super.init()
        do {
            tokens = try TokenVault.load()
            connected = tokens != nil
            if connected { status = "Session Spotify retrouvée." }
        } catch { status = "Session enregistrée inaccessible. Reconnecte Spotify." }
    }

    func connect(clientID input: String) {
        guard !connecting else { return }
        let clientID = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clientID.range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil else {
            status = SpotifyError.configuration.localizedDescription
            return
        }
        connecting = true
        status = "Valide le partage de ta lecture dans l’app Spotify, puis reviens dans LyricLive."
        polling?.cancel()
        polling = nil
        generation = UUID()
        let loginID = generation
        authentication = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == loginID { self.connecting = false; self.authentication = nil } }
            do {
                try self.check(loginID)
                let authorized = try await self.appAuthentication.authorize(clientID: clientID) { [weak self] message in
                    guard let self, self.generation == loginID else { return }
                    self.status = message
                }
                try self.check(loginID)
                let saved = SpotifyTokens(accessToken: authorized.accessToken,
                    refreshToken: authorized.refreshToken,
                    expiresAt: authorized.expirationDate, clientID: clientID)
                try TokenVault.save(saved)
                self.tokens = saved
                self.connected = true
                self.status = "Spotify connecté. Lecture du morceau en cours…"
                self.startPolling()
            } catch is CancellationError {
                // Disconnect invalidates callbacks and any in-flight authorization.
            } catch {
                guard self.generation == loginID else { return }
                self.status = error.localizedDescription
                if self.connected { self.startPolling() }
            }
        }
    }

    func handleURL(_ url: URL) {
        appAuthentication.handleURL(url)
    }

    func disconnect() {
        BackgroundSyncClient.shared.revokeOnDisconnect()
        generation = UUID()
        pollID = UUID()
        polling?.cancel(); polling = nil
        authentication?.cancel(); authentication = nil
        appAuthentication.cancel()
        tokens = nil
        connected = false
        connecting = false
        playback = nil
        lastUpdated = nil
        do { try TokenVault.delete(); status = "Spotify déconnecté de cet iPhone." }
        catch { status = "Déconnecté en mémoire, mais le trousseau n’a pas pu être effacé. Réessaie une fois l’iPhone déverrouillé." }
    }

    func setForeground(_ active: Bool) {
        foreground = active
        appAuthentication.setForeground(active)
        if active { BackgroundSyncClient.shared.retryPendingRevoke(); startPolling() }
        else {
            pollID = UUID()
            polling?.cancel(); polling = nil
        }
    }

    private func startPolling() {
        guard foreground, connected, !backgroundBusy, polling == nil else { return }
        let loginID = generation
        let currentPoll = UUID()
        pollID = currentPoll
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == loginID, self.pollID == currentPoll,
                      self.foreground, self.connected else { return }
                let wait = self.nextAllowedRequest.timeIntervalSinceNow
                if wait > 0 {
                    do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                }
                do {
                    try await self.fetchPlayback(loginID: loginID, currentPoll: currentPoll)
                } catch is CancellationError { return }
                catch {
                    guard self.generation == loginID, self.pollID == currentPoll else { return }
                    self.playback = nil
                    self.lastUpdated = nil
                    self.status = error.localizedDescription
                    if case BackgroundSyncError.expired = error {
                        self.disconnect(); self.status = BackgroundSyncError.expired.localizedDescription; return
                    }
                    if case SpotifyError.expired = error {
                        self.disconnect()
                        self.status = SpotifyError.expired.localizedDescription
                        return
                    }
                    if case SpotifyError.forbidden = error {
                        // Stop retrying a permanent permission failure until foregrounding again.
                        self.polling = nil
                        return
                    }
                    if case SpotifyError.rateLimit(let seconds) = error {
                        self.nextAllowedRequest = Date().addingTimeInterval(seconds)
                    } else {
                        self.nextAllowedRequest = Date().addingTimeInterval(10)
                    }
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func check(_ loginID: UUID, poll: UUID? = nil) throws {
        try Task.checkCancellation()
        guard loginID == generation, poll == nil || poll == pollID else { throw CancellationError() }
    }

    func enableBackground(serverURL: String) async {
        guard connected, !backgroundBusy else { return }
        backgroundBusy = true
        defer { backgroundBusy = false; startPolling() }
        polling?.cancel(); polling = nil
        let expected = generation
        do {
            _ = try await validAccessToken(loginID: expected, force: false)
            guard let tokens else { throw SpotifyError.expired }
            try await BackgroundSyncClient.shared.enable(baseURL: serverURL, tokens: tokens)
            try check(expected)
            status = "Suivi serveur activé. Active ensuite la Live Activity."
        } catch { status = error.localizedDescription }
    }

    func disableBackground() async {
        guard !backgroundBusy else { return }
        backgroundBusy = true
        defer { backgroundBusy = false; startPolling() }
        polling?.cancel(); polling = nil
        let expected = generation
        do {
            let restored = try await BackgroundSyncClient.shared.stop()
            try check(expected)
            if let restored { try TokenVault.save(restored); tokens = restored }
            status = "Suivi serveur arrêté."
        } catch { status = "L’arrêt du serveur n’a pas été confirmé : " + error.localizedDescription }
    }

    private func fetchPlayback(loginID: UUID, currentPoll: UUID) async throws {
        if BackgroundSyncClient.shared.enabled {
            let current = try await BackgroundSyncClient.shared.playback()
            try check(loginID, poll: currentPoll)
            playback = current; lastUpdated = Date()
            status = current?.is_playing == true ? "Lecture suivie par le serveur" : "Serveur connecté · Lecture absente ou en pause"
            return
        }
        for attempt in 0...1 {
            let token = try await validAccessToken(loginID: loginID, force: attempt == 1)
            try check(loginID, poll: currentPoll)
            var request = URLRequest(url: URL(string: "https://api.spotify.com/v1/me/player/currently-playing")!)
            request.timeoutInterval = 20
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            try check(loginID, poll: currentPoll)
            guard let response = response as? HTTPURLResponse else { throw SpotifyError.network(0) }
            switch response.statusCode {
            case 200:
                let decoded = try JSONDecoder().decode(SpotifyPlayback.self, from: data)
                playback = decoded
                lastUpdated = Date()
                if decoded.item?.type == "track" {
                    status = decoded.is_playing ? "Lecture en cours · Actualisation toutes les 3 secondes" : "Spotify en pause"
                } else { status = "Aucun morceau musical disponible (publicité, podcast ou session privée)." }
                return
            case 204:
                playback = nil; lastUpdated = Date()
                status = "Aucune lecture détectée. Lance un morceau dans Spotify."
                return
            case 401:
                if attempt == 1 { throw SpotifyError.expired }
            case 403: throw SpotifyError.forbidden
            case 429: throw SpotifyError.rateLimit(Self.retryDelay(response))
            default: throw SpotifyError.network(response.statusCode)
            }
        }
    }

    private func validAccessToken(loginID: UUID, force: Bool) async throws -> String {
        guard let saved = tokens else { throw SpotifyError.expired }
        if !force, saved.expiresAt.timeIntervalSinceNow > 60 { return saved.accessToken }
        let response = try await tokenRequest([
            "grant_type": "refresh_token", "refresh_token": saved.refreshToken, "client_id": saved.clientID
        ], refreshing: true)
        try check(loginID)
        let renewed = SpotifyTokens(accessToken: response.access_token,
            refreshToken: response.refresh_token ?? saved.refreshToken,
            expiresAt: Date().addingTimeInterval(response.expires_in), clientID: saved.clientID)
        try TokenVault.save(renewed)
        tokens = renewed
        return renewed.accessToken
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Double
    }
    private func tokenRequest(_ fields: [String: String], refreshing: Bool) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // RFC 3986 percent encoding keeps '+' and '&' out of individual form values.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = Data(fields.sorted(by: { $0.key < $1.key }).map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" +
            $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw SpotifyError.network(0) }
        if response.statusCode == 429 { throw SpotifyError.rateLimit(Self.retryDelay(response)) }
        if response.statusCode == 400 || response.statusCode == 401 {
            throw refreshing ? SpotifyError.expired : SpotifyError.authorization
        }
        guard response.statusCode == 200 else { throw SpotifyError.network(response.statusCode) }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func retryDelay(_ response: HTTPURLResponse) -> TimeInterval {
        max(3, Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 30)
    }
}

