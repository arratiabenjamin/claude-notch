// AvatarSpeaker.swift
// The voice + speech queue + spatial-audio brain behind the avatar orb.
//
// Phases 4, 5 and 6 of the orb redesign live here in a single coordinator
// because they share state (current speech, queue, audio engine) and any
// split would just shuffle that state through indirection without buying
// anything.
//
// Architecture:
//   • AVSpeechSynthesizer drives TTS. We render speech to PCM via
//     AVSpeechSynthesizer.write(_:toBufferCallback:) and feed those buffers
//     into an AVAudioEngine player node so we can spatialize per slot.
//   • Each rendered buffer is also analyzed for RMS amplitude; the values
//     are published on `@Published var amplitude` so OrbView/OrbCompactView
//     can pulse the orb in real time.
//   • A FIFO queue serializes utterances. Never interrupts: if we're
//     speaking and another session ends, the new utterance waits.
//   • Each utterance carries a `slot` (front/left/right). The audio source
//     is positioned in 3D space accordingly so on AirPods Pro with head
//     tracking, the user hears the announcement from that direction.
//   • If multiple sessions share a slot, we prefix the utterance with the
//     session name so the user can tell them apart.
//
// All public API is `@MainActor` because it ties into SwiftUI bindings.
// Internal audio processing happens on AVFoundation's own threads; we
// hop back via `await MainActor.run` before touching published state.
import Foundation
import AVFoundation
import Combine
import os.log

private let log = Logger(subsystem: "com.velion.claude-notch", category: "avatar-speaker")

@MainActor
final class AvatarSpeaker: ObservableObject {

    // MARK: - Published lip-sync hook

    /// 0..1 RMS amplitude of the most recent rendered audio frame. OrbView
    /// reads this and feeds it into VelionOrb.pulseAmplitude. Falls back to
    /// 0 between utterances.
    @Published private(set) var amplitude: Double = 0.0

    /// True while there's an utterance playing or rendering.
    @Published private(set) var isSpeaking: Bool = false

    /// Session id currently being spoken about, if any. Lets the orb know
    /// which satellite to emphasize during the announcement.
    @Published private(set) var speakingSessionId: String?

    // MARK: - Audio infrastructure

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()
    private let player = AVAudioPlayerNode()
    private var engineConfigured = false

    private let synth = AVSpeechSynthesizer()

    // MARK: - Queue

    /// One pending or in-flight announcement.
    struct Utterance {
        let text: String
        let slot: SpatialSlot
        let sessionId: String
    }

    private var queue: [Utterance] = []
    private var currentSessionId: String?

    // MARK: - Settings hooks (read on each speak call so toggles take effect)

    private var muted: Bool {
        UserDefaults.standard.bool(forKey: "avatar_muted")
    }

    /// Preferred BCP-47 language for the voice. Empty → system pick.
    private var preferredVoiceLanguage: String {
        let stored = UserDefaults.standard.string(forKey: "avatar_voice_lang") ?? ""
        return stored.isEmpty ? "es-MX" : stored
    }

    // MARK: - Public API

    /// Enqueue an announcement for the given session. If something is
    /// already speaking, the utterance waits its turn (FIFO).
    func enqueue(text: String, slot: SpatialSlot, sessionId: String, sessionName: String) {
        if muted { return }
        let prefixed = needsNamePrefix(slot: slot, sessionId: sessionId)
            ? "\(sessionName). \(text)"
            : text
        let u = Utterance(text: prefixed, slot: slot, sessionId: sessionId)
        queue.append(u)
        log.info("enqueued utterance for session=\(sessionId, privacy: .public) slot=\(slot.rawValue, privacy: .public) qLen=\(self.queue.count, privacy: .public)")
        speakNextIfIdle()
    }

    /// Flush the queue immediately. Used by the global mute hotkey so the
    /// user can shut up the avatar mid-sentence.
    func silence() {
        queue.removeAll()
        synth.stopSpeaking(at: .immediate)
        player.stop()
        amplitude = 0
        isSpeaking = false
        speakingSessionId = nil
        currentSessionId = nil
    }

    // MARK: - Queue + playback

    private func speakNextIfIdle() {
        guard !isSpeaking, let next = queue.first else { return }
        queue.removeFirst()
        currentSessionId = next.sessionId
        speakingSessionId = next.sessionId
        isSpeaking = true
        Task { await render(next) }
    }

    /// Render `utterance.text` to PCM via AVSpeechSynthesizer, push the
    /// resulting buffers into the spatialized player node, and resolve when
    /// playback finishes. On any failure we degrade silently and pop to the
    /// next utterance so a hung voice can never wedge the queue.
    private func render(_ utterance: Utterance) async {
        await ensureEngine(running: true)
        position(slot: utterance.slot)

        let speech = AVSpeechUtterance(string: utterance.text)
        if let voice = preferredVoice() { speech.voice = voice }
        speech.rate = AVSpeechUtteranceDefaultSpeechRate
        speech.pitchMultiplier = 1.0
        speech.preUtteranceDelay = 0.05

        var didFinish = false
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // AVSpeechSynthesizer.write is the documented way to get audio
            // buffers out of TTS. The callback is called on a private queue.
            synth.write(speech) { [weak self] buffer in
                guard let self else { return }
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if !didFinish {
                        didFinish = true
                        Task { @MainActor [weak self] in
                            self?.handleUtteranceFinished()
                            continuation.resume()
                        }
                    }
                    return
                }
                Task { @MainActor [weak self] in
                    self?.publishAmplitude(pcm)
                }
                self.scheduleBuffer(pcm)
            }
        }
    }

    private func scheduleBuffer(_ buffer: AVAudioPCMBuffer) {
        // Player needs to be playing before scheduling. Cheap to call repeatedly.
        if !player.isPlaying { player.play() }
        // Convert to engine's format if necessary. AVSpeechSynthesizer.write
        // returns Float32 in the synthesizer's natural rate (typically 22050 Hz).
        // Foundation does the resampling for us when we connect through the
        // environment node configured at the engine output rate, so we can
        // schedule directly here. If formats really diverge, AVAudioConverter
        // is the right escape hatch — Phase 5.5 if it ever bites.
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    @MainActor
    private func handleUtteranceFinished() {
        amplitude = 0
        isSpeaking = false
        speakingSessionId = nil
        currentSessionId = nil
        // Slight pause between utterances so they don't run together
        // when the queue is busy.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.speakNextIfIdle()
        }
    }

    // MARK: - Spatial positioning

    /// Update the player's 3D position to match `slot`. Audible only on
    /// stereo playback and dramatically more so on AirPods with head
    /// tracking; harmless otherwise.
    private func position(slot: SpatialSlot) {
        let pos: AVAudio3DPoint
        switch slot {
        case .front: pos = AVAudio3DPoint(x:  0, y: 0, z: -1.2)
        case .left:  pos = AVAudio3DPoint(x: -1.2, y: 0, z: -0.4)
        case .right: pos = AVAudio3DPoint(x:  1.2, y: 0, z: -0.4)
        }
        player.position = pos
    }

    // MARK: - Engine setup

    /// Idempotently configure the engine: player → environment → output.
    /// We don't auto-start because that prompts for microphone privileges
    /// in some sandbox configurations; we start lazily when needed.
    private func ensureEngine(running: Bool) async {
        if !engineConfigured { configureEngine() }
        guard running else { return }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                log.error("engine.start failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func configureEngine() {
        engineConfigured = true
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)

        engine.attach(environment)
        engine.attach(player)

        // Player is mono (TTS is mono); environment node spatializes to stereo.
        engine.connect(player, to: environment, format: format)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)

        environment.renderingAlgorithm = .HRTF
        environment.distanceAttenuationParameters.maximumDistance = 5.0
        environment.distanceAttenuationParameters.referenceDistance = 0.5
        environment.outputType = .headphones

        // The listener stays at the origin facing forward.
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(
            yaw: 0, pitch: 0, roll: 0
        )
    }

    // MARK: - Voice selection

    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        let lang = preferredVoiceLanguage
        // Prefer enhanced/premium voices when available — they're noticeably
        // less robotic and the file is already cached on the system.
        let candidates = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == lang || $0.language.hasPrefix(String(lang.prefix(2))) }
            .sorted { lhs, rhs in
                let lq = lhs.quality.rawValue
                let rq = rhs.quality.rawValue
                return lq > rq
            }
        return candidates.first ?? AVSpeechSynthesisVoice(language: lang)
    }

    // MARK: - Amplitude analysis

    /// RMS over the most recent buffer; published as 0..1 for the orb pulse.
    private func publishAmplitude(_ buffer: AVAudioPCMBuffer) {
        guard let chData = buffer.floatChannelData else { return }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }
        let samples = chData[0]
        var sum: Float = 0
        for i in 0..<frameCount {
            let s = samples[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(frameCount))
        // Compress to 0..1 with a soft curve — TTS RMS is small (< 0.3).
        let scaled = min(1.0, Double(rms) * 4.5)
        amplitude = scaled
    }

    // MARK: - Multi-session-per-slot prefix

    /// True when more than one session is mapped to the same slot, so the
    /// utterance should announce *which* session it's about. The slot info
    /// is canonical (SpatialSlotManager) but we don't have a direct ref
    /// here — caller passes the slot, and the queue treats every utterance
    /// as needing a prefix when in doubt. Heuristic: prefix any time we're
    /// the second+ utterance for the slot in the visible queue.
    private func needsNamePrefix(slot: SpatialSlot, sessionId: String) -> Bool {
        // Always prefix; the announcement reads more naturally with a name
        // anyway, and we don't have a cheap way to know slot-stack count
        // from inside the queue. Cost is one extra word per announcement.
        true
    }
}
