import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let targetPlaylistID = "targetPlaylistID"
        static let targetPlaylistName = "targetPlaylistName"
        static let hapticsEnabled = "hapticsEnabled"
        static let userDisplayName = "userDisplayName"
        static let saveToLikedSongs = "saveToLikedSongs"
        static let saveToShazamPlaylist = "saveToShazamPlaylist"
        static let additionalPlaylistIDs = "additionalPlaylistIDs"
        static let additionalPlaylistNames = "additionalPlaylistNames"
    }

    /// Legacy single-target playlist — kept for migration but no longer the primary destination model.
    @Published var targetPlaylistID: String? {
        didSet { UserDefaults.standard.set(targetPlaylistID, forKey: Keys.targetPlaylistID) }
    }
    @Published var targetPlaylistName: String? {
        didSet { UserDefaults.standard.set(targetPlaylistName, forKey: Keys.targetPlaylistName) }
    }
    @Published var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: Keys.hapticsEnabled) }
    }
    /// Cached display name from Spotify, just for showing "Signed in as ..." in the UI without an extra API hit per launch.
    @Published var userDisplayName: String? {
        didSet { UserDefaults.standard.set(userDisplayName, forKey: Keys.userDisplayName) }
    }
    /// Save every match to the user's Liked Songs library (`PUT /me/tracks`). Default on.
    @Published var saveToLikedSongs: Bool {
        didSet { UserDefaults.standard.set(saveToLikedSongs, forKey: Keys.saveToLikedSongs) }
    }
    /// Save every match to the auto-created Shazam Songs playlist. Default on.
    @Published var saveToShazamPlaylist: Bool {
        didSet { UserDefaults.standard.set(saveToShazamPlaylist, forKey: Keys.saveToShazamPlaylist) }
    }
    /// Extra user-selected playlist IDs to mirror matches into.
    @Published var additionalPlaylistIDs: [String] {
        didSet { UserDefaults.standard.set(additionalPlaylistIDs, forKey: Keys.additionalPlaylistIDs) }
    }
    /// Display names for the additional playlist IDs (kept parallel for quick UI rendering without API calls).
    @Published var additionalPlaylistNames: [String: String] {
        didSet { UserDefaults.standard.set(additionalPlaylistNames, forKey: Keys.additionalPlaylistNames) }
    }

    init() {
        let d = UserDefaults.standard
        self.targetPlaylistID = d.string(forKey: Keys.targetPlaylistID)
        self.targetPlaylistName = d.string(forKey: Keys.targetPlaylistName)
        self.hapticsEnabled = d.object(forKey: Keys.hapticsEnabled) as? Bool ?? true
        self.userDisplayName = d.string(forKey: Keys.userDisplayName)
        self.saveToLikedSongs = d.object(forKey: Keys.saveToLikedSongs) as? Bool ?? true
        self.saveToShazamPlaylist = d.object(forKey: Keys.saveToShazamPlaylist) as? Bool ?? true
        self.additionalPlaylistIDs = (d.array(forKey: Keys.additionalPlaylistIDs) as? [String]) ?? []
        self.additionalPlaylistNames = (d.dictionary(forKey: Keys.additionalPlaylistNames) as? [String: String]) ?? [:]
    }
}
