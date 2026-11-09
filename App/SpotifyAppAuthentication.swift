import Foundation
import SpotifyLogin

struct SpotifyAuthorizedSession: Sendable {
    let accessToken: String
    let refreshToken: String
    let expirationDate: Date
}

private enum SpotifyAppAuthError: LocalizedError {
    case notInstalled, refused, canceled, failed
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Installe l’app Spotify sur cet iPhone, puis réessaie."
        case .refused: return "Tu as refusé le partage de ta lecture Spotify."
        case .canceled: return "Connexion Spotify annulée."
        case .failed: return "Connexion Spotify impossible. Vérifie le Client ID, le Bundle ID, le Redirect URI et les utilisateurs autorisés dans Spotify Developer."
        }
    }
}

/// Spotify's maintained SDK owns the app-switch and PKCE exchange.
/// Only the initiating manager may complete its pending authorization.
@MainActor
final class SpotifyAppAuthentication: NSObject, SessionManagerDelegate {
    private var manager: SessionManager?
    private var pending: CheckedContinuation<SpotifyAuthorizedSession, Error>?

    func authorize(clientID: String) async throws -> SpotifyAuthorizedSession {
        cancel()
        try Task.checkCancellation()
        let configuration = Configuration(clientID: clientID,
            redirectURL: URL(string: SpotifyClient.redirectURI)!)
        let manager = SessionManager(configuration: configuration, delegate: self)
        guard manager.isSpotifyAppInstalled else { throw SpotifyAppAuthError.notInstalled }
        self.manager = manager
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            // No web fallback and no playURI: authorize without starting or changing music.
            manager.initiateSession(with: [Scope.userReadCurrentlyPlaying],
                authorizationFlow: .clientOnlyFailsIfNotInstalled)
        }
    }

    func handleURL(_ url: URL) {
        guard pending != nil, let manager,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == SpotifyClient.callbackScheme, parts.host == "callback",
              parts.path.isEmpty, parts.user == nil, parts.port == nil,
              parts.fragment == nil else { return }
        // Ignore duplicate callbacks after the SDK has accepted one code/error.
        guard !callbackConsumed else { return }
        callbackConsumed = true
        _ = manager.openURL(url)
    }

    private var callbackConsumed = false

    func cancel() {
        manager?.delegate = nil
        manager = nil
        callbackConsumed = false
        let continuation = pending
        pending = nil
        continuation?.resume(throwing: CancellationError())
    }

    private func finish(_ result: Result<SpotifyAuthorizedSession, Error>, manager incoming: SessionManager) {
        guard incoming === manager, let continuation = pending else { return }
        pending = nil
        manager?.delegate = nil
        manager = nil
        callbackConsumed = false
        continuation.resume(with: result)
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
