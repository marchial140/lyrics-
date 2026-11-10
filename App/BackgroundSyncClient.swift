import ActivityKit
import Combine
import Foundation
import Security
import SwiftUI

enum BackgroundSyncError: LocalizedError {
    case configuration, network, expired, appleToken, storage
    var errorDescription: String? {
        switch self {
        case .configuration: return "Renseigne l’adresse HTTPS de ton serveur LyricLive."
        case .network: return "Le serveur de suivi est inaccessible. Vérifie son adresse et sa configuration."
        case .expired: return "La session du serveur a expiré. Reconnecte Spotify et réactive le suivi."
        case .appleToken: return "Jeton Apple non reçu. Vérifie la capability Push Notifications et le profil Apple Developer."
        case .storage: return "Impossible d’enregistrer la session de suivi dans le trousseau."
        }
    }
}

@MainActor
final class BackgroundSyncClient: ObservableObject {
    static let shared = BackgroundSyncClient()
    @Published private(set) var enabled = false
    @Published private(set) var ready = false
    @Published private(set) var status = "Suivi en arrière-plan non configuré."
    private struct Credentials: Codable {
        var baseURL: String
        var id: String
        var secret: String
        var version: Int = 0
        var registered = false
        var pendingRevoke = false
    }
    private var credentials: Credentials?
    private var tokenTask: Task<Void, Never>?
    private var tokenDeadline: Task<Void, Never>?
    private var boundActivity: String?
    private var deleting = false
    private var creating = false
    private var hasRegistration = false
    private static var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "LyricLive") + ".background",
         kSecAttrAccount as String: "session"]
    }
    private init() {
        var query = Self.keychainQuery
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            credentials = try? JSONDecoder().decode(Credentials.self, from: data)
            enabled = credentials?.registered == true && credentials?.pendingRevoke == false
            if enabled { status = "Session serveur retrouvée. Active la Live Activity pour recevoir les mises à jour." }
        }
    }
    private func persist() throws {
        guard let credentials else {
            let result = SecItemDelete(Self.keychainQuery as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw BackgroundSyncError.storage }
            return
        }
        let data = try JSONEncoder().encode(credentials)
        let result = SecItemUpdate(Self.keychainQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var query = Self.keychainQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw BackgroundSyncError.storage }
        } else if result != errSecSuccess { throw BackgroundSyncError.storage }
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = format.date(from: text) { return date }
            format.formatOptions = [.withInternetDateTime]
            guard let date = format.date(from: text) else { throw BackgroundSyncError.network }
            return date
        }
        return decoder
    }
    private func call(_ method: String, suffix: String = "", body: Data? = nil) async throws -> Data {
        guard let saved = credentials, let base = URL(string: saved.baseURL) else { throw BackgroundSyncError.configuration }
        var url = base.appendingPathComponent("v1").appendingPathComponent("sessions").appendingPathComponent(saved.id)
        if !suffix.isEmpty { url.appendPathComponent(suffix) }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body; request.timeoutInterval = 15
        request.setValue("Bearer " + saved.secret, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw BackgroundSyncError.network }
        if response.statusCode == 401 { throw BackgroundSyncError.expired }
        guard (200...299).contains(response.statusCode) else { throw BackgroundSyncError.network }
        return data
    }
    func enable(baseURL input: String, tokens: SpotifyTokens) async throws {
        guard var url = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { throw BackgroundSyncError.configuration }
        url.path = ""
        if let previous = credentials, previous.baseURL != url.string {
            guard !previous.registered, !previous.pendingRevoke else { throw BackgroundSyncError.configuration }
            credentials?.baseURL = url.string!
            try persist()
        }
        if credentials == nil {
            var bytes = [UInt8](repeating: 0, count: 32)
            let result = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
            guard result == errSecSuccess else { throw BackgroundSyncError.storage }
            let secret = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            credentials = Credentials(baseURL: url.string!, id: UUID().uuidString.lowercased(), secret: secret)
            try persist()
        }
        creating = true
        defer { creating = false; retryPendingRevoke() }
        struct Body: Encodable { let tokens: SpotifyTokens }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        _ = try await call("PUT", body: encoder.encode(Body(tokens: tokens)))
        guard credentials?.pendingRevoke == false else { throw CancellationError() }
        credentials?.registered = true; credentials?.pendingRevoke = false
        try persist()
        enabled = true; ready = false
        status = "Serveur connecté. Active la Live Activity puis attends la confirmation Apple."
    }
    func playback() async throws -> SpotifyPlayback? {
        struct Envelope: Decodable { let playback: SpotifyPlayback?; let deliveryStatus: String? }
        let data = try await call("GET", suffix: "playback")
        let response = try Self.decoder().decode(Envelope.self, from: data)
        if let delivery = response.deliveryStatus { status = "Envoi Apple refusé : " + delivery; ready = false }
        else if hasRegistration {
            ready = true
            status = "Live Activity inscrite sur le serveur. Livraison soumise aux délais Apple."
        }
        return response.playback
    }
    func bind(_ activity: Activity<LyricAttributes>) {
        guard enabled, boundActivity != activity.id else { return }
        tokenTask?.cancel(); tokenDeadline?.cancel()
        boundActivity = activity.id; ready = false; hasRegistration = false
        credentials?.version += 1
        let version = credentials?.version ?? 1
        do { try persist() } catch { status = error.localizedDescription; return }
        status = "En attente du jeton Apple…"
        tokenDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, !self.ready, self.boundActivity == activity.id else { return }
            self.status = BackgroundSyncError.appleToken.localizedDescription
        }
        tokenTask = Task { [weak self] in
            guard let self else { return }
            if let token = activity.pushToken { await self.register(token, activity: activity.id, version: version) }
            for await token in activity.pushTokenUpdates {
                guard !Task.isCancelled, self.boundActivity == activity.id else { return }
                await self.register(token, activity: activity.id, version: version)
            }
        }
    }
    private func register(_ token: Data, activity: String, version: Int) async {
        struct Body: Encodable { let pushToken: String; let activityID: String; let version: Int; let frequent: Bool }
        let body = Body(pushToken: token.map { String(format: "%02x", $0) }.joined(), activityID: activity,
                        version: version, frequent: ActivityAuthorizationInfo().frequentPushesEnabled)
        for attempt in 0..<3 {
            guard enabled, boundActivity == activity, !Task.isCancelled else { return }
            do {
                _ = try await call("PUT", suffix: "activity", body: JSONEncoder().encode(body))
                guard boundActivity == activity, !Task.isCancelled else { return }
                ready = true; hasRegistration = true; tokenDeadline?.cancel()
                status = "Live Activity inscrite sur le serveur. Livraison soumise aux délais Apple."
                return
            } catch {
                status = "Inscription de la Live Activity échouée : " + error.localizedDescription
                if attempt < 2 { try? await Task.sleep(for: .seconds(3)) }
            }
        }
    }
    func stop() async throws -> SpotifyTokens? {
        struct Result: Decodable { let tokens: SpotifyTokens? }
        guard credentials != nil else { return nil }
        let restored: SpotifyTokens?
        do {
            let data = try await call("DELETE")
            restored = try Self.decoder().decode(Result.self, from: data).tokens
        }
        catch BackgroundSyncError.expired { restored = nil }
        tokenTask?.cancel(); tokenDeadline?.cancel()
        credentials = nil; try persist()
        enabled = false; ready = false; hasRegistration = false; boundActivity = nil
        status = "Suivi serveur arrêté et session effacée."
        return restored
    }
    func unbind() {
        tokenTask?.cancel(); tokenDeadline?.cancel()
        boundActivity = nil; ready = false; hasRegistration = false
        guard enabled else { return }
        credentials?.version += 1
        struct Body: Encodable { let version: Int }
        let body = Body(version: credentials?.version ?? 1)
        try? persist()
        Task { [weak self] in
            guard let self else { return }
            do { _ = try await self.call("DELETE", suffix: "activity", body: JSONEncoder().encode(body)) }
            catch { self.status = "Arrêt de la livraison non confirmé ; l’activité retirée ne peut plus afficher les mises à jour." }
        }
    }
    func revokeOnDisconnect() {
        guard credentials != nil else { return }
        credentials?.pendingRevoke = true
        try? persist()
        tokenTask?.cancel(); tokenDeadline?.cancel()
        enabled = false; ready = false
        retryPendingRevoke()
    }
    func retryPendingRevoke() {
        guard credentials?.pendingRevoke == true, !deleting, !creating else { return }
        deleting = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.deleting = false }
            do { _ = try await self.stop() }
            catch { self.status = "Arrêt serveur non confirmé. Nouvelle tentative au retour dans l’app ; expiration automatique après six heures maximum." }
        }
    }
}

struct BackgroundSettingsView: View {
    @ObservedObject var spotify: SpotifyClient
    @ObservedObject private var sync = BackgroundSyncClient.shared
    @AppStorage("backgroundServerURL") private var serverURL = ""
    var body: some View {
        DisclosureGroup("Suivi avec l’iPhone verrouillé") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ce mode utilise ton serveur LyricLive pour suivre Spotify et envoyer les lignes à Apple. Il recevra ta session Spotify et les informations du morceau. Les délais de livraison dépendent d’iOS.")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("Adresse HTTPS du serveur", text: $serverURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .disabled(sync.enabled || spotify.backgroundBusy)
                if sync.enabled {
                    Button("Désactiver le suivi serveur", role: .destructive) {
                        Task { await spotify.disableBackground() }
                    }.disabled(spotify.backgroundBusy)
                } else {
                    Button("Activer le suivi serveur") {
                        Task { await spotify.enableBackground(serverURL: serverURL) }
                    }.disabled(!spotify.connected || spotify.backgroundBusy)
                }
                if spotify.backgroundBusy { ProgressView() }
                Text(sync.status).font(.footnote).foregroundStyle(.secondary)
            }.padding(.top, 12)
        }
    }
}
