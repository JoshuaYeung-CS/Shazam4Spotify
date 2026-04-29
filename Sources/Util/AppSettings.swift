import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    private enum Keys {
        static let targetPlaylistID = "targetPlaylistID"
        static let targetPlaylistName = "targetPlaylistName"
        static let hapticsEnabled = "hapticsEnabled"
    }

    @Published var targetPlaylistID: String? {
        didSet { UserDefaults.standard.set(targetPlaylistID, forKey: Keys.targetPlaylistID) }
    }
    @Published var targetPlaylistName: String? {
        didSet { UserDefaults.standard.set(targetPlaylistName, forKey: Keys.targetPlaylistName) }
    }
    @Published var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: Keys.hapticsEnabled) }
    }

    init() {
        let d = UserDefaults.standard
        self.targetPlaylistID = d.string(forKey: Keys.targetPlaylistID)
        self.targetPlaylistName = d.string(forKey: Keys.targetPlaylistName)
        self.hapticsEnabled = d.object(forKey: Keys.hapticsEnabled) as? Bool ?? true
    }
}
