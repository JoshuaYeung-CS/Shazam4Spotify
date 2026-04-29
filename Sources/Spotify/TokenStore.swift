import Foundation
import Security

struct SpotifyTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-30) }
}

actor TokenStore {
    static let shared = TokenStore()

    private let service = "com.joshuayeung.shazam2spotify"
    private let account = "spotify-tokens"

    private var cache: SpotifyTokens?

    func load() -> SpotifyTokens? {
        if let cache { return cache }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let tokens = try? JSONDecoder().decode(SpotifyTokens.self, from: data)
        else { return nil }
        cache = tokens
        return tokens
    }

    func save(_ tokens: SpotifyTokens) throws {
        cache = tokens
        let data = try JSONEncoder().encode(tokens)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus != errSecSuccess { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func clear() {
        cache = nil
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    struct KeychainError: Error { let status: OSStatus }
}
