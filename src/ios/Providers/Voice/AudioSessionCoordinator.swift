import Foundation
import AVFoundation
import UIKit

/// Opaque identity for one microphone-session owner.
///
/// A token can be begun or ended repeatedly without changing its ownership
/// count. Separate capture paths must use separate tokens so one path cannot
/// release another path's `.capture` intent.
@objc public final class AudioSessionCaptureToken: NSObject {
    fileprivate let id = UUID()
}

// MARK: - AudioSessionCoordinator
//
// The SINGLE owner of AVAudioSession category/active across the app. Every
// subsystem that needs audio declares an INTENT via begin()/end(); the
// coordinator picks the highest-priority active intent and applies its session
// profile (the only place setCategory / setActive is called). This removes the
// previous "everyone calls setCategory last-wins" races and the foreground-return
// silence (a stale category survived because a partial guard skipped reconfigure).
//
// Audio sources → intents (System TTS and cloud TTS are the SAME `replyTTS`
// source, just different engines resolved from the Voice Output group):
//   .capture            — mic recording (.record/.measurement)            [highest]
//   .applicationMusic   — apple-media applicationQueuePlayer
//   .mediaAttachment    — Markdown audio attachment / auto_play playback
//   .replyTTS           — read-replies (cloud VoiceOutputPlayer OR System AVSpeech)
//   .backgroundKeepAlive— silent keep-alive track (background only)        [lowest]
//
// `.mediaAttachment` and `.replyTTS` are mutually exclusive at the source level
// (the media player preempts TTS — see AIChatViewModel.stopSpeech on play), so in
// practice only one of them is active; the coordinator still ranks them.

@MainActor
final class AudioSessionCoordinator {
    static let shared = AudioSessionCoordinator()
    private init() { registerInterruptionObserver() }

    enum Intent: Int {
        // Higher rawValue = higher priority.
        case backgroundKeepAlive = 0
        case replyTTS = 1
        case mediaAttachment = 2
        case applicationMusic = 3
        case capture = 4
    }

    private let logger = AppLogger(category: "AudioSession")
    private var active: Set<Intent> = []
    /// Capture is the only intent that can legitimately have concurrent owners
    /// (the voice UI and an apple-speech native offload). Keep those owners
    /// separate from the legacy idempotent intent set so either API can coexist
    /// without one caller prematurely releasing another caller's microphone.
    private var captureTokens: Set<UUID> = []
    /// `sessionActive` tracks whether the process still owns AVAudioSession.
    /// A failed profile application leaves the previous session potentially
    /// active, but it must not be treated as healthy until a later apply
    /// succeeds.
    private var sessionNeedsReassertion = false

    /// True while the mic is capturing — reply TTS is suppressed in this state.
    var isCapturing: Bool {
        active.contains(.capture) || !captureTokens.isEmpty
    }

    /// Runtime health of the background keep-alive intent. Merely finding the
    /// intent in `active` is insufficient: iOS may have deactivated the session,
    /// or the most recent profile application may have failed.
    var hasBackgroundKeepAliveIntent: Bool {
        active.contains(.backgroundKeepAlive)
    }

    var backgroundKeepAliveIsActive: Bool {
        hasBackgroundKeepAliveIntent
            && sessionActive
            && !sessionNeedsReassertion
    }

    // MARK: - Public API

    /// Posted when a media attachment preempts reply TTS — the active chat VM stops
    /// its System AVSpeechSynthesizer in response (cloud TTS is stopped directly).
    static let replyTTSPreemptedNotification = Notification.Name("AudioSession.replyTTSPreempted")
    /// Posted by apple-media immediately before it gives the queue to the system
    /// Music player. App-owned audible playback must release its session first.
    static let systemMusicWillPlayNotification = Notification.Name("OpenMinis.SystemMusicWillPlay")

    /// Declare that `intent` now needs the audio session. Idempotent.
    @discardableResult
    func begin(_ intent: Intent) -> Bool {
        // Media attachment preempts reply TTS (mutually exclusive voice content):
        // stop the cloud queue directly and notify the chat VM to stop System TTS,
        // BEFORE media takes the session. (TTS is not auto-resumed afterwards.)
        if intent == .mediaAttachment, active.contains(.replyTTS) {
            VoiceOutputPlayer.shared.stopAll()
            NotificationCenter.default.post(name: Self.replyTTSPreemptedNotification, object: nil)
        }
        let was = highest
        active.insert(intent)
        if highest != was || !sessionActive || sessionNeedsReassertion {
            return apply(reason: "begin(\(intent))") == nil
        }
        return true
    }

    /// Declare that `intent` no longer needs the session.
    func end(_ intent: Intent) {
        guard active.contains(intent) else { return }
        active.remove(intent)
        apply(reason: "end(\(intent))")
    }

    /// Acquire capture ownership for a specific caller. Reusing the same token
    /// is idempotent, which is important when VAD reconfigures after an audio
    /// interruption without ending its logical capture.
    @discardableResult
    func beginCapture(with token: AudioSessionCaptureToken) -> Bool {
        let was = highest
        let inserted = captureTokens.insert(token.id).inserted
        if highest != was || !sessionActive || sessionNeedsReassertion {
            return apply(reason: "begin(capture:\(inserted ? "new" : "existing"))") == nil
        }
        return true
    }

    /// Release only the capture ownership represented by `token`. Repeated
    /// releases are harmless, and another owner's token keeps `.capture` active.
    func endCapture(with token: AudioSessionCaptureToken) {
        let was = highest
        guard captureTokens.remove(token.id) != nil else { return }
        if highest != was {
            apply(reason: "end(capture)")
        }
    }

    /// Re-assert the correct session on foreground return (the stale-category
    /// fix). Intent ownership remains with each subsystem: in particular,
    /// BackgroundKeepAliveManager may deliberately debounce its foreground stop
    /// so a rapid foreground→background blip does not lose the audio survival
    /// leg. Removing its intent here created split-brain state where its engine
    /// flag remained true but the coordinator had already released the session.
    func reassertForForeground() {
        _ = apply(reason: "foreground")
    }

    /// Acquire the app audio session for MediaPlayer's application queue
    /// player. Unlike `systemMusicPlayer`, this player renders inside Minis,
    /// so releasing the app session immediately before `play()` is backwards.
    ///
    /// Returns a user-facing error string so the Objective-C native offload can
    /// fail before touching MediaPlayer when the session cannot be activated.
    func beginApplicationMusic() -> String? {
        guard !isCapturing else {
            return "Cannot start Apple Music while the microphone is recording."
        }

        // Install the new highest-priority owner before stopping the old
        // engines. Their idempotent end() calls then cannot transiently
        // deactivate AVAudioSession between preemption and music startup.
        active.remove(.backgroundKeepAlive)
        active.remove(.replyTTS)
        active.remove(.mediaAttachment)
        active.insert(.applicationMusic)

        VoiceOutputPlayer.shared.stopAll()
        NotificationCenter.default.post(
            name: Self.replyTTSPreemptedNotification,
            object: nil)
        GlobalAudioPlayer.shared.stop()

        if let error = apply(reason: "begin(applicationMusic)") {
            active.remove(.applicationMusic)
            _ = apply(reason: "rollback(applicationMusic)")
            return "Unable to activate the app audio session: \(error.localizedDescription)"
        }
        return nil
    }

    func endApplicationMusic() {
        end(.applicationMusic)
    }

    // MARK: - Core (the ONLY setCategory/setActive site)

    private var sessionActive = false

    private var highest: Intent? {
        if !captureTokens.isEmpty {
            return .capture
        }
        return active.max(by: { $0.rawValue < $1.rawValue })
    }

    private func profile(for intent: Intent) -> (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions) {
        switch intent {
        case .capture:
            return (.record, .measurement, [])
        case .mediaAttachment:
            return (.playback, .default, [.duckOthers])
        case .replyTTS:
            return (.playback, .spokenAudio, [.duckOthers])
        case .applicationMusic:
            return (.playback, .default, [])
        case .backgroundKeepAlive:
            return (.playback, .default, [.mixWithOthers])
        }
    }

    @discardableResult
    private func apply(reason: String) -> Error? {
        let session = AVAudioSession.sharedInstance()
        guard let top = highest else {
            // Nothing needs audio — release the session.
            if sessionActive {
                try? session.setActive(false, options: .notifyOthersOnDeactivation)
                sessionActive = false
                logger.info("[AudioSession] \(reason) → idle, deactivated")
            }
            sessionNeedsReassertion = false
            return nil
        }
        let (cat, mode, opts) = profile(for: top)
        // FULL compare (category + mode + options), not just category — a partial
        // guard let BKA's `.mixWithOthers` profile poison reply TTS before.
        let needsReconfig = session.category != cat
            || session.mode != mode
            || session.categoryOptions != opts
        do {
            if needsReconfig {
                try session.setCategory(cat, mode: mode, options: opts)
            }
            if !sessionActive || needsReconfig {
                try session.setActive(true)
                sessionActive = true
            }
            sessionNeedsReassertion = false
            logger.info("[AudioSession] \(reason) → \(top) (\(cat.rawValue)/\(mode.rawValue)) active")
            return nil
        } catch {
            sessionNeedsReassertion = true
            logger.error("[AudioSession] \(reason) apply failed: \(error.localizedDescription)")
            return error
        }
    }

    // MARK: - Unified interruption handling (replaces per-subsystem observers)

    /// Set by subsystems so the coordinator can resume them after an interruption.
    var onInterruptionEnded: (() -> Void)?

    /// True while TTS was paused by us because external audio took priority
    /// (interruption or secondary-audio-silence hint). Guards the resume so we
    /// never resume playback the USER paused.
    private var pausedByExternalAudio = false

    private func registerInterruptionObserver() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        // [T-tts-pause-on-external-record] A third-party keyboard's dictation
        // (or any other app recording) runs its OWN audio session alongside our
        // .playback/.spokenAudio one — iOS does NOT post an
        // interruptionNotification for that coexistence, so TTS kept talking
        // and the keyboard transcribed our own speech. The system DOES post
        // silenceSecondaryAudioHintNotification (.begin) when higher-priority
        // audio (recording/call) should dominate: pause TTS there, resume on
        // .end.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSilenceSecondaryAudioHint(_:)),
            name: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil)
        // [T-tts-pause-inapp-keyboard-dictation] A third-party keyboard's
        // dictation started FROM INSIDE our app shares this process's audio
        // context — iOS does NOT post a silence-secondary-audio hint for it (that
        // notification fires only when ANOTHER app takes over). But the keyboard's
        // record session still triggers a route change, and the authoritative
        // `secondaryAudioShouldBeSilencedHint` property flips true while it holds
        // the mic. Poll that property on every route change and pause/resume TTS
        // accordingly, so in-app dictation gets the same treatment as cross-app
        // recording. (Reason codes alone are unreliable — categoryChange /
        // routeConfigurationChange fire for many unrelated cases — so we trust the
        // property, not the reason.)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleSystemMusicWillPlay(_:)),
            name: Self.systemMusicWillPlayNotification, object: nil)
    }

    @objc private func handleSystemMusicWillPlay(_ note: Notification) {
        // Stop both reply engines and any local attachment before Apple Music
        // prepares its queue. The direct active-set cleanup is intentional:
        // it also recovers a stale intent left by an already-destroyed chat VM.
        VoiceOutputPlayer.shared.stopAll()
        NotificationCenter.default.post(
            name: Self.replyTTSPreemptedNotification,
            object: nil)
        GlobalAudioPlayer.shared.stop()
        let removedTTS = active.remove(.replyTTS) != nil
        let removedMedia = active.remove(.mediaAttachment) != nil
        let removedApplicationMusic = active.remove(.applicationMusic) != nil
        if removedTTS || removedMedia || removedApplicationMusic {
            apply(reason: "system-music-will-play")
        }
    }

    @objc private func handleRouteChange(_ note: Notification) {
        let shouldSilence = AVAudioSession.sharedInstance().secondaryAudioShouldBeSilencedHint
        if shouldSilence {
            pauseTTSForExternalAudio(reason: "route-change(secondary-silence)")
        } else {
            resumeTTSAfterExternalAudio(reason: "route-change(secondary-clear)")
        }
    }

    /// Pause reply TTS because external audio (interruption / recording in
    /// another app) needs to dominate. `pause()` keeps the synthesis queue so
    /// playback can pick up where it left off — deliberately NOT stopAll().
    ///
    /// The intent flag `pausedByExternalAudio` is latched INDEPENDENTLY of the
    /// player's physical `isPaused`: an external recording frequently stops our
    /// AVAudioPlayer BEFORE the pause signal arrives, so at this point there may
    /// be no live player to physically pause — but we still must remember that
    /// WE own the pause, or the matching `.end` won't resume. `pause()` now
    /// latches `isPaused` even with no live player and gates `pumpPlayback`, so
    /// the queue can't sneak a unit out under the recorder.
    private func pauseTTSForExternalAudio(reason: String) {
        // Idempotent: repeated BEGIN signals (interruption + secondary-hint can
        // both fire) must not clear an already-recorded pause intent.
        guard !pausedByExternalAudio else { return }
        pausedByExternalAudio = true
        VoiceOutputPlayer.shared.pause()
        logger.info("[AudioSession] \(reason) → TTS paused (external audio)")
    }

    /// Resume reply TTS if (and only if) WE paused it for external audio.
    private func resumeTTSAfterExternalAudio(reason: String) {
        guard pausedByExternalAudio else { return }
        pausedByExternalAudio = false
        VoiceOutputPlayer.shared.resume()
        logger.info("[AudioSession] \(reason) → TTS resumed")
    }

    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            logger.info("[AudioSession] interruption began")
            sessionActive = false   // system deactivated us
            sessionNeedsReassertion = true
            // Previously we only flagged the session inactive; the TTS queue
            // kept "playing" into a dead session. Pause it so the queue
            // survives and can resume when the interruption ends.
            pauseTTSForExternalAudio(reason: "interruption-began")
        case .ended:
            logger.info("[AudioSession] interruption ended → re-asserting")
            apply(reason: "interruption-ended")
            resumeTTSAfterExternalAudio(reason: "interruption-ended")
            onInterruptionEnded?()
        @unknown default:
            break
        }
    }

    @objc private func handleSilenceSecondaryAudioHint(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionSilenceSecondaryAudioHintTypeKey] as? UInt,
              let type = AVAudioSession.SilenceSecondaryAudioHintType(rawValue: raw) else { return }
        switch type {
        case .begin:
            logger.info("[AudioSession] silence-secondary-audio hint BEGIN")
            pauseTTSForExternalAudio(reason: "secondary-audio-hint")
        case .end:
            logger.info("[AudioSession] silence-secondary-audio hint END")
            resumeTTSAfterExternalAudio(reason: "secondary-audio-hint-end")
        @unknown default:
            break
        }
    }
}

/// Objective-C bridge used by in-process native offloads. Keeping capture
/// ownership here prevents apple-speech from overwriting AVAudioSession behind
/// the coordinator's back.
@MainActor
@objc public final class AudioSessionOffloadBridge: NSObject {
    private static let legacyCaptureToken = AudioSessionCaptureToken()

    /// Legacy idempotent API retained for binary/source compatibility.
    @objc public static func beginCapture() {
        AudioSessionCoordinator.shared.beginCapture(with: legacyCaptureToken)
    }

    @objc public static func endCapture() {
        AudioSessionCoordinator.shared.endCapture(with: legacyCaptureToken)
    }

    /// Acquire an independent capture lease for one native-offload invocation.
    /// The returned opaque token must be passed to `releaseCapture(_:)`.
    @objc public static func acquireCapture() -> AudioSessionCaptureToken {
        let token = AudioSessionCaptureToken()
        AudioSessionCoordinator.shared.beginCapture(with: token)
        return token
    }

    /// Idempotently release one native-offload capture lease.
    @objc public static func releaseCapture(_ token: AudioSessionCaptureToken) {
        AudioSessionCoordinator.shared.endCapture(with: token)
    }

    /// Returns nil on success or a user-facing error on failure.
    @objc public static func beginApplicationMusic() -> String? {
        AudioSessionCoordinator.shared.beginApplicationMusic()
    }

    @objc public static func endApplicationMusic() {
        AudioSessionCoordinator.shared.endApplicationMusic()
    }
}
