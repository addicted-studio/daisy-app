//
//  AudioRecorder.swift
//  Daisy
//
//  Captures microphone input via AVAudioEngine and broadcasts PCM buffers
//  to subscribers (the on-device transcriber) while optionally archiving
//  the raw audio to disk as a .caf file.
//
//  Everything runs locally. No audio leaves the device.
//

import Foundation
import AVFoundation
import CoreAudio
import Observation
import os

/// Ferry AVAudioPCMBuffer across actor boundaries. Buffers from
/// AVAudioEngine's input tap are not mutated by us after the tap closure
/// returns, so this is safe in practice.
///
/// `nonisolated` overrides the file-level default of MainActor isolation
/// so this struct can be constructed and destructured from any context
/// (audio render thread, ScreenCaptureKit output queue, etc.).
nonisolated struct AudioChunk: @unchecked Sendable {
    let pcm: AVAudioPCMBuffer
    let time: AVAudioTime
}

/// Thread-safe counter for archive-file write failures that happen on
/// the AVAudioEngine render thread. The tap closure can't reach into
/// MainActor state to log or toast inline (and shouldn't — render
/// thread must stay fast), so we accumulate and surface a single
/// summary on stop().
private final class WriteErrorBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<(count: Int, first: (any Error)?)>(initialState: (0, nil))

    func record(_ error: any Error) {
        lock.withLock { state in
            state.count += 1
            if state.first == nil { state.first = error }
        }
    }

    func snapshot() -> (count: Int, first: (any Error)?) {
        lock.withLock { $0 }
    }

    func reset() {
        lock.withLock { $0 = (0, nil) }
    }
}

/// Companion to WriteErrorBox — total audio frames that successfully
/// landed on disk via `try audioFile.write(from:)`. Same render-thread
/// constraint: incremented inside the installTap closure with no
/// MainActor hop. RecordingSession compares this against
/// `elapsed * sampleRate` and the on-disk file size to decide whether
/// the mic stream archive is healthy, empty, or truncated.
private final class FrameCountBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    func add(_ frames: UInt64) {
        lock.withLock { $0 &+= frames }
    }

    func snapshot() -> UInt64 {
        lock.withLock { $0 }
    }

    func reset() {
        lock.withLock { $0 = 0 }
    }
}

nonisolated enum DaisyError: LocalizedError {
    case noMicrophone
    case speechUnauthorized
    case onDeviceUnsupported(locale: String)
    case recognitionFailed(String)
    case audioEngineFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMicrophone:
            return "No microphone input is available."
        case .speechUnauthorized:
            return "Speech recognition permission was denied. Grant it in System Settings → Privacy & Security → Speech Recognition."
        case .onDeviceUnsupported(let locale):
            return "On-device speech recognition is not available for \(locale). Try a different language."
        case .recognitionFailed(let msg):
            return "Recognition failed: \(msg)"
        case .audioEngineFailed(let msg):
            return "Audio engine failed: \(msg)"
        }
    }
}

@Observable
@MainActor
final class AudioRecorder {
    enum RecordingState: Equatable {
        case idle
        case recording
        /// Engine is paused but the tap, audio file handle and
        /// bufferContinuation are preserved. `resume()` re-arms
        /// the engine and writes continue appending to the same
        /// .caf file.
        case paused
        case stopped
    }

    // MARK: - Observable state

    private(set) var state: RecordingState = .idle
    private(set) var levelDB: Float = -160
    private(set) var elapsed: TimeInterval = 0
    private(set) var lastError: String?
    private(set) var archivedFileURL: URL?
    /// Normalised 0…1 spectrum bands for the daisy widget's petals.
    /// Updated from the audio render thread via `Task @MainActor`.
    private(set) var spectrumBands: [Float] = Array(
        repeating: 0,
        count: SpectrumAnalyzer.bandCount
    )

    // MARK: - Private

    /// AVAudioEngine instance. **Mutable** (not `let`) because on
    /// macOS 26.5 `engine.reset()` doesn't actually flush the cached
    /// inputNode format after an AUHAL device swap (the Apple bug we
    /// chase in `handleConfigurationChange`'s de-sync guard). The
    /// only reliable workaround when reset() leaves us with a stale
    /// format is to throw away the engine entirely and build a new
    /// instance from scratch — `rebuildEngineAndRetry()` does this.
    /// Build 39 fix; pre-39 this was `let` and recovery silently
    /// paused the session on every EarPods unplug.
    @ObservationIgnored
    private var engine = AVAudioEngine()
    @ObservationIgnored
    private var audioFile: AVAudioFile?
    @ObservationIgnored
    private var bufferContinuation: AsyncStream<AudioChunk>.Continuation?
    @ObservationIgnored
    private var elapsedTimer: Timer?
    @ObservationIgnored
    private var startedAt: Date?
    /// Sum of completed active intervals before the current one.
    /// `elapsed` is computed as `accumulatedActiveSec + (now - startedAt)`
    /// so a pause/resume cycle doesn't make the counter jump over
    /// the time the user was paused — `elapsed` measures audio
    /// captured, not wall clock.
    private var accumulatedActiveSec: TimeInterval = 0
    @ObservationIgnored
    private let analyzer = SpectrumAnalyzer()
    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "AudioRecorder")
    @ObservationIgnored
    private let writeErrors = WriteErrorBox()
    /// Counter of audio frames that successfully landed in the
    /// AVAudioFile via `try fileRef.write(from: buffer)` on the render
    /// thread. Mirrors the symmetric counter in SystemAudioCapture and
    /// is the truthful "did anything actually persist?" answer that
    /// RecordingSession.stop() needs to decide between `.captured` and
    /// `.truncated` for frontmatter + the post-stop toast. Pre-1.0.7.1
    /// the only signal was `elapsed > 0` (wall-clock, NOT disk write
    /// success), which is what allowed the 2026-05-25 Billions test to
    /// land a 44-minute transcript on top of a 135.9-second mic.caf.
    @ObservationIgnored
    private let framesWritten = FrameCountBox()

    /// Stashed at `start()` time so the route-change recovery path can
    /// re-pin the engine to the same device after macOS yanks it out
    /// from under us (AirPods ↔ built-in, USB mic plug/unplug, etc.).
    /// Empty string == "follow system default".
    @ObservationIgnored
    private var activePreferredDeviceUID: String = ""

    /// Stable UID of the input device the AUHAL is *actually* bound to,
    /// refreshed inside `bindInputAUHAL` on every successful bind. This
    /// is the authoritative "device we're recording on" — set by US at
    /// bind time, NOT read back from the AUHAL (which, after a route-
    /// change graph teardown, can already report the NEW system-default
    /// device). The keep-device branch of `handleConfigurationChange`
    /// resolves THIS back to a live `AudioDeviceID` instead of trusting
    /// `currentAUHALInputDeviceID()`. nil until the first bind.
    @ObservationIgnored
    private var lastBoundInputUID: String?

    /// NotificationCenter token for the engine-configuration-change
    /// observer. Held so we can remove it on `stop()` and in `deinit`
    /// without retain-cycling through `self`. nil between sessions.
    @ObservationIgnored
    private var configChangeObserver: NSObjectProtocol?

    /// CoreAudio property-listener block for default-input-device
    /// changes. Catches the case `AVAudioEngineConfigurationChange`
    /// MISSES — wired output-only headphones (3.5mm jack) on some
    /// macOS versions reroute the input graph as a side effect but
    /// don't post the engine notification. Without this listener,
    /// recovery never runs for that device class and the tap goes
    /// silent for the rest of the session.
    @ObservationIgnored
    private var inputDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored
    private var inputDeviceListenerInstalled: Bool = false
    /// Wall-clock debounce — macOS often emits the property change
    /// 2-3 times in rapid succession as the audio graph settles.
    /// Mirrors the same debounce SystemAudioCapture uses.
    @ObservationIgnored
    private var lastInputRestartAt: Date?

    /// Audio-buffer arrival watchdog. After `engine.start()` completes
    /// in route-change recovery we arm a short timer; if no buffer has
    /// landed by the time it fires the recovery silently failed (AUHAL
    /// bound to a dead device, format mismatch we didn't catch, etc.)
    /// and we fall to `.paused` with a Resume toast rather than burn
    /// the rest of the meeting on a dead tap.
    @ObservationIgnored
    private var recoveryWatchdog: Timer?
    /// Monotonic generation for the recovery watchdog. Bumped on every
    /// arm AND cancel, captured in the timer closure, and re-checked in
    /// `checkRecoveryProgress`. Under route-change flapping a Timer can
    /// already have hopped its task to the MainActor by the time we
    /// cancel it; the generation guard makes that stale task a no-op
    /// instead of letting it act on an outdated `armedAt`.
    @ObservationIgnored
    private var recoveryGeneration: Int = 0
    /// Render-thread → MainActor bridge for last-buffer timestamp. The tap
    /// closure writes through this; the MainActor watchdog reads it.
    private final class BufferTimestampBox: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<Date?>(initialState: nil)
        func mark(_ at: Date) { lock.withLock { $0 = at } }
        func snapshot() -> Date? { lock.withLock { $0 } }
        func reset() { lock.withLock { $0 = nil } }
    }
    @ObservationIgnored
    private let bufferTimestamp = BufferTimestampBox()

    /// Render-thread → MainActor bridge for mic signal LIVENESS (level,
    /// not mere arrival). The tap records each sampled buffer's RMS;
    /// the MainActor silence monitor reads the last time RMS cleared the
    /// liveness floor. `lastRMS` is kept only so the trip log can report
    /// the level we paused on — some SCO stacks emit faint comfort-noise,
    /// useful for calibrating `micLivenessFloorDB` from real logs.
    private final class MicLivenessBox: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<(aboveFloorAt: Date?, lastRMS: Float)>(
            initialState: (nil, -160)
        )
        func record(rms: Float, at: Date, floor: Float) {
            lock.withLock { state in
                state.lastRMS = rms
                if rms > floor { state.aboveFloorAt = at }
            }
        }
        func snapshot() -> (aboveFloorAt: Date?, lastRMS: Float) { lock.withLock { $0 } }
        func reset(to date: Date?) { lock.withLock { $0 = (date, -160) } }
    }
    @ObservationIgnored
    private let micLiveness = MicLivenessBox()
    /// Repeating MainActor timer that runs the signal-level silence
    /// check while `.recording`. Distinct from `recoveryWatchdog`
    /// (one-shot, arrival-only, armed around route changes).
    @ObservationIgnored
    private var silenceMonitor: Timer?

    /// Format the engine's input bus is running at right now.
    /// Captured in `start()` and refreshed in `handleConfigurationChange`
    /// so we can detect when route-change recovery has put us on a
    /// device with a different sample rate / channel layout. AVAudioFile
    /// can't change format mid-write, so a real mismatch forces us to
    /// roll the archive into a new .partN.caf file.
    @ObservationIgnored
    private var lastInputFormat: AVAudioFormat?

    /// Every .caf file we've written for this session. First entry is
    /// `archivedFileURL` itself (the base path). Additional entries
    /// appear only when a mid-session route change brought a new
    /// input format — see `handleConfigurationChange`. Surfaced as
    /// a warning toast on `stop()` so the user knows to look for
    /// `microphone.part2.caf` etc. alongside the primary file.
    @ObservationIgnored
    private(set) var archivedParts: [URL] = []

    /// Total audio frames that successfully landed on disk via
    /// `try fileRef.write(from: buffer)`. RecordingSession compares
    /// this against `elapsed * sampleRate` and the on-disk file size
    /// to detect mid-session AVAudioFile write death (the 2026-05-25
    /// Billions failure: tap delivered ~44min of audio to the live
    /// transcriber but only 135.9s of it reached disk). Zero means
    /// every write threw or the tap was never installed.
    var archivedFrameCount: UInt64 {
        framesWritten.snapshot()
    }

    /// (errorCount, firstError) from render-thread write failures.
    /// Non-zero count combined with `archivedFrameCount` far below
    /// expected is the canonical truncation signal.
    var archiveWriteErrorsSummary: (count: Int, first: (any Error)?) {
        writeErrors.snapshot()
    }

    /// Monotonic part index, incremented each time we open a new
    /// .caf for a format change. Starts at 1 for the base file.
    @ObservationIgnored
    private var partCounter: Int = 0

    // MARK: - API

    /// Subscribe to PCM buffers as they arrive from the microphone.
    /// Read this property **before** calling `start()` so the continuation
    /// is installed before the tap fires.
    var buffers: AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            self.bufferContinuation = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.bufferContinuation = nil
                }
            }
        }
    }

    // prewarm() removed in 1.0.6.1 — was a no-op stub kept after
    // the 1.0.5 crash. If a future release wants a real prewarm,
    // gate it on `SystemPermissions.shared.microphone == .granted`
    // AND run it AFTER the first successful `start()` (engine state
    // is only sane post-first-record).

    /// Begin capturing microphone audio. Pass an `archiveURL` to also write
    /// a .caf file for later replay/re-processing. `preferredDeviceUID`
    /// is the stable `kAudioDevicePropertyDeviceUID` of the device the
    /// user picked in Settings; pass empty string (or nil) to follow
    /// the macOS system default.
    func start(archiveURL: URL? = nil, preferredDeviceUID: String? = nil) throws {
        guard state != .recording else { return }
        lastError = nil

        // Cache the device UID so the route-change recovery handler
        // can re-pin AVAudioEngine to the same device after macOS
        // tears the audio graph down. Empty string == follow system
        // default (the v1.0 behaviour the user explicitly chose).
        activePreferredDeviceUID = preferredDeviceUID ?? ""

        // Point AVAudioEngine.inputNode at the user-picked device
        // (if any) BEFORE we sample its output format — switching
        // devices after `outputFormat` is captured leaves us writing
        // to a file with the wrong sample rate / channel count.
        applyPreferredInputDevice(uid: activePreferredDeviceUID)

        // Subscribe to AVAudioEngineConfigurationChange BEFORE engine
        // start. macOS posts this when the audio graph is forcibly
        // torn down — AirPods disconnect, a USB mic is plugged or
        // pulled, the user re-routes Sound output in Control Centre,
        // or any other change that invalidates the engine's current
        // input/output formats. Without an observer, the engine quietly
        // stops, the tap fires no more buffers, and recording dies
        // silently mid-session. With one, we get a chance to restart
        // and keep going.
        if configChangeObserver == nil {
            configChangeObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: .main
            ) { [weak self] _ in
                // Hop to MainActor explicitly — NotificationCenter
                // queues an Operation, not a Task, so the closure
                // body runs nonisolated by default.
                Task { @MainActor [weak self] in
                    self?.handleConfigurationChange()
                }
            }
        }
        // Belt-and-braces default-input-device listener — catches
        // route changes that DON'T fire AVAudioEngineConfigurationChange
        // (wired output-only headphones on some macOS versions).
        installInputDeviceListener()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            throw DaisyError.noMicrophone
        }

        if let archiveURL {
            do {
                audioFile = try AVAudioFile(forWriting: archiveURL, settings: format.settings)
                archivedFileURL = archiveURL
                archivedParts = [archiveURL]
                partCounter = 1
            } catch {
                throw DaisyError.audioEngineFailed(error.localizedDescription)
            }
        } else {
            audioFile = nil
            archivedFileURL = nil
            archivedParts = []
            partCounter = 0
        }

        lastInputFormat = format
        writeErrors.reset()
        framesWritten.reset()
        bufferTimestamp.reset()
        installInputTap(format: format)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            audioFile = nil
            archivedFileURL = nil
            throw DaisyError.audioEngineFailed(error.localizedDescription)
        }

        startedAt = Date()
        elapsed = 0
        accumulatedActiveSec = 0
        state = .recording

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        startSilenceMonitor()
        // Arrival watchdog for the INITIAL start (was only armed in recovery
        // paths). engine.start() can return success while the mic delivers 0
        // frames — a wired headset opened at a mis-negotiated rate (the
        // 2026-06-01 "Kirill" call: base 44100 Hz / 0 frames, real audio only
        // in part2 at 48000 Hz after a later route change). On no-buffers-in-5s
        // this escalates to a full engine rebuild (re-resolves device +
        // format) rather than pausing, so an auto-started meeting doesn't
        // silently lose the user's voice.
        armRecoveryWatchdog(escalateToRebuild: true)

        log.info("AudioRecorder started")
    }

    /// Soft pause. Engine stops processing buffers, but the tap, the
    /// audio file handle and the bufferContinuation all stay alive —
    /// `resume()` re-arms the engine and writes continue appending
    /// to the same .caf file with no perceptible gap (audio time
    /// jumps; wall clock doesn't, by design).
    func pause() {
        guard state == .recording else { return }
        cancelRecoveryWatchdog()
        stopSilenceMonitor()
        engine.pause()
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        // Bank the active interval that just ended so `elapsed`
        // doesn't reset when we resume.
        if let startedAt {
            accumulatedActiveSec += Date().timeIntervalSince(startedAt)
        }
        startedAt = nil
        // Level + spectrum visually decay to zero while paused so
        // the widget reads as "not listening" rather than "frozen".
        levelDB = -160
        spectrumBands = Array(repeating: 0, count: SpectrumAnalyzer.bandCount)
        state = .paused
        log.info("AudioRecorder paused after \(self.elapsed, privacy: .public)s")
    }

    /// Resume after `pause()`. Re-derives the AUHAL binding + audio
    /// format from current HW state before starting the engine — this
    /// is the symmetric counterpart of `handleConfigurationChange()`
    /// for the mic-paused-then-device-changed scenario.
    ///
    /// **The bug this fixes (build 44 → 45):** the previous resume()
    /// just called `engine.start()` and re-armed the watchdog, on the
    /// assumption that pause was always user-intentional and the
    /// hardware was unchanged. That breaks in two real-world flows
    /// captured in `daisy-log-1054.txt`:
    /// (a) `fallToPaused()` from a watchdog-triggered route-change
    ///     recovery — the engine is paused with a tap format cached
    ///     from the OLD device (e.g. 16 kHz BT-SCO mic), and by the
    ///     time the user presses Resume the BT headphones may be
    ///     gone and the active device is now BuiltIn at 48 kHz.
    ///     `engine.start()` returns success but the very next buffer
    ///     arrival blows up with
    ///         `kAudioUnitErr_FormatNotSupported (-10868)`
    ///     ("Error, formats don't match! HW format: 48000 Hz, tap
    ///     format: 16000 Hz" in CoreAudio's log).
    /// (b) User manually pauses → switches mic in Settings (or unplugs
    ///     EarPods) → presses Resume. Same stale-format situation, just
    ///     reached via the intentional pause path.
    ///
    /// The fix mirrors `handleConfigurationChange()`'s recovery flow:
    /// re-pin AUHAL → `engine.reset()` to flush the stale outputFormat
    /// cache → re-derive format from `inputNode.outputFormat(forBus:)`
    /// → CoreAudio cross-check → on de-sync escalate to
    /// `rebuildEngineAndRetry()` → otherwise roll the archive into a
    /// new part if the format changed (existing AVAudioFile can't
    /// accept the new format) → install fresh tap → start engine.
    func resume() throws {
        guard state == .paused else { return }

        // --- Symmetric recovery prep (see header comment) ---
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        applyPreferredInputDevice(uid: activePreferredDeviceUID)
        engine.reset()

        let newFormat = input.outputFormat(forBus: 0)
        guard newFormat.channelCount > 0 else {
            log.error("Resume failed — no input channels available on current device.")
            throw DaisyError.audioEngineFailed("No audio input device available. Connect a mic and try again.")
        }

        // Same CoreAudio cross-check the route-change path uses.
        // Catches the macOS 26.5 stale-format-after-reset() case
        // where outputFormat() returns the prior device's rate.
        if let auDeviceID = currentAUHALInputDeviceID(),
           let hwSampleRate = AudioInputDevices.streamFormatSampleRate(for: auDeviceID),
           abs(newFormat.sampleRate - hwSampleRate) > 0.5 {
            log.warning("Format de-sync at resume: AVAudioEngine reports \(newFormat.sampleRate, privacy: .public) Hz, CoreAudio reports \(hwSampleRate, privacy: .public) Hz on device \(auDeviceID, privacy: .public). Attempting full engine rebuild.")
            log.warning("De-sync diag: \(AudioInputDevices.streamRateDiagnostics(for: auDeviceID), privacy: .public)")
            guard rebuildEngineAndRetry() else {
                log.error("Engine rebuild on resume failed. Staying paused.")
                throw DaisyError.audioEngineFailed("Mic device changed and the audio engine couldn't reinitialize. Hit Record to start a new session.")
            }
            // rebuildEngineAndRetry() installed a fresh tap on a brand
            // new engine, called engine.start(), and armed its own
            // watchdog. We only need to flip state machine bookkeeping
            // — same bookkeeping the non-rebuild happy-path does below.
            startedAt = Date()
            elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
            state = .recording
            startSilenceMonitor()
            log.info("AudioRecorder resumed via engine rebuild")
            return
        }

        // Roll archive if the active device's format differs from what
        // we were writing pre-pause (e.g. paused on BuiltIn 48 kHz →
        // user plugged EarPods 44.1 kHz → resumed). AVAudioFile can't
        // ingest frames in a different format than it was opened with,
        // so silent data-loss is the alternative if we just kept the
        // old file handle.
        let formatChanged = !(lastInputFormat.map { Self.formatsAreEqual($0, newFormat) } ?? false)
        if formatChanged, let baseURL = archivedFileURL {
            audioFile = nil
            partCounter += 1
            let newPartURL = Self.makePartURL(base: baseURL, part: partCounter)
            do {
                audioFile = try AVAudioFile(forWriting: newPartURL, settings: newFormat.settings)
                archivedParts.append(newPartURL)
                let oldRate = lastInputFormat?.sampleRate ?? 0
                let oldChans = lastInputFormat?.channelCount ?? 0
                log.warning("Audio format changed at resume (\(oldRate, privacy: .public) Hz / \(oldChans, privacy: .public) ch → \(newFormat.sampleRate, privacy: .public) Hz / \(newFormat.channelCount, privacy: .public) ch). Archive rolled to \(newPartURL.lastPathComponent, privacy: .public).")
            } catch {
                log.error("Failed to open part \(self.partCounter, privacy: .public) for new format at resume: \(error.localizedDescription, privacy: .public). Continuing without archive for this part.")
                audioFile = nil
            }
        }

        // Only advance the format baseline when we have a live file to
        // match it (or aren't archiving at all). If a format-change roll
        // FAILED to open the new part, keep the OLD baseline so the next
        // route change re-detects the change and retries the roll, instead
        // of marking us "in sync" with a format we have no open file for —
        // which would silently kill the archive until stop().
        if audioFile != nil || archivedFileURL == nil {
            lastInputFormat = newFormat
        }
        installInputTap(format: newFormat)

        // Re-prepare before start — same belt-and-braces reasoning as
        // the route-change path: AVAudioEngine's internal AU state was
        // touched by `reset()` above and some macOS versions throw
        // `kAudioUnitErr_Uninitialized` from `start()` without it.
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw DaisyError.audioEngineFailed(error.localizedDescription)
        }

        // Open a new active interval; `tick` will sum it with
        // `accumulatedActiveSec` for the user-visible elapsed value.
        startedAt = Date()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        state = .recording
        // engine.start() can return success while AUHAL is on a stale
        // or dead device. Watchdog falls us to paused if no buffer
        // arrives within 5s.
        armRecoveryWatchdog()
        startSilenceMonitor()
        log.info("AudioRecorder resumed")
    }

    func stop() {
        // Tolerate stop-from-paused too: the explicit Stop & save
        // path may come straight from a paused session.
        guard state == .recording || state == .paused else { return }
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        removeInputDeviceListener()
        cancelRecoveryWatchdog()
        stopSilenceMonitor()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        bufferContinuation?.finish()
        bufferContinuation = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        audioFile = nil  // closes the file
        analyzer.reset()
        spectrumBands = Array(repeating: 0, count: SpectrumAnalyzer.bandCount)
        state = .stopped
        log.info("AudioRecorder stopped after \(self.elapsed, privacy: .public)s")

        // Surface any render-thread write failures. A few drops are
        // tolerable (transient disk pressure), a flood means the
        // archive is likely incomplete.
        let (errCount, firstErr) = writeErrors.snapshot()
        if errCount > 0 {
            let firstMessage = firstErr?.localizedDescription ?? "unknown"
            log.error("\(errCount, privacy: .public) audio buffer write(s) failed during recording. First: \(firstMessage, privacy: .public)")
            if errCount > 25 {
                ToastCenter.shared.show(
                    "Audio archive may be incomplete — \(errCount) write errors.",
                    style: .warning
                )
            }
        }

        // Surface multi-part archives — these only happen when a
        // mid-session route change brought a new input format, so
        // the user needs to know there's more than one .caf to look
        // at in the session folder.
        if archivedParts.count > 1 {
            let names = archivedParts.map(\.lastPathComponent).joined(separator: ", ")
            log.warning("Recording split across \(self.archivedParts.count, privacy: .public) parts due to format change(s): \(names, privacy: .public)")
            ToastCenter.shared.show(
                "Recording saved as \(archivedParts.count) parts — mic format changed mid-session.",
                style: .info
            )
        }
    }

    /// Handle `AVAudioEngineConfigurationChange`. macOS posts this
    /// when the audio graph is forcibly invalidated — AirPods
    /// disconnect, USB mic plug/unplug, Sound output re-route via
    /// Control Centre, sleep/wake, etc. The engine has already
    /// stopped itself by the time we get here. Without recovery
    /// recording dies silently; with this handler we keep going
    /// over the new device.
    ///
    /// Strategy: tear down tap + audio-file path, re-pin to the
    /// user's preferred device, read the *new* input format, then:
    ///
    ///   - if the new format MATCHES the old one (the common case —
    ///     AirPods ↔ built-in, both 48 kHz stereo) we just reinstall
    ///     the tap with the same format and the existing AVAudioFile
    ///     keeps accepting writes;
    ///   - if the new format DIFFERS (sample rate, channel count,
    ///     interleave, or commonFormat) we close the current file
    ///     (flushing it to disk), bump `partCounter` and open a
    ///     fresh `<base>.partN.caf` with the new format. Old part
    ///     stays on disk intact — we surface a multi-part toast at
    ///     `stop()` so the user knows to grab both. This is the
    ///     fix for the silent-data-loss bug where a mid-session
    ///     route change to a different-format device caused every
    ///     subsequent buffer write to fail format-mismatch into
    ///     `writeErrors` while `elapsed` kept ticking — 50+ minutes
    ///     of audio gone with no in-app indication.
    ///
    /// Not invoked during `.paused` (user-intentional) or `.stopped`.
    /// `.idle` shouldn't happen — observer is only registered after
    /// `start()` flips state to `.recording`.
    private func handleConfigurationChange() {
        guard state == .recording else {
            log.info("Config change ignored (state=\(String(describing: self.state), privacy: .public))")
            return
        }
        // Single debounce point for BOTH the NotificationCenter
        // observer and the CoreAudio default-input listener. A single
        // route change (AirPods disconnect, USB plug, etc.) typically
        // fires BOTH notifications; without this guard they run
        // recovery concurrently on the MainActor — second run tears
        // down a tap the first just installed.
        if let last = lastInputRestartAt,
           Date().timeIntervalSince(last) < 2.0 {
            log.info("Config change debounced — last restart \(Date().timeIntervalSince(last), privacy: .public)s ago")
            return
        }
        lastInputRestartAt = Date()

        log.warning("Audio configuration changed mid-recording — engine stopped by macOS, attempting recovery")

        // Tear down the audio graph — the tap was bound to the old
        // input format and would otherwise either silently drop
        // buffers or write format-mismatched frames into the file.
        let input = engine.inputNode
        input.removeTap(onBus: 0)

        // Belt-and-braces engine stop. AVAudioEngineConfigurationChange
        // signals that the *configuration* changed, not necessarily that
        // the engine itself transitioned to stopped — on some hardware /
        // macOS 26.2 the engine remains in a running state from
        // AVAudioEngine's perspective even though the underlying graph
        // is dead. Calling stop() unconditionally ensures `reset()`
        // below sees a clean, stopped engine.
        if engine.isRunning {
            engine.stop()
        }

        // Re-pin BEFORE reading the new format (device choice determines
        // the format). Decide whether to KEEP the device we were recording
        // on or FOLLOW the new system default.
        //
        // We override the OS in exactly ONE case: an unpinned session
        // where the new default INPUT is a Bluetooth device. Connecting
        // AirPods for *output* makes macOS flip the default input onto
        // their SCO mic, which frequently delivers pure silence — the
        // arrival watchdog passes, status stays .recording, and the rest
        // of the meeting records nothing. We don't trust that flip and
        // keep the device we were already on. For a wired/USB input
        // change (transport ≠ Bluetooth) the user intends it, so we
        // follow it; and a pinned mic always follows the pinned UID.
        //
        // The device-to-keep is resolved from `lastBoundInputUID` (the
        // UID we recorded at bind time), NOT from `currentAUHALInputDeviceID()`:
        // after the graph teardown the AUHAL can already report the new
        // BT device, which would make "keep current" silently keep the
        // very device we're trying to avoid. UID is stable across the
        // teardown; AudioDeviceID is session-local. (To intentionally
        // record through a BT mic, pick it in Settings — that sets a
        // pinned UID and takes the follow branch below.)
        let deviceBefore = currentAUHALInputDeviceID()   // logging only
        let newDefaultID = AudioInputDevices.systemDefaultInputID()
        let newDefaultIsBluetooth = newDefaultID != 0 && AudioInputDevices.isBluetooth(newDefaultID)

        if activePreferredDeviceUID.isEmpty,
           newDefaultIsBluetooth,
           let keepUID = lastBoundInputUID,
           let keepID = AudioInputDevices.deviceID(forUID: keepUID) {
            log.info("Config change, no pinned mic — new system-default input is Bluetooth; keeping the device we were recording on (UID \(keepUID, privacy: .public), id \(keepID, privacy: .public); AUHAL now reports \(deviceBefore ?? 0, privacy: .public)) to stop a BT-output route hijacking the recording mic.")
            bindInputAUHAL(to: keepID)
        } else {
            applyPreferredInputDevice(uid: activePreferredDeviceUID)
        }

        // The bug this fixes (build 33 → 34, macOS 26.2): AVAudioEngine
        // caches `inputNode.outputFormat(forBus: 0)` from the AUHAL's
        // PREVIOUS device binding and does NOT auto-refresh after we
        // change the AU's `kAudioOutputUnitProperty_CurrentDevice`.
        // Without `reset()` here, the read on the next line returns
        // the stale pre-route-change format (e.g. 44.1 kHz from
        // disconnected EarPods) while the AUHAL is actually now bound
        // to a 48 kHz BuiltIn mic. The subsequent `installTap(…, format:)`
        // trips Apple's internal assertion
        //     `format.sampleRate == inputHWFormat.sampleRate`
        // and the app crashes with an Obj-C exception that punches
        // straight through our Swift error handling.
        //
        // `engine.reset()` forces the inputNode's audio unit to
        // re-init against the now-current AudioDeviceID, so the
        // following `outputFormat(forBus:)` reads fresh state.
        //
        // Refs: Apple DevForum threads 680785 ("AVAudioEngine sample
        // rate mismatch on newer devices") and 683348 ("output format
        // 0ch after setDeviceID"). AudioKit follows the same pattern
        // in `AVAudioEngine+Devices.swift`.
        engine.reset()

        let newFormat = input.outputFormat(forBus: 0)
        guard newFormat.channelCount > 0 else {
            log.error("Recovery failed — no input channels available after route change. Pausing.")
            fallToPaused()
            ToastCenter.shared.show(
                "Mic disconnected — recording paused. Connect a mic and hit Resume.",
                style: .warning
            )
            return
        }

        // Defensive cross-check against the actual hardware. Even with
        // `engine.reset()` above, on macOS 26.5 `outputFormat(forBus:)`
        // routinely returns the PREVIOUS device's cached format (caught
        // build 36/37 logs: AVE reports 44100 Hz from disconnected
        // EarPods while the AUHAL is bound to BuiltIn at 48000 Hz).
        // Ask CoreAudio directly what sample rate the now-bound device
        // reports. If the two disagree, escalate to a full engine
        // rebuild — that's the only thing that actually flushes the
        // cached format on 26.5. If even the rebuild can't get a
        // matching format we fall to paused with a "Hit Resume" toast.
        if let auDeviceID = currentAUHALInputDeviceID(),
           let hwSampleRate = AudioInputDevices.streamFormatSampleRate(for: auDeviceID),
           abs(newFormat.sampleRate - hwSampleRate) > 0.5 {
            log.warning("Format de-sync after route change: AVAudioEngine reports \(newFormat.sampleRate, privacy: .public) Hz, CoreAudio reports \(hwSampleRate, privacy: .public) Hz on device \(auDeviceID, privacy: .public). Attempting full engine rebuild.")
            log.warning("De-sync diag: \(AudioInputDevices.streamRateDiagnostics(for: auDeviceID), privacy: .public)")
            if rebuildEngineAndRetry() {
                log.info("Recovery via engine rebuild succeeded — recording continues")
                ToastCenter.shared.show(
                    "Mic device changed — recording continues.",
                    style: .info
                )
                return
            }
            log.error("Engine rebuild also failed. Falling to paused.")
            fallToPaused()
            ToastCenter.shared.show(
                "Mic format changed — recording paused. Hit Resume to retry.",
                style: .warning
            )
            return
        }

        let formatChanged = !(lastInputFormat.map { Self.formatsAreEqual($0, newFormat) } ?? false)

        if formatChanged, let baseURL = archivedFileURL {
            // Close current file (flushes the header + any pending
            // frames to disk) and roll the archive into a new part
            // with the new format. AVAudioFile can't accept frames
            // in a format different from the one it was opened with,
            // so any attempt to keep writing to the same handle
            // would land us back in the silent-data-loss scenario.
            audioFile = nil
            partCounter += 1
            let newPartURL = Self.makePartURL(base: baseURL, part: partCounter)
            do {
                audioFile = try AVAudioFile(forWriting: newPartURL, settings: newFormat.settings)
                archivedParts.append(newPartURL)
                let oldRate = lastInputFormat?.sampleRate ?? 0
                let oldChans = lastInputFormat?.channelCount ?? 0
                log.warning("Audio format changed (\(oldRate, privacy: .public) Hz / \(oldChans, privacy: .public) ch → \(newFormat.sampleRate, privacy: .public) Hz / \(newFormat.channelCount, privacy: .public) ch). Archive rolled to \(newPartURL.lastPathComponent, privacy: .public).")
            } catch {
                log.error("Failed to open part \(self.partCounter, privacy: .public) for new format: \(error.localizedDescription, privacy: .public). Continuing without archive.")
                audioFile = nil
            }
        }

        // Only advance the format baseline when we have a live file to
        // match it (or aren't archiving at all). If a format-change roll
        // FAILED to open the new part, keep the OLD baseline so the next
        // route change re-detects the change and retries the roll, instead
        // of marking us "in sync" with a format we have no open file for —
        // which would silently kill the archive until stop().
        if audioFile != nil || archivedFileURL == nil {
            lastInputFormat = newFormat
        }
        installInputTap(format: newFormat)

        // Re-prepare the engine graph BEFORE start() — the route
        // change torn down internal AU state, and on some devices
        // skipping prepare() lets engine.start() throw
        // `kAudioUnitErr_Uninitialized`. Cheap when not needed
        // (idempotent), saves a "Mic changed — recording paused"
        // toast on the affected hardware.
        engine.prepare()

        do {
            try engine.start()
            log.info("Audio engine restarted after route change — recording continues")
            let toastBody: String
            if formatChanged {
                toastBody = "Mic device changed — recording continues in a new file (\(archivedParts.count) parts so far)."
            } else {
                toastBody = "Mic device changed — recording continues."
            }
            ToastCenter.shared.show(toastBody, style: .info)
            // Engine reports started but the AUHAL can still be bound
            // to a dead device. Watchdog falls us to .paused if no
            // buffer arrives within 5s.
            armRecoveryWatchdog()
        } catch {
            // Engine refused to come back. Don't kill the session —
            // mark it paused so the user can hit Resume manually
            // after their hardware settles. The existing pause/resume
            // path is the cleanest re-entry point.
            log.error("Engine restart after route change failed: \(error.localizedDescription, privacy: .public). Falling to paused state.")
            fallToPaused()
            ToastCenter.shared.show(
                "Mic changed — recording paused. Hit Resume to continue.",
                style: .warning
            )
        }
    }

    // MARK: - Full engine rebuild (macOS 26.5 stale-format workaround)

    /// Throw away the current `AVAudioEngine` and build a fresh
    /// instance, then re-run the start sequence (pin device → read
    /// format → install tap → prepare → start). The programmatic
    /// equivalent of "user presses Stop, then Record again".
    ///
    /// **Why this exists:** on macOS 26.5 `engine.reset()` does NOT
    /// flush AVAudioEngine's cached inputNode format. After an AUHAL
    /// device swap (EarPods unplug → BuiltIn mic takes over),
    /// `inputNode.outputFormat(forBus: 0)` keeps returning the
    /// previous device's format indefinitely, and the de-sync guard
    /// in `handleConfigurationChange` ends up firing on every route
    /// change → session falls to paused, user sees "audio doesn't
    /// record" with no recovery path other than Stop+Record. Build
    /// 34/35/36/37 all hit this. Recreating the engine is the only
    /// thing that drops the cache.
    ///
    /// Returns `true` if rebuild + start succeeded, `false` if even
    /// the new engine can't get a coherent format or refuses to start
    /// (in which case the caller falls back to `.paused` with a Resume
    /// toast).
    ///
    /// Preserves: `archiveURL`, `bufferContinuation`, `analyzer`,
    /// `framesWritten` / `writeErrors` totals (so the post-stop audit
    /// counts across the rebuild boundary). Rolls the archive into a
    /// new `.partN.caf` if the new format differs, same as the
    /// in-place recovery path did.
    private func rebuildEngineAndRetry() -> Bool {
        // Tear down the old engine. The observer is bound to the old
        // engine *instance* (the `object:` arg to addObserver was the
        // `engine` we're about to throw away), so it must be removed
        // here and re-added against the new instance below — otherwise
        // future ConfigurationChange notifications come through on a
        // dead observer and recovery never runs.
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }

        // Replace the engine. The old instance becomes orphaned and
        // is released by ARC once nothing else references it (Sparkle's
        // appcast XHR or some other unrelated retain won't pin it).
        engine = AVAudioEngine()

        // Re-pin to the user's preferred device on the NEW engine's
        // inputNode AUHAL. Same call as the original `start()` path —
        // applies the saved `activePreferredDeviceUID` (empty string
        // == "follow system default").
        applyPreferredInputDevice(uid: activePreferredDeviceUID)

        let input = engine.inputNode
        let newFormat = input.outputFormat(forBus: 0)
        guard newFormat.channelCount > 0 else {
            log.error("Engine rebuild failed — no input channels available on the new engine instance.")
            return false
        }

        // Cross-check the rebuilt engine's reported format against
        // CoreAudio's direct read. If it STILL disagrees after a full
        // engine rebuild, we're in deep water (likely a kernel-side
        // AUHAL bug rather than the SwiftUI-layer cache) — give up
        // auto-recovery rather than crash in installTap.
        if let auDeviceID = currentAUHALInputDeviceID(),
           let hwSampleRate = AudioInputDevices.streamFormatSampleRate(for: auDeviceID),
           abs(newFormat.sampleRate - hwSampleRate) > 0.5 {
            log.error("Engine rebuild produced ANOTHER format de-sync: AVE \(newFormat.sampleRate, privacy: .public) Hz vs CoreAudio \(hwSampleRate, privacy: .public) Hz. Auto-recovery exhausted.")
            log.error("De-sync diag: \(AudioInputDevices.streamRateDiagnostics(for: auDeviceID), privacy: .public) | AVE reports \(newFormat.sampleRate, privacy: .public)Hz/\(newFormat.channelCount, privacy: .public)ch")
            return false
        }

        // Roll archive if format differs from what we had pre-rebuild
        // (e.g., 44.1 kHz EarPods → 48 kHz BuiltIn). AVAudioFile can't
        // accept frames in a different format than it was opened with,
        // so the only way to keep writing is a new .partN.caf.
        let formatChanged = !(lastInputFormat.map { Self.formatsAreEqual($0, newFormat) } ?? false)
        if formatChanged, let baseURL = archivedFileURL {
            audioFile = nil
            partCounter += 1
            let newPartURL = Self.makePartURL(base: baseURL, part: partCounter)
            do {
                audioFile = try AVAudioFile(forWriting: newPartURL, settings: newFormat.settings)
                archivedParts.append(newPartURL)
                let oldRate = lastInputFormat?.sampleRate ?? 0
                log.warning("Engine-rebuild rolled archive (\(oldRate, privacy: .public) Hz → \(newFormat.sampleRate, privacy: .public) Hz) → \(newPartURL.lastPathComponent, privacy: .public)")
            } catch {
                log.error("Failed to open part \(self.partCounter, privacy: .public) for new format: \(error.localizedDescription, privacy: .public). Continuing without archive for this part.")
                audioFile = nil
            }
        }

        // Only advance the format baseline when we have a live file to
        // match it (or aren't archiving at all). If a format-change roll
        // FAILED to open the new part, keep the OLD baseline so the next
        // route change re-detects the change and retries the roll, instead
        // of marking us "in sync" with a format we have no open file for —
        // which would silently kill the archive until stop().
        if audioFile != nil || archivedFileURL == nil {
            lastInputFormat = newFormat
        }
        installInputTap(format: newFormat)

        // Re-register the ConfigurationChange observer against the
        // NEW engine instance — the previous one was removed above.
        // Without this, the next route change on the rebuilt engine
        // wouldn't trigger our handler and we'd silently die.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleConfigurationChange()
            }
        }

        engine.prepare()
        do {
            try engine.start()
            // Same watchdog the in-place recovery arms — engine.start()
            // can return success while AUHAL silently delivers no
            // buffers. Watchdog catches that within 5s.
            armRecoveryWatchdog()
            return true
        } catch {
            log.error("Rebuilt engine.start() failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Default-input-device listener (CoreAudio)

    /// Subscribe to `kAudioHardwarePropertyDefaultInputDevice` so we
    /// catch route changes that `AVAudioEngineConfigurationChange`
    /// silently misses. Idempotent — guarded by `inputDeviceListenerInstalled`.
    private func installInputDeviceListener() {
        guard !inputDeviceListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // CoreAudio dispatches on the queue we pass below — off
            // main. Hop back to MainActor for recovery logic.
            Task { @MainActor [weak self] in
                self?.handleDefaultInputDeviceChange()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated),
            block
        )
        if status == noErr {
            inputDeviceListenerBlock = block
            inputDeviceListenerInstalled = true
            log.info("Default input device listener installed")
        } else {
            log.error("Failed to install default input listener: status=\(status, privacy: .public)")
        }
    }

    private func removeInputDeviceListener() {
        guard inputDeviceListenerInstalled, let block = inputDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated),
            block
        )
        if status != noErr {
            log.error("Failed to remove default input listener: status=\(status, privacy: .public)")
        }
        inputDeviceListenerBlock = nil
        inputDeviceListenerInstalled = false
    }

    /// CoreAudio fired a default-input-device change. Debounce against
    /// the rapid-fire 2-3-times pattern macOS uses while the audio
    /// graph settles, then re-run the same recovery path as
    /// `handleConfigurationChange` — the two notifications cover
    /// overlapping-but-not-identical sets of route changes, and we
    /// want either one to be enough to keep us alive.
    private func handleDefaultInputDeviceChange() {
        guard state == .recording else { return }
        log.info("Default input device changed mid-recording — running route-change recovery")
        // Debounce against double-fire (NC + CoreAudio for the same
        // event) lives inside handleConfigurationChange — single
        // chokepoint, single timestamp. Don't gate here too.
        handleConfigurationChange()
    }

    // MARK: - Recovery watchdog

    /// Arm a short timer that checks `bufferTimestamp` after a route-
    /// change recovery. If no buffer arrived AFTER the arm time, the
    /// recovery silently failed (AUHAL on a dead device, etc.) and we
    /// fall to `.paused` rather than letting the user record minutes
    /// of nothing.
    ///
    /// Uses `armedAt` (wall-clock at arm time), NOT a snapshot of the
    /// last buffer's timestamp, as the comparison baseline. A flapping
    /// route change can re-arm this watchdog mid-window; with a
    /// snapshot-of-last-buffer baseline, a buffer that arrived BETWEEN
    /// the two arms would falsely satisfy the second check on stale
    /// data. armedAt requires a strictly POST-arm buffer, which is the
    /// only signal that actually proves the new graph is alive.
    private func armRecoveryWatchdog(deadline: TimeInterval = 5.0, escalateToRebuild: Bool = false) {
        cancelRecoveryWatchdog()
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        let armedAt = Date()
        recoveryWatchdog = Timer.scheduledTimer(withTimeInterval: deadline, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkRecoveryProgress(armedAt: armedAt, generation: generation, escalateToRebuild: escalateToRebuild)
            }
        }
    }

    private func cancelRecoveryWatchdog() {
        recoveryWatchdog?.invalidate()
        recoveryWatchdog = nil
        // Bump so an already-fired-but-not-yet-run timer task bails out.
        recoveryGeneration &+= 1
    }

    private func checkRecoveryProgress(armedAt: Date, generation: Int, escalateToRebuild: Bool = false) {
        // A newer arm/cancel happened after this timer fired (route-change
        // flapping) — act on it and we'd be using a stale armedAt.
        guard generation == recoveryGeneration else {
            log.info("Stale recovery watchdog (gen \(generation, privacy: .public) ≠ \(self.recoveryGeneration, privacy: .public)) — ignoring.")
            return
        }
        recoveryWatchdog = nil
        guard state == .recording else { return }
        let current = bufferTimestamp.snapshot()
        // Healthy: at least one buffer arrived strictly after arm time.
        if let c = current, c > armedAt { return }

        // No buffers post-arm. When this watchdog was armed right after the
        // INITIAL start() (escalateToRebuild=true), the mic opened on a
        // device/format that delivers nothing — the wired-headset-at-44100 /
        // 0-frame case (2026-06-01 "Kirill" call: base file 44100 Hz / 0
        // frames, audio only landed once a route change rolled part2 at 48
        // kHz). A full engine rebuild re-resolves the device + format and
        // rolls a fresh part — far better than pausing an unattended
        // auto-started meeting and losing the user's voice. rebuildEngineAndRetry
        // arms its OWN (non-escalating) watchdog, so a second failure falls
        // to paused — no rebuild loop.
        if escalateToRebuild {
            log.error("Recovery watchdog fired at start — no buffers post-arm. Rebuilding engine before pausing.")
            if rebuildEngineAndRetry() { return }
            log.error("Start-time rebuild failed — falling to paused.")
        } else {
            log.error("Recovery watchdog fired — no audio buffers post-arm. Falling to paused.")
        }
        fallToPaused()
        ToastCenter.shared.show(
            "Mic stopped delivering audio — recording paused. Hit Resume to retry.",
            style: .warning
        )
    }

    /// Centralised "drop to paused" used by the route-change recovery
    /// when the engine refuses to come back or the new device has no
    /// usable channels. Preserves `accumulatedActiveSec` and clears
    /// the level/spectrum so the widget doesn't appear frozen.
    private func fallToPaused() {
        cancelRecoveryWatchdog()
        stopSilenceMonitor()
        // Clear the debounce so a follow-up CoreAudio listener fire
        // (user plugged a working mic right after the fall) isn't
        // swallowed by the 2-sec window — they deserve to recover.
        lastInputRestartAt = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if let startedAt {
            accumulatedActiveSec += Date().timeIntervalSince(startedAt)
        }
        startedAt = nil
        levelDB = -160
        spectrumBands = Array(repeating: 0, count: SpectrumAnalyzer.bandCount)
        state = .paused
    }

    // MARK: - Mic silence watchdog (signal level, not arrival)

    private func startSilenceMonitor() {
        stopSilenceMonitor()
        micLiveness.reset(to: Date())   // grace anchor from now
        silenceMonitor = Timer.scheduledTimer(
            withTimeInterval: Self.silenceMonitorIntervalSec, repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkMicSilence() }
        }
    }

    private func stopSilenceMonitor() {
        silenceMonitor?.invalidate()
        silenceMonitor = nil
    }

    /// Signal-level dead-input check, run on a timer while recording.
    /// The arrival watchdog only proves *some* buffer landed; this proves
    /// the buffers carry SIGNAL. If mic RMS has stayed below the liveness
    /// floor for `micSilenceWindowSec` (zero excursions above it), the
    /// input is delivering silence — BT-SCO, hardware mute, a dead device,
    /// or any future silent path — so the meeting is recording nothing.
    /// Pause and tell the user. This is the catch-all the keep-device fix
    /// can't be: it fires even if we ended up on a silent device anyway.
    private func checkMicSilence() {
        guard state == .recording else { return }
        let snap = micLiveness.snapshot()
        // `aboveFloorAt` is re-anchored to "now" whenever the tap is
        // (re)installed or the monitor (re)starts, so it's non-nil
        // throughout a recording; the guard is purely defensive.
        guard let reference = snap.aboveFloorAt else { return }
        let silentFor = Date().timeIntervalSince(reference)
        guard silentFor >= Self.micSilenceWindowSec else { return }
        log.error("Mic silence watchdog fired — RMS below \(Self.micLivenessFloorDB, privacy: .public) dBFS for \(Int(silentFor), privacy: .public)s (last RMS \(snap.lastRMS, privacy: .public) dBFS). Falling to paused.")
        fallToPaused()
        ToastCenter.shared.show(
            "Mic went silent — recording paused. Check your mic (Bluetooth mics often record silence) and hit Resume.",
            style: .warning
        )
    }

    /// Install (or re-install) the audio render-thread tap on
    /// `inputNode` bus 0 with the given format. Captures the current
    /// `audioFile`, `bufferContinuation`, `analyzer` and `writeErrors`
    /// references so the closure body has zero MainActor hops per
    /// buffer except for the rate-limited level/spectrum UI updates.
    /// Safe to call multiple times — the tap is removed beforehand
    /// in `handleConfigurationChange`.
    private func installInputTap(format: AVAudioFormat) {
        let input = engine.inputNode
        let continuationRef = bufferContinuation
        let fileRef = audioFile
        let analyzerRef = analyzer
        let writeErrorsRef = writeErrors
        let framesWrittenRef = framesWritten
        let timestampRef = bufferTimestamp
        let livenessRef = micLiveness
        // Fresh grace window every time a new audio path starts (start,
        // resume, route-change recovery, engine rebuild) so the silence
        // monitor doesn't trip during the brief no-buffer transition.
        micLiveness.reset(to: Date())

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            // Render thread — keep work minimal. Buffer-write failures
            // are accumulated and surfaced once at stop() rather than
            // touching MainActor state per buffer.
            // Atomic timestamp mark — read by the MainActor recovery
            // watchdog to detect AUHAL-on-dead-device silent failure.
            timestampRef.mark(Date())
            if let fileRef {
                do {
                    try fileRef.write(from: buffer)
                    // Only counted on success. Divergence between
                    // this and elapsed*sampleRate is the truncation
                    // signal RecordingSession.stop() surfaces.
                    framesWrittenRef.add(UInt64(buffer.frameLength))
                } catch {
                    writeErrorsRef.record(error)
                }
            }
            continuationRef?.yield(AudioChunk(pcm: buffer, time: time))

            // Coalesce spectrum + level publishes to ~30 Hz (build 43).
            // Pre-build-43 we computed FFT + spawned a `Task @MainActor`
            // for EVERY render buffer — 50–100 Hz depending on
            // bufferSize/sampleRate. Each Task queued on MainActor as
            // a property mutation that the widget's TimelineView
            // (also @30 Hz) didn't actually need that often: spectrum
            // is a visual, not a measurement. 50 Hz of MainActor
            // churn was a meaningful chunk of the pause/resume hang
            // budget on long sessions. Now: we only ship a Task if
            // the wall clock has advanced ~33 ms since the last
            // ship, and skip the FFT itself when gated (FFT is
            // cheap but allocating + publishing the bands array
            // ISN'T — analyzer's scratch buffers + the MainActor
            // assign trigger Observable invalidation). The render-
            // thread tap closure is single-threaded so the
            // `nonisolated(unsafe)` timestamp is safe without a
            // lock.
            let nowRefTime = Date().timeIntervalSinceReferenceDate
            if nowRefTime - Self.lastSpectrumPublishRefTime > Self.spectrumPublishIntervalSec {
                Self.lastSpectrumPublishRefTime = nowRefTime
                let peak = Self.peakLevelDB(of: buffer)
                // Fold liveness sampling into the same gate. RMS (not
                // peak) so a denormal spike can't fake a live signal.
                livenessRef.record(
                    rms: Self.rmsLevelDB(of: buffer),
                    at: Date(),
                    floor: Self.micLivenessFloorDB
                )

                // Compute spectrum bands for the daisy widget. FFT of 2048
                // samples is ~0.5 ms on Apple Silicon — safe on render
                // thread. The UnsafeBufferPointer is borrowed for the
                // duration of bands(...) only — SpectrumAnalyzer copies
                // into its own pre-allocated scratch immediately. Pre-
                // 1.0.3 we did `Array(UnsafeBufferPointer(...))` here
                // which allocated ~16 KB heap per buffer at 100 Hz, with
                // a real priority-inversion risk against the engine's
                // internal mutexes during malloc slow paths.
                var bands: [Float]? = nil
                if let ch = buffer.floatChannelData?[0] {
                    let frames = Int(buffer.frameLength)
                    let sampleRate = buffer.format.sampleRate
                    let bufferPtr = UnsafeBufferPointer(start: ch, count: frames)
                    bands = analyzerRef.bands(from: bufferPtr, sampleRate: sampleRate)
                }

                Task { @MainActor [weak self] in
                    self?.levelDB = peak
                    if let b = bands {
                        self?.spectrumBands = b
                    }
                }
            }
        }
    }

    /// Wall-clock timestamp of the most recent spectrum/level publish
    /// to MainActor. Single-threaded (render-thread tap closure only)
    /// so `nonisolated(unsafe)` is safe. Static so it survives engine
    /// rebuilds and route-change reconfigurations without resetting
    /// the rate-limit window.
    nonisolated(unsafe) private static var lastSpectrumPublishRefTime: TimeInterval = 0
    /// 33 ms = ~30 Hz cap. The widget's TimelineView is also 30 Hz,
    /// so any faster ship is wasted UI work that just steals MainActor
    /// time from other consumers.
    private static let spectrumPublishIntervalSec: TimeInterval = 1.0 / 30.0

    /// Mic liveness floor in dBFS. A live mic — even in a quiet room —
    /// sits at a noise floor around −50…−70 dBFS; a dead/silent input
    /// (a BT-SCO mic delivering nothing, hardware mute, a device that
    /// keeps the AUHAL alive but sends digital zero) reads ≤ −120 dBFS
    /// or exact zero. The 40+ dB gap means −80 cleanly separates "alive
    /// but quiet" from "dead". Measured as RMS (not peak) so a single
    /// denormal/transient spike can't fake liveness.
    private static let micLivenessFloorDB: Float = -80
    /// How long mic RMS must stay below `micLivenessFloorDB`, with zero
    /// excursions above it, before we treat the input as dead and pause.
    /// Long enough not to trip on a natural pause in speech (the floor
    /// already clears room tone, so this is headroom against edge cases).
    private static let micSilenceWindowSec: TimeInterval = 10
    /// Cadence of the MainActor liveness check.
    private static let silenceMonitorIntervalSec: TimeInterval = 2

    /// Compare two AVAudioFormats on the dimensions that matter to
    /// AVAudioFile compatibility. NSObject equality on AVAudioFormat
    /// also checks bit-depth flags, which we don't care about — a
    /// 48 kHz Float32 stereo mic ↔ 48 kHz Int16 stereo USB-mic
    /// change shouldn't force a new part, but currently does. If
    /// that becomes a real issue, narrow the comparison further.
    nonisolated private static func formatsAreEqual(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        return a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
            && a.isInterleaved == b.isInterleaved
    }

    /// Build the .partN URL for a route-change-induced new file:
    /// `microphone.caf` → `microphone.part2.caf`. The first part
    /// keeps the base name unchanged so existing transcript/session
    /// wiring doesn't need to know about parts in the common case.
    nonisolated private static func makePartURL(base: URL, part: Int) -> URL {
        let ext = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        let dir = base.deletingLastPathComponent()
        return dir.appendingPathComponent("\(stem).part\(part).\(ext)")
    }

    /// Read back the AudioDeviceID currently bound to
    /// `engine.inputNode`'s AUHAL. Used by the route-change recovery
    /// path to cross-check `outputFormat(forBus:)` against CoreAudio's
    /// view of the device's stream format (see the de-sync guard in
    /// `handleConfigurationChange`). Returns nil if the audioUnit is
    /// missing or `AudioUnitGetProperty` fails — caller skips the
    /// guard and trusts AVAudioEngine on its word, which is the
    /// pre-build-34 behaviour.
    private func currentAUHALInputDeviceID() -> AudioDeviceID? {
        guard let audioUnit = engine.inputNode.audioUnit else {
            return nil
        }
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard status == noErr, deviceID != 0 else {
            return nil
        }
        return deviceID
    }

    /// Point `engine.inputNode`'s underlying HAL audio unit at a
    /// specific `AudioDeviceID`. Pass an empty UID to follow the macOS
    /// system default; pass a stable device UID to pin to that piece
    /// of hardware.
    ///
    /// Must be called BEFORE `engine.start()` and BEFORE we sample
    /// `inputNode.outputFormat`. Switching device after format
    /// capture would leave us writing the archive .caf at the wrong
    /// sample rate / channel count for the actual hardware.
    ///
    /// Pre-1.0.4 this short-circuited on `uid.isEmpty` ("trust the
    /// AUHAL to track the default"). That trust was misplaced: after
    /// `AVAudioEngineConfigurationChange` the AUHAL stays bound to
    /// the *previous* default device's ID, which macOS has already
    /// invalidated. The tap then fires zero buffers for the rest of
    /// the session — silent dead recording. Now we ALWAYS resolve to
    /// a concrete `AudioDeviceID` and call
    /// `kAudioOutputUnitProperty_CurrentDevice` explicitly, so route
    /// changes land us on the new default instead of a stale ghost.
    private func applyPreferredInputDevice(uid: String) {
        // Resolve to a concrete device ID. Three paths:
        //   1. User pinned a specific device → use that if connected.
        //   2. User pinned but device is gone → fall through to default.
        //   3. User picked "System default" → use the current default.
        var deviceID: AudioDeviceID
        if !uid.isEmpty, let pinned = AudioInputDevices.deviceID(forUID: uid) {
            deviceID = pinned
        } else {
            if !uid.isEmpty {
                log.warning("Saved mic UID \(uid, privacy: .public) not connected — falling back to system default")
            }
            deviceID = AudioInputDevices.systemDefaultInputID()
            // CoreAudio returns 0 if no default input is wired up at all
            // (rare — only on machines with literally zero input devices).
            // We have nothing to pin to; let the engine fail open and
            // surface `.noMicrophone` via the format check in start()/
            // handleConfigurationChange() instead. Pre-existing AUHAL
            // binding (if any) is preserved — better stale than nothing.
            guard deviceID != 0 else {
                log.error("No system default input device available — AUHAL left at its previous binding")
                return
            }
        }
        bindInputAUHAL(to: deviceID)
    }

    /// Explicitly bind `inputNode`'s AUHAL to a concrete `AudioDeviceID`
    /// via `kAudioOutputUnitProperty_CurrentDevice`. Factored out of
    /// `applyPreferredInputDevice` so route-change recovery can re-pin to
    /// "the device we were already recording on" without re-resolving
    /// through the system-default path (see `handleConfigurationChange`).
    /// `kAudioOutputUnitProperty_CurrentDevice` is the right property name
    /// even for AUHAL units configured as inputs — AVAudioEngine wraps an
    /// AUHAL on its inputNode for exactly this purpose.
    private func bindInputAUHAL(to deviceID: AudioDeviceID) {
        guard let audioUnit = engine.inputNode.audioUnit else {
            log.error("engine.inputNode.audioUnit is nil — can't route to device \(deviceID, privacy: .public)")
            return
        }
        var mutableID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            log.error("AudioUnitSetProperty(CurrentDevice) failed (status \(status, privacy: .public), deviceID \(deviceID, privacy: .public))")
        } else {
            // Remember, by stable UID, the device we actually bound to.
            // Keep the previous value if CoreAudio can't resolve a UID
            // for this ID — better a slightly stale anchor than none.
            lastBoundInputUID = AudioInputDevices.uid(for: deviceID) ?? lastBoundInputUID
            log.info("Bound mic AUHAL to device ID \(deviceID, privacy: .public)")
        }
    }

    func reset() {
        if state == .recording || state == .paused { stop() }
        state = .idle
        elapsed = 0
        accumulatedActiveSec = 0
        startedAt = nil
        levelDB = -160
        archivedFileURL = nil
        lastError = nil
    }

    // MARK: - Helpers

    private func tick() {
        guard let startedAt else { return }
        elapsed = accumulatedActiveSec + Date().timeIntervalSince(startedAt)
    }

    nonisolated private static func peakLevelDB(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return -160 }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        var peak: Float = 0
        for ch in 0..<count {
            let ptr = channels[ch]
            for i in 0..<frames {
                let v = abs(ptr[i])
                if v > peak { peak = v }
            }
        }
        guard peak > 0 else { return -160 }
        return 20 * log10(peak)
    }

    /// Root-mean-square level of the buffer in dBFS. Unlike peak, a lone
    /// denormal/transient spike can't mask an otherwise-silent stream —
    /// exactly the BT-SCO "buffers flowing but silent" failure the
    /// liveness watchdog must catch. Same single-pass cost as the peak
    /// scan; called at the same ~30 Hz gate.
    nonisolated private static func rmsLevelDB(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return -160 }
        let frames = Int(buffer.frameLength)
        let count = Int(buffer.format.channelCount)
        guard frames > 0, count > 0 else { return -160 }
        var sumSquares: Float = 0
        for ch in 0..<count {
            let ptr = channels[ch]
            for i in 0..<frames {
                let v = ptr[i]
                sumSquares += v * v
            }
        }
        let meanSquare = sumSquares / Float(frames * count)
        guard meanSquare > 0 else { return -160 }
        // 10·log10(power) == 20·log10(rms amplitude).
        return 10 * log10(meanSquare)
    }
}
