import AVFAudio
import Combine
import Foundation
import OSLog
import ShazamKit
import UIKit

struct RecognizedSong: Identifiable, Hashable, Codable {
    let id: UUID
    let title: String
    let artist: String
    let isrc: String?
    let appleMusicID: String?
    let artworkURL: URL?
    let recognizedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        isrc: String? = nil,
        appleMusicID: String? = nil,
        artworkURL: URL? = nil,
        recognizedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.isrc = isrc
        self.appleMusicID = appleMusicID
        self.artworkURL = artworkURL
        self.recognizedAt = recognizedAt
    }

    init(item: SHMatchedMediaItem) {
        self.init(
            title: item.title ?? "Unknown title",
            artist: item.artist ?? "Unknown artist",
            isrc: item.isrc,
            appleMusicID: item.appleMusicID,
            artworkURL: item.artworkURL
        )
    }
}

@MainActor
final class ShazamMatcher: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case listening
        case interrupted
        case error(String)
    }

    @Published private(set) var state: State = .idle
    /// Smoothed mic input level, normalized 0…1. Drives audio-reactive UI.
    @Published private(set) var inputLevel: Float = 0
    let matchPublisher = PassthroughSubject<RecognizedSong, Never>()

    private let audioEngine = AVAudioEngine()
    private var session: SHSession?
    private var lastMatchedISRC: String?
    private var lastMatchedAt: Date?
    private var lastLevelEmit: TimeInterval = 0

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    /// Tracks whether the user explicitly asked to listen — used to auto-resume after an interruption ends.
    private var userIntentToListen = false

    override init() {
        super.init()
        installAudioObservers()
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
        if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
    }

    func start() async {
        userIntentToListen = true
        guard state != .listening else { return }
        Logger.matcher.info("Listen requested")
        let granted = await AudioSessionManager.requestMicPermission()
        guard granted else {
            Logger.matcher.error("Microphone permission denied")
            state = .error(AudioSessionManager.permissionDeniedMessage)
            userIntentToListen = false
            return
        }
        do {
            try AudioSessionManager.configureForListening()
            try startEngine()
            state = .listening
            Logger.matcher.info("Audio engine started, ShazamKit session active")
        } catch {
            Logger.matcher.error("Failed to start engine: \(error.localizedDescription, privacy: .public)")
            state = .error(error.localizedDescription)
            userIntentToListen = false
        }
    }

    func stop() {
        Logger.matcher.info("Listen stopped by user")
        userIntentToListen = false
        teardownEngine()
        AudioSessionManager.deactivate()
        if state == .listening || state == .interrupted { state = .idle }
        inputLevel = 0
    }

    private func startEngine() throws {
        let newSession = SHSession()
        newSession.delegate = self
        self.session = newSession

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak newSession, weak self] buffer, audioTime in
            newSession?.matchStreamingBuffer(buffer, at: audioTime)

            // Compute RMS amplitude on the audio thread (cheap), then publish on main with throttling.
            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0, let channelData = buffer.floatChannelData?[0] else { return }
            var sumSquares: Float = 0
            for i in 0..<frameLength {
                let sample = channelData[i]
                sumSquares += sample * sample
            }
            let rms = sqrt(sumSquares / Float(frameLength))
            // Music typically RMS ~0.05–0.3; multiplier scales that to 0…1.
            let normalized = min(rms * 4, 1.0)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let now = Date().timeIntervalSinceReferenceDate
                if now - self.lastLevelEmit < 0.05 { return }
                self.lastLevelEmit = now
                // Low-pass filter for smooth visual decay.
                self.inputLevel = self.inputLevel * 0.55 + normalized * 0.45
            }
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    private func teardownEngine() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        session = nil
    }

    // MARK: - Interruptions & route changes

    private func installAudioObservers() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleForeground() }
        }
    }

    /// If the system suspended the engine while we were in the background and the user still wants to listen,
    /// detect the discrepancy on foreground and restart.
    private func handleForeground() {
        guard userIntentToListen, state == .listening, !audioEngine.isRunning else { return }
        Logger.matcher.notice("Engine died while suspended; restarting on foreground")
        teardownEngine()
        do {
            try AudioSessionManager.configureForListening()
            try startEngine()
        } catch {
            Logger.matcher.error("Foreground restart failed: \(error.localizedDescription, privacy: .public)")
            state = .error(error.localizedDescription)
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            Logger.matcher.notice("Audio session interrupted")
            teardownEngine()
            if userIntentToListen { state = .interrupted }
        case .ended:
            guard userIntentToListen else { return }
            // Resume only if the system says we should (e.g., phone call ended cleanly).
            let shouldResume: Bool = {
                guard let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt else { return false }
                return AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            }()
            guard shouldResume else {
                Logger.matcher.notice("Interruption ended; system did not signal shouldResume")
                return
            }
            Logger.matcher.info("Resuming after interruption")
            do {
                try AudioSessionManager.configureForListening()
                try startEngine()
                state = .listening
            } catch {
                Logger.matcher.error("Failed to resume: \(error.localizedDescription, privacy: .public)")
                state = .error(error.localizedDescription)
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        // If the input device disappeared (e.g., headphones unplugged in a way that removed the active input),
        // the engine may stop accepting buffers. Restart conservatively only if we were listening and the engine died.
        guard state == .listening, !audioEngine.isRunning, userIntentToListen else { return }
        teardownEngine()
        do {
            try AudioSessionManager.configureForListening()
            try startEngine()
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}

extension ShazamMatcher: SHSessionDelegate {
    nonisolated func session(_ session: SHSession, didFind match: SHMatch) {
        guard let item = match.mediaItems.first else { return }
        Task { @MainActor in
            self.handleMatch(item: item)
        }
    }

    nonisolated func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        // No match for this window — keep listening.
    }

    @MainActor
    private func handleMatch(item: SHMatchedMediaItem) {
        // Dedupe: ignore the same ISRC reported within 30s.
        let now = Date()
        if let isrc = item.isrc, isrc == lastMatchedISRC,
           let last = lastMatchedAt, now.timeIntervalSince(last) < 30 {
            return
        }
        lastMatchedISRC = item.isrc
        lastMatchedAt = now
        Logger.matcher.info("Match: \(item.title ?? "?", privacy: .public) — \(item.artist ?? "?", privacy: .public) (ISRC=\(item.isrc ?? "nil", privacy: .public))")
        matchPublisher.send(RecognizedSong(item: item))
    }
}
