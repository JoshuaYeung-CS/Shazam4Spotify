# Start here — Shazam4Spotify

**What this is:** a native iOS app that recognizes music playing nearby with ShazamKit and saves each match to Spotify (Liked Songs, a default `Shazam Songs` playlist, and/or chosen playlists), bridging the two services by ISRC.
**Status:** paused (last feature: multi-destination matching, May 2026). Version 0.1.0, no web URL or TestFlight pipeline.

## Look here first
- [README.md](README.md) — overview, architecture, robustness notes, full build setup
- [Sources/Pipeline/MatchPipeline.swift](Sources/Pipeline/MatchPipeline.swift) — match to Spotify track to destinations (dedupe, 404 recovery)
- [Sources/Audio/ShazamMatcher.swift](Sources/Audio/ShazamMatcher.swift) — mic tap + ShazamKit session
- [Sources/Spotify/SpotifyAuth.swift](Sources/Spotify/SpotifyAuth.swift) + [SpotifyClient.swift](Sources/Spotify/SpotifyClient.swift) — PKCE login, token refresh, Web API calls
- [Sources/Util/Config.swift](Sources/Util/Config.swift) — Spotify client ID, redirect URI, scopes, default playlist name
- [project.yml](project.yml) — xcodegen spec (bundle id, team, entitlements)

## Where things are
- `Sources/Audio/` — audio session, ShazamKit matcher
- `Sources/Spotify/` — auth, API client, protocols, models, Keychain token store
- `Sources/Pipeline/` — `MatchPipeline`, `CaughtStore` (match history JSON)
- `Sources/UI/` — `ContentView`, `PlaylistPickerView`, `SettingsView`
- `Sources/Util/` — settings, config, haptics, logging
- `Tests/` — CaughtStore, MatchPipeline, SpotifyClient unit tests
- `Resources/` — Info.plist, assets; `Shazam4Spotify.entitlements` at root (ShazamKit)
- `docs/screenshots/` — README images

## Search for
- `MatchPipeline.process`, `buildDestinations`, `saveToLikedSongs` — where matches go
- `isrc:` — ISRC search against Spotify
- `ensureShazamPlaylistID`, `invalidatePlaylistCache` — playlist creation and recovery
- `spotifyClientID`, `spotifyScopes` — Spotify app config
- `caught-songs.json` — persisted history

## Set up & run
Needs a Mac with Xcode 16+, xcodegen, an Apple Developer membership (ShazamKit entitlement) and a Spotify Developer app (redirect `shazam4spotify://callback`; put its Client ID in `Sources/Util/Config.swift`). No secrets: PKCE, no client secret.
```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Shazam4Spotify.xcodeproj -scheme Shazam4Spotify \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project Shazam4Spotify.xcodeproj -scheme Shazam4Spotify \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```
A real iPhone is the reliable path for song recognition.

## Continue working
- No roadmap or todo file. Open edges are the README "Known limitations" (simulator ShazamKit, background listening, Spotify 5-user dev mode).
- The README architecture section predates multi-destination matching; check `MatchPipeline.swift` for the current flow.
