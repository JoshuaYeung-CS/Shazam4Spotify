# Shazam4Spotify

> Native iOS app that recognizes ambient music with **ShazamKit** and auto-adds
> the match to a **Spotify** playlist via the Web API.

Built because Apple's official Shazam app only deep-links to Apple Music — there's
no first-party equivalent for Spotify users. Shazam4Spotify closes that gap.

---

## Overview

Tap a button, hold your phone near a speaker, and any song that gets recognized
is silently appended to a Spotify playlist of your choice (auto-created if
needed). The matching uses **ShazamKit's cloud catalog** (the same one the
first-party Shazam app uses) and bridges to Spotify through the **ISRC** —
the international standard recording code that both services agree on.

```
┌──────────────┐    audio buffers   ┌─────────────┐    ISRC    ┌──────────────┐    URI    ┌─────────────────┐
│ AVAudioEngine│ ─────────────────> │  SHSession  │ ─────────> │ Spotify Web  │ ────────> │   Add to user's │
│  (mic tap)   │                    │ (ShazamKit) │            │  API search  │           │     playlist    │
└──────────────┘                    └─────────────┘            └──────────────┘           └─────────────────┘
```

ISRC is the unlock: Shazam returns one (e.g. `GBAYK0500030`) for every match,
Spotify's `q=isrc:...` search returns the exact track URI — no fuzzy
name-matching, no confusion between remixes or live versions.

---

## Features

- **One-tap listening** with audio-reactive ripple animation that pulses in
  time with detected sound levels.
- **ISRC-based bridging** — exact track matching across services.
- **Background grace period** — continues listening for ~3-10 min after
  backgrounding via the legitimate `audio` background mode.
- **Smart de-duplication** — ignores the same ISRC if reported within 30s.
- **Auto-recovery** — if the target playlist was deleted on Spotify, the
  pipeline silently re-resolves and retries.
- **Single-flight token refresh** — concurrent API calls during token expiry
  share one refresh, preventing race conditions where one call invalidates
  another's refresh token.
- **Persistent catch history** — all matched songs stored locally as JSON
  (`Application Support/caught-songs.json`), survives app restarts.
- **Configurable target playlist** — pick any of your existing Spotify
  playlists, or let the app auto-create one called `Shazam Songs`.

---

## Architecture

```
Sources/
├── Shazam4SpotifyApp.swift         @main entry, wires environment objects
│
├── Audio/
│   ├── AudioSessionManager.swift   AVAudioSession config, mic permission
│   └── ShazamMatcher.swift         SHSession + AVAudioEngine, RMS metering,
│                                   interruption / route-change / foreground
│                                   recovery, 30-second ISRC dedupe
├── Spotify/
│   ├── SpotifyAuth.swift           PKCE OAuth via ASWebAuthenticationSession,
│   │                               single-flight token refresh, Keychain-backed
│   ├── SpotifyClient.swift         Web API + retry policy (401/429/5xx),
│   │                               error envelope parsing for friendly messages
│   ├── SpotifyClientProtocol.swift Protocol boundaries for testability:
│   │                               SpotifyClientProtocol, AuthStateProviding,
│   │                               TokenProviding
│   ├── SpotifyModels.swift         Codable types (Track, Playlist, User, ...)
│   └── TokenStore.swift            Keychain wrapper (actor-isolated)
├── Pipeline/
│   ├── CaughtStore.swift           File-backed persistence for match history
│   └── MatchPipeline.swift         match → resolve track (ISRC then fallback)
│                                   → ensure playlist (cached/created/recovered)
│                                   → add (with 404 re-resolve)
├── UI/
│   ├── ContentView.swift           Listen button, audio-reactive rings, status,
│   │                               recent catches list with album art
│   ├── PlaylistPickerView.swift    Paginated picker (handles >50 playlists)
│   └── SettingsView.swift          Account, target playlist, haptics, history
└── Util/
    ├── AppSettings.swift           UserDefaults-backed @Published settings
    ├── Config.swift                Constants (endpoints, scopes, defaults)
    ├── Haptics.swift               UINotificationFeedbackGenerator wrapper
    └── Log.swift                   os.Logger subsystems: auth/api/matcher/pipeline

Tests/
├── CaughtStoreTests.swift          Round-trip, trim-to-max, corruption recovery
├── MatchPipelineTests.swift        Mock-driven: happy path, not-on-Spotify,
│                                   dedupe, 404 auto-recovery, history persistence
└── SpotifyClientTests.swift        URLProtocol-mocked: Bearer header,
                                    401-refresh-retry, 429 Retry-After, GET-only
                                    5xx retry policy, error envelope parsing
```

**20 Swift sources, ~2,500 LOC, 20 passing unit tests.** Project file
generated from [`project.yml`](project.yml) via
[xcodegen](https://github.com/yonaskolb/XcodeGen) — `.xcodeproj` is gitignored
because it's regenerable.

---

## Tech stack

| Layer | Choice | Why |
|---|---|---|
| UI | **SwiftUI** (iOS 17+) | Modern declarative, `symbolEffect` animations, less boilerplate |
| Audio | **AVAudioEngine** | Direct buffer access needed for ShazamKit's `matchStreamingBuffer` + RMS metering |
| Recognition | **ShazamKit** (cloud catalog) | Same backend as the first-party Shazam app — 50M+ tracks fingerprinted since 2002 |
| Auth | **OAuth 2.0 PKCE** (no client secret) | Native flow for public clients; refresh tokens in Keychain |
| Web API | URLSession + `async/await` | No third-party HTTP dependencies |
| Persistence | JSON file (history), Keychain (tokens), UserDefaults (settings) | Right tool per data sensitivity / volume |
| Project generation | **xcodegen** | Declarative, easier to diff than `.pbxproj`, regenerable |
| Tests | XCTest + URLProtocol mocking | No network in CI, deterministic |

Zero third-party Swift dependencies. Everything stdlib + Apple frameworks.

---

## Robustness highlights

A few things deliberately handled that often aren't in similar samples:

- **Single-flight refresh** — `Task` pinning ensures concurrent API calls
  during token expiry share one refresh, so the second caller doesn't see
  an invalidated refresh token mid-flight.
- **HTTP retry policy** — `401` forces a refresh and retries once; `429`
  respects `Retry-After` (capped at 5 s); `5xx` retries on `GET` only because
  `POST`s might have already side-effected.
- **AVAudioSession interruption + route changes** — phone call pauses the
  engine and sets `.interrupted` state; auto-resume only if `shouldResume`
  flag fires. Engine death during background suspension is detected on
  foreground and restarted.
- **404 on `addTrack`** — assumes the user deleted the playlist on Spotify;
  clears the cached resolution + persisted settings, re-resolves, retries once.
- **OAuth cancel vs error** — `ASWebAuthenticationSession.canceledLogin`
  surfaces as `AuthError.userCancelled` and is silent in the UI; other
  errors raise the alert.
- **Spotify error envelope parsing** — `{"error":{"message":"..."}}` gets
  translated into user-friendly copy; `403 development mode` explicitly
  suggests adding the user to the dashboard's User Management list.

---

## How to build

### Prerequisites

- macOS with **Xcode 16+** (iOS 17.0 SDK)
- A real iPhone or the iOS Simulator (Mac mic forwarding has caveats; real
  device is more reliable for ShazamKit)
- **Apple Developer Program** membership ($99/yr) — required for the
  ShazamKit cloud match entitlement. Without it, the audio pipeline still
  works but `shazamd` returns `401 Unauthorized` from Apple's match server.
- A Spotify Developer app — see below

### One-time setup

1. **Clone**
   ```sh
   git clone https://github.com/JoshuaYeung-CS/Shazam4Spotify.git
   cd Shazam4Spotify
   ```

2. **Install xcodegen and generate the Xcode project**
   ```sh
   brew install xcodegen
   xcodegen generate
   ```

3. **Spotify Developer app**
   - Visit https://developer.spotify.com/dashboard → create app
   - Web API only; no client secret needed (we use PKCE)
   - Redirect URI: `shazam4spotify://callback`
   - Add your Spotify account email under **User Management** (dev mode caps
     at 5 users)
   - Copy the Client ID into `Sources/Util/Config.swift`

4. **Enable ShazamKit App Service entitlement**
   - https://developer.apple.com/account/resources/identifiers
   - Register App ID for `com.joshuayeung.shazam4spotify`
   - Enable **ShazamKit App Service** under App Services
   - Update `DEVELOPMENT_TEAM` in [`project.yml`](project.yml) to your team ID

5. **Build + run**
   ```sh
   xcodebuild -project Shazam4Spotify.xcodeproj \
              -scheme Shazam4Spotify \
              -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
              build
   ```
   Or just open `Shazam4Spotify.xcodeproj` in Xcode and hit ⌘R.

### Run tests

```sh
xcodebuild -project Shazam4Spotify.xcodeproj \
           -scheme Shazam4Spotify \
           -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
           test
```

All 20 tests should pass in under 1 second.

---

## Known limitations

- **iOS Simulator ShazamKit reliability is uneven** — even with the
  entitlement enabled, the simulator's mic forwarding and Apple's match
  daemon for simulators don't always cooperate. Real iPhone is the reliable
  path for actual song recognition.
- **True always-on background listening** isn't possible from a third-party
  app — Apple's Auto-Shazam uses private entitlements not available to
  developers. The app uses the legitimate `audio` background mode for
  foreground + grace-period listening only.
- **Development Mode** Spotify apps are limited to 5 whitelisted users.
  Going beyond that requires Extended Quota review from Spotify.
- **Free Apple ID signing certs expire after 7 days** — paid Apple Developer
  Program ($99/yr) is also required to skip the weekly re-signing dance.

---

## License

[MIT](LICENSE) — see the LICENSE file.
