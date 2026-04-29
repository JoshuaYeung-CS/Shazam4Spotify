import SwiftUI

@main
struct Shazam2SpotifyApp: App {
    @StateObject private var auth: SpotifyAuth
    @StateObject private var matcher = ShazamMatcher()
    @StateObject private var settings = AppSettings()
    @StateObject private var pipeline: MatchPipeline

    init() {
        let auth = SpotifyAuth()
        let settings = AppSettings()
        let client = SpotifyClient(auth: auth)
        _auth = StateObject(wrappedValue: auth)
        _settings = StateObject(wrappedValue: settings)
        _pipeline = StateObject(wrappedValue: MatchPipeline(auth: auth, client: client, settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(auth)
                .environmentObject(matcher)
                .environmentObject(pipeline)
                .environmentObject(settings)
                .task {
                    pipeline.bind(to: matcher)
                }
        }
    }
}
