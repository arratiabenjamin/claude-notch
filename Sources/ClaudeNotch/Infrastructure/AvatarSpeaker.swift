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
import CoreAudio
import Combine
import os.log

private let log = Logger(subsystem: "com.velion.claude-notch", category: "avatar-speaker")

@MainActor
final class AvatarSpeaker: ObservableObject {

    // MARK: - Published lip-sync hook

    /// 0..1 RMS amplitude of the most recent rendered audio frame. OrbView
    /// reads this to feed VelionHologram's `.speaking(amplitude:)` mode so
    /// the orb scale tracks the avatar's voice. Falls back to 0 between
    /// utterances.
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

    /// Format negotiated on the first buffer we receive from TTS. Used to
    /// re-connect the audio pipeline so it matches the synthesizer's output.
    /// AVSpeechSynthesizer.write returns PCM in the voice's natural rate,
    /// which is NOT always 22.05 kHz — Spanish enhanced voices on macOS 26
    /// often render at 24 kHz. Locking the connection format up front leaves
    /// the player silent.
    private var connectedFormat: AVAudioFormat?

    /// True when the active pipeline goes player → environment → main.
    /// False when it bypasses the environment for direct stereo through
    /// the speakers.
    private var spatialActive: Bool = false

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
    /// Default es-ES because the highest-quality Spanish neural voice on
    /// macOS 26 (Monica Premium) ships under that locale; es-MX/es-AR
    /// usually only have Compact builds available.
    private var preferredVoiceLanguage: String {
        let stored = UserDefaults.standard.string(forKey: "avatar_voice_lang") ?? ""
        return stored.isEmpty ? "es-ES" : stored
    }

    // MARK: - Public API

    /// Enqueue an announcement for the given session. If something is
    /// already speaking, the utterance waits its turn (FIFO).
    /// `text` is what gets spoken verbatim — the caller decides whether to
    /// prefix the session name (do that only when multiple sessions share
    /// the same spatial slot, otherwise the direction alone identifies it).
    func enqueue(text: String, slot: SpatialSlot, sessionId: String) {
        if muted { return }
        let u = Utterance(text: text, slot: slot, sessionId: sessionId)
        queue.append(u)
        log.info("enqueued utterance for session=\(sessionId, privacy: .public) slot=\(slot.rawValue, privacy: .public) qLen=\(self.queue.count, privacy: .public) text=\(text.prefix(80), privacy: .public)")
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
    /// resulting buffers into the player node, and resolve when playback
    /// finishes. On any failure we degrade silently and pop to the next
    /// utterance so a hung voice can never wedge the queue.
    ///
    /// The pipeline is reconfigured per-utterance based on the current
    /// output device:
    ///   • Headphones (any kind) → player → environment → main, HRTF on,
    ///     audible spatial separation per slot.
    ///   • Built-in speakers / external speakers → player → main, plain
    ///     stereo. Still spatializes via L/R balance from `position(slot:)`,
    ///     but no HRTF (which can mute audio on speakers in some configs).
    private func render(_ utterance: Utterance) async {
        let useSpatial = isHeadphonesActive()
        log.info("render slot=\(utterance.slot.rawValue, privacy: .public) spatial=\(useSpatial, privacy: .public)")

        let speech = AVSpeechUtterance(string: utterance.text)
        if let voice = preferredVoice() {
            speech.voice = voice
            log.info("voice=\(voice.identifier, privacy: .public) lang=\(voice.language, privacy: .public)")
        }
        // 92% of default speech rate — perceptibly slower without sounding
        // dragged. The default rate is too fast for an announcement that
        // wants to be understood from across the room.
        speech.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
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
                    self?.scheduleBuffer(pcm, useSpatial: useSpatial, slot: utterance.slot)
                }
            }
        }
    }

    /// Schedule a TTS buffer for playback. Lazily starts the engine, builds
    /// or rebuilds the pipeline at the buffer's actual format, and starts
    /// the player.
    private func scheduleBuffer(_ buffer: AVAudioPCMBuffer, useSpatial: Bool, slot: SpatialSlot) {
        ensureEnginePipeline(matching: buffer.format, useSpatial: useSpatial)
        if useSpatial { position(slot: slot) }

        if !engine.isRunning {
            do {
                try engine.start()
                log.info("engine started")
            } catch {
                log.error("engine.start failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// Build or rebuild the engine graph so it matches the incoming buffer
    /// format. Reconnect when the format or routing (spatial vs flat)
    /// changes — silently no-ops when nothing changed.
    private func ensureEnginePipeline(matching bufferFormat: AVAudioFormat, useSpatial: Bool) {
        let formatChanged = connectedFormat?.sampleRate != bufferFormat.sampleRate
            || connectedFormat?.channelCount != bufferFormat.channelCount
        let routingChanged = spatialActive != useSpatial
        let neverConfigured = player.engine == nil

        guard formatChanged || routingChanged || neverConfigured else { return }

        // Detach + re-attach to wipe any previous graph state.
        if player.engine != nil { engine.detach(player) }
        if environment.engine != nil { engine.detach(environment) }

        engine.attach(player)
        if useSpatial {
            engine.attach(environment)
            engine.connect(player, to: environment, format: bufferFormat)
            engine.connect(environment, to: engine.mainMixerNode, format: nil)
            environment.renderingAlgorithm = .HRTF
            environment.outputType = .headphones
            environment.distanceAttenuationParameters.referenceDistance = 0.5
            environment.distanceAttenuationParameters.maximumDistance = 5.0
            environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
            environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)
        } else {
            engine.connect(player, to: engine.mainMixerNode, format: bufferFormat)
        }

        connectedFormat = bufferFormat
        spatialActive = useSpatial
        log.info("pipeline rebuilt: spatial=\(useSpatial, privacy: .public) sampleRate=\(bufferFormat.sampleRate, privacy: .public) channels=\(bufferFormat.channelCount, privacy: .public)")
    }

    /// Best-effort detection of whether the current output route is
    /// headphones / AirPods / Bluetooth audio (anything where HRTF makes
    /// sense). On macOS, the AVAudioSession API isn't available — we use
    /// CoreAudio default-output-device transport type instead.
    private func isHeadphonesActive() -> Bool {
        var defaultOutput: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil, &size, &defaultOutput
        ) == noErr else { return false }

        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            defaultOutput, &addr, 0, nil, &size, &transport
        ) == noErr else { return false }

        // Only Bluetooth output (AirPods, BT headphones) gets the HRTF
        // path. Wired headphones and external speakers go through the
        // flat-stereo path because we can't distinguish them reliably and
        // HRTF over speakers sounds wrong. AirPods + head tracking is the
        // only configuration where 3D buys the user something dramatic.
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
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

    // MARK: - Voice selection

    private func preferredVoice() -> AVSpeechSynthesisVoice? {
        let lang = preferredVoiceLanguage
        let allSpanish = AVSpeechSynthesisVoice.speechVoices()
            .filter {
                $0.language == lang ||
                $0.language.hasPrefix(String(lang.prefix(2)))
            }

        // Strong preference for hand-picked neural voices when present —
        // Apple's highest-quality Spanish offerings on macOS 26.
        let preferredIdentifiers = [
            "com.apple.voice.premium.es-ES.Monica",
            "com.apple.voice.enhanced.es-ES.Monica",
            "com.apple.voice.premium.es-MX.Paulina",
            "com.apple.voice.enhanced.es-MX.Paulina",
            "com.apple.voice.premium.es-ES.Jorge",
            "com.apple.voice.enhanced.es-ES.Jorge"
        ]
        for id in preferredIdentifiers {
            if let v = allSpanish.first(where: { $0.identifier == id }) {
                return v
            }
        }

        // Fallback: any Spanish voice, sorted by quality (premium > enhanced > default).
        let sorted = allSpanish.sorted { lhs, rhs in
            lhs.quality.rawValue > rhs.quality.rawValue
        }
        return sorted.first ?? AVSpeechSynthesisVoice(language: lang)
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

}
