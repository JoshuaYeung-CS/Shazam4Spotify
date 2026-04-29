import AuthenticationServices
import CryptoKit
import Foundation
import UIKit

@MainActor
final class SpotifyAuth: NSObject, ObservableObject {
    @Published private(set) var isSignedIn: Bool = false

    private var webAuthSession: ASWebAuthenticationSession?
    private var refreshTask: Task<SpotifyTokens, Error>?

    override init() {
        super.init()
        Task { await refreshSignedInState() }
    }

    func refreshSignedInState() async {
        let tokens = await TokenStore.shared.load()
        isSignedIn = tokens != nil
    }

    func signIn() async throws {
        let verifier = Self.makeCodeVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = UUID().uuidString

        var components = URLComponents(url: Config.spotifyAuthorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Config.spotifyClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Config.spotifyRedirectURI),
            URLQueryItem(name: "scope", value: Config.spotifyScopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
        ]

        let callbackURL = try await startWebAuth(authURL: components.url!)
        guard let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              let returnedState = comps.queryItems?.first(where: { $0.name == "state" })?.value,
              returnedState == state,
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            throw AuthError.invalidCallback
        }

        let tokens = try await exchangeCode(code, verifier: verifier)
        try await TokenStore.shared.save(tokens)
        isSignedIn = true
    }

    func signOut() async {
        await TokenStore.shared.clear()
        isSignedIn = false
    }

    func validAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let tokens = await TokenStore.shared.load() else { throw AuthError.notSignedIn }
        if !forceRefresh && !tokens.isExpired { return tokens.accessToken }

        if let inflight = refreshTask {
            return try await inflight.value.accessToken
        }
        let task = Task<SpotifyTokens, Error> { [refreshToken = tokens.refreshToken] in
            let fresh = try await self.refresh(refreshToken: refreshToken)
            try await TokenStore.shared.save(fresh)
            return fresh
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value.accessToken
        } catch {
            // Only sign out on hard auth failures (400/401). Transient errors (5xx, network) bubble up
            // so the caller can retry without forcing the user to re-auth.
            if let auth = error as? AuthError, auth.requiresReauth {
                await TokenStore.shared.clear()
                isSignedIn = false
            }
            throw error
        }
    }

    private func startWebAuth(authURL: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "shazam2spotify"
            ) { url, err in
                if let err {
                    let nsErr = err as NSError
                    if nsErr.domain == ASWebAuthenticationSessionError.errorDomain,
                       nsErr.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        cont.resume(throwing: AuthError.userCancelled)
                    } else {
                        cont.resume(throwing: err)
                    }
                    return
                }
                guard let url else { cont.resume(throwing: AuthError.invalidCallback); return }
                cont.resume(returning: url)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.webAuthSession = session
            session.start()
        }
    }

    private func exchangeCode(_ code: String, verifier: String) async throws -> SpotifyTokens {
        var req = URLRequest(url: Config.spotifyTokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formURLEncoded([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Config.spotifyRedirectURI,
            "client_id": Config.spotifyClientID,
            "code_verifier": verifier,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AuthError.tokenExchangeFailed(status: -1, body: "") }
        guard http.statusCode == 200 else {
            throw AuthError.tokenExchangeFailed(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try decodeTokens(from: data, fallbackRefresh: nil)
    }

    private func refresh(refreshToken: String) async throws -> SpotifyTokens {
        var req = URLRequest(url: Config.spotifyTokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formURLEncoded([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Config.spotifyClientID,
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AuthError.tokenExchangeFailed(status: -1, body: "") }
        guard http.statusCode == 200 else {
            throw AuthError.tokenExchangeFailed(status: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        return try decodeTokens(from: data, fallbackRefresh: refreshToken)
    }

    private func decodeTokens(from data: Data, fallbackRefresh: String?) throws -> SpotifyTokens {
        struct Resp: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int
        }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        guard let refresh = r.refresh_token ?? fallbackRefresh else {
            throw AuthError.tokenExchangeFailed("missing refresh token")
        }
        return SpotifyTokens(
            accessToken: r.access_token,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(TimeInterval(r.expires_in))
        )
    }

    private func formURLEncoded(_ params: [String: String]) -> Data {
        var comps = URLComponents()
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((comps.percentEncodedQuery ?? "").utf8)
    }

    private static func makeCodeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    enum AuthError: Error, LocalizedError {
        case userCancelled
        case invalidCallback
        case tokenExchangeFailed(status: Int, body: String)
        case notSignedIn

        var errorDescription: String? {
            switch self {
            case .userCancelled: return "Sign-in cancelled."
            case .invalidCallback: return "Spotify returned an invalid response."
            case .tokenExchangeFailed(let s, let b):
                return "Spotify token exchange failed (HTTP \(s)): \(b.isEmpty ? "no response body" : b)"
            case .notSignedIn: return "Not signed in to Spotify."
            }
        }

        /// Returns true if the failure indicates the refresh token is no longer valid.
        var requiresReauth: Bool {
            if case .tokenExchangeFailed(let status, _) = self {
                return status == 400 || status == 401
            }
            return false
        }
    }
}

extension SpotifyAuth: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first ?? ASPresentationAnchor()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
