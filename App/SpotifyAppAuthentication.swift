import Foundation
import SpotifyLogin

struct SpotifyAuthorizedSession: Sendable {
    let accessToken: String
    let refreshToken: String
    let expirationDate: Date
}

private enum SpotifyAppAuthError: LocalizedError {
    case notInstalled, refused, canceled, failed, invalidCallback, noCallback, exchangeTimeout, authorizationTimeout
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Installe l’app Spotify sur cet iPhone, puis réessaie."
        case .refused: return "Tu as refusé le partage de ta lecture Spotify."
        case .canceled: return "Connexion Spotify annulée."
        case .failed: return "Connexion Spotify impossible. Vérifie le Client ID, le Bundle ID, le Redirect URI et les utilisateurs autorisés dans Spotify Developer."
        case .invalidCallback: return "Le retour Spotify est invalide. Le Redirect URI doit être exactement com.lyriclive.spotify://callback. Réessaie la connexion."
        case .noCallback: return "Spotify n’a pas renvoyé l’autorisation à LyricLive. Accepte la demande dans Spotify et laisse Spotify te ramener ici. Vérifie aussi le Redirect URI : com.lyriclive.spotify://callback."
        case .exchangeTimeout: return "Le retour Spotify a été reçu, mais la finalisation a dépassé 20 secondes. Vérifie ta connexion Internet puis réessaie."
        case .authorizationTimeout: return "La connexion Spotify a expiré. Appuie sur Connecter Spotify pour réessayer."
        }
    }
}

/// Retains the SDK manager until completion, cancellation or an explicit deadline.
/// Every terminal path resumes the pending continuation exactly once.
@MainActor
final class SpotifyAppAuthentication: NSObject, SessionManagerDelegate {
    private var manager: SessionManager?
    private var pending: CheckedContinuation<SpotifyAuthorizedSession, Error>?
    private var attemptID = UUID()
    private var callbackConsumed = false
    private var leftApp = false
    private var deadline: Task<Void, Never>?
    private var returnDeadline: Task<Void, Never>?
    private var progress: ((String) -> Void)?

    func authorize(clientID: String, onProgress: @escaping (String) -> Void) async throws -> SpotifyAuthorizedSession {
        cancel()
        try Task.checkCancellation()
        let configuration = Configuration(clientID: clientID,
            redirectURL: URL(string: SpotifyClient.redirectURI)!)
        let manager = SessionManager(configuration: configuration, delegate: self)
        guard manager.isSpotifyAppInstalled else { throw SpotifyAppAuthError.notInstalled }
        self.manager = manager
        progress = onProgress
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            armDeadline(seconds: 120, error: .authorizationTimeout)
            manager.initiateSession(with: [Scope.userReadCurrentlyPlaying],
                authorizationFlow: .clientOnlyFailsIfNotInstalled)
        }
    }

    func setForeground(_ active: Bool) {
        guard pending != nil else { return }
        if !active {
            leftApp = true
            returnDeadline?.cancel()
            returnDeadline = nil
        } else if leftApp, !callbackConsumed {
            // SwiftUI can report foreground before onOpenURL. Allow that event to arrive.
            let expected = attemptID
            returnDeadline?.cancel()
            returnDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, self.attemptID == expected, self.pending != nil,
                      !self.callbackConsumed else { return }
                self.complete(.failure(SpotifyAppAuthError.noCallback))
            }
        }
    }

    func handleURL(_ url: URL) {
        guard pending != nil, let manager,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == SpotifyClient.callbackScheme else { return }
        guard !callbackConsumed else { return }
        // A trailing slash is equivalent here; normalize it before handing off to the SDK.
        guard parts.host?.lowercased() == "callback", ["", "/"].contains(parts.path),
              parts.user == nil, parts.password == nil, parts.port == nil else {
            complete(.failure(SpotifyAppAuthError.invalidCallback))
            return
        }
        var query = parts.queryItems ?? []
        if let fragment = parts.percentEncodedFragment, !fragment.isEmpty {
            guard query.isEmpty, let parsed = URLComponents(string: "https://callback.invalid/?" + fragment) else {
                complete(.failure(SpotifyAppAuthError.invalidCallback)); return
            }
            query = parsed.queryItems ?? []
        }
        let codes = query.filter { $0.name == "code" }
        let errors = query.filter { $0.name == "error" }
        let validCode = codes.count == 1 && !(codes.first?.value ?? "").isEmpty && errors.isEmpty
        let validError = errors.count == 1 && !(errors.first?.value ?? "").isEmpty && codes.isEmpty
        guard validCode || validError else {
            // Do not accept legacy implicit-flow access tokens in URL fragments.
            complete(.failure(SpotifyAppAuthError.invalidCallback))
            return
        }
        var canonical = URLComponents(string: SpotifyClient.redirectURI)!
        canonical.queryItems = query
        guard let callback = canonical.url else {
            complete(.failure(SpotifyAppAuthError.invalidCallback)); return
        }
        callbackConsumed = true
        returnDeadline?.cancel()
        returnDeadline = nil
        progress?("Retour Spotify reçu. Finalisation de la connexion…")
        armDeadline(seconds: 20, error: .exchangeTimeout)
        if !manager.openURL(callback) {
            complete(.failure(SpotifyAppAuthError.invalidCallback))
        }
    }

    func cancel() {
        complete(.failure(CancellationError()))
    }

    private func armDeadline(seconds: Double, error: SpotifyAppAuthError) {
        deadline?.cancel()
        let expected = attemptID
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.attemptID == expected, self.pending != nil else { return }
            self.complete(.failure(error))
        }
    }

    private func complete(_ result: Result<SpotifyAuthorizedSession, Error>) {
        deadline?.cancel(); deadline = nil
        returnDeadline?.cancel(); returnDeadline = nil
        manager?.delegate = nil
        manager = nil
        attemptID = UUID()
        callbackConsumed = false
        leftApp = false
        progress = nil
        let continuation = pending
        pending = nil
        continuation?.resume(with: result)
    }

    private func finish(_ result: Result<SpotifyAuthorizedSession, Error>, manager incoming: SessionManager) {
        guard incoming === manager, pending != nil else { return }
        complete(result)
    }

    nonisolated func sessionManager(manager: SessionManager, didInitiate session: Session) {
        let authorized = SpotifyAuthorizedSession(accessToken: session.accessToken,
            refreshToken: session.refreshToken, expirationDate: session.expirationDate)
        let hasScope = session.scopes.contains(.userReadCurrentlyPlaying)
        Task { @MainActor [weak self] in
            guard hasScope else { self?.finish(.failure(SpotifyAppAuthError.refused), manager: manager); return }
            self?.finish(.success(authorized), manager: manager)
        }
    }

    nonisolated func sessionManager(manager: SessionManager, didFailWith error: Error) {
        let mapped: SpotifyAppAuthError
        switch error as? SpotifyLogin.SpotifyError {
        case .accessDenied: mapped = .refused
        case .authorizationCancelled: mapped = .canceled
        default: mapped = .failed
        }
        Task { @MainActor [weak self] in
            self?.finish(.failure(mapped), manager: manager)
        }
    }
}
