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

    @ObservationIgnored
    private let engine = AVAudioEngine()
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

    /// Stashed at `start()` time so the route-change recovery path can
    /// re-pin the engine to the same device after macOS yanks it out
    /// from under us (AirPods ↔ built-in, USB mic plug/unplug, etc.).
    /// Empty string == "follow system default".
    @ObservationIgnored
    private var activePreferredDeviceUID: String = ""

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

    /// DO NOT CALL AT APP LAUNCH. `engine.prepare()` requires the
    /// inputNode's audio unit to be initializable, which it ISN'T
    /// until macOS has granted microphone access AND the audio
    /// session is properly configured. Calling this before the
    /// first user-initiated `start()` throws an ObjC NSException
    /// out of `AVAudioEngineGraph::Initialize` that propagates
    /// past Swift's catch boundary and aborts the process. We
    /// hit this in 1.0.5 → 1.0.5.1 hotfix.
    ///
    /// Kept as a placeholder so future work that wants a real
    /// prewarm has a single hook to wire it through (e.g.
    /// "prewarm once AFTER the user requests microphone access
    /// and the engine has its first valid input format"). The
    /// current body is a no-op so accidental callers don't crash.
    func prewarm() {
        log.info("AudioRecorder.prewarm() called — no-op since 1.0.5.1 (see comment)")
    }

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

    /// Resume after `pause()`. Re-starts the engine without touching
    /// the tap or the file handle — the existing AVAudioFile keeps
    /// writing where it left off.
    func resume() throws {
        guard state == .paused else { return }
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
        // Mirror the route-change recovery watchdog — engine.start()
        // here can also return success while AUHAL is on a stale or
        // dead device (e.g., user picked a new mic in Settings during
        // the pause, then unplugged it before resuming). Without this,
        // resume-into-dead-device produces the same silent timer-only
        // recording that route-change recovery used to.
        armRecoveryWatchdog()
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

        // Re-pin to the user's preferred device. If the saved UID is
        // no longer connected (e.g. AirPods just disconnected) this
        // logs a warning and silently falls back to system default —
        // exactly what the user wants ("keep recording on whatever
        // mic is available now"). Must happen BEFORE we read the new
        // format, because device choice determines the format.
        applyPreferredInputDevice(uid: activePreferredDeviceUID)

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

        lastInputFormat = newFormat
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
    private func armRecoveryWatchdog(deadline: TimeInterval = 5.0) {
        cancelRecoveryWatchdog()
        let armedAt = Date()
        recoveryWatchdog = Timer.scheduledTimer(withTimeInterval: deadline, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkRecoveryProgress(armedAt: armedAt)
            }
        }
    }

    private func cancelRecoveryWatchdog() {
        recoveryWatchdog?.invalidate()
        recoveryWatchdog = nil
    }

    private func checkRecoveryProgress(armedAt: Date) {
        recoveryWatchdog = nil
        guard state == .recording else { return }
        let current = bufferTimestamp.snapshot()
        // Healthy: at least one buffer arrived strictly after arm time.
        if let c = current, c > armedAt { return }
        log.error("Recovery watchdog fired — no audio buffers post-arm. Falling to paused.")
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
        let timestampRef = bufferTimestamp

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
                } catch {
                    writeErrorsRef.record(error)
                }
            }
            continuationRef?.yield(AudioChunk(pcm: buffer, time: time))

            let peak = Self.peakLevelDB(of: buffer)

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
        guard let audioUnit = engine.inputNode.audioUnit else {
            log.error("engine.inputNode.audioUnit is nil — can't route to preferred device")
            return
        }
        // `kAudioOutputUnitProperty_CurrentDevice` is the right
        // property name even for AUHAL units configured as inputs;
        // AVAudioEngine wraps an AUHAL on its inputNode for exactly
        // this purpose.
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            log.error("AudioUnitSetProperty(CurrentDevice) failed (status \(status, privacy: .public), deviceID \(deviceID, privacy: .public))")
        } else {
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
}
