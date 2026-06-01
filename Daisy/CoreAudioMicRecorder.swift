//
//  CoreAudioMicRecorder.swift
//  Daisy
//
//  Direct CoreAudio AUHAL microphone capture — a drop-in replacement
//  for `AudioRecorder` (which uses AVAudioEngine). Everything runs
//  locally; no audio leaves the device.
//
//  WHY THIS EXISTS (the AVAudioEngine bug it sidesteps)
//  ----------------------------------------------------
//  On macOS 26.5, AVAudioEngine's `inputNode`/`outputNode` share ONE
//  internal AUHAL that gets stuck in sample-rate-conversion mode after
//  a route change: the input HARDWARE runs at e.g. 48000 Hz, but
//  `inputNode.outputFormat(forBus: 0)` stays pinned at a stale 44100 Hz,
//  and even a full `AVAudioEngine()` rebuild does NOT clear it (the
//  stale state is HAL/aggregate-device level, not the Swift object).
//  The tap then either delivers 0 frames or delivers 44100-rate audio
//  the transcriber can't use → empty transcript. See `AudioRecorder`'s
//  `handleConfigurationChange` / `rebuildEngineAndRetry` for the long
//  archaeology of fighting that bug from the AVAudioEngine layer.
//
//  CoreAudio reads the device's REAL rate correctly (48000 on the input
//  scope + nominal). So this class owns the device + the stream-format
//  negotiation DIRECTLY against CoreAudio's truth — we open a
//  `kAudioUnitSubType_HALOutput` AudioUnit, pin it to the resolved input
//  device, read the device's real input ASBD, set our float32 client
//  format at THAT rate, and pull frames via `AudioUnitRender` from an
//  input render callback. No shared engine, no hidden SRC, no stale
//  cached format to flush.
//
//  This ships behind `AppSettings.useCoreAudioMicCapture` (default
//  OFF) for on-device validation first — see the integration notes at
//  the bottom of this file and the `MicRecording` protocol that lets
//  `RecordingSession` swap implementations without touching call sites.
//
//  REFERENCES
//  ----------
//  • Apple TN2091 "Device input using the HAL Output Audio Unit" — the
//    canonical recipe (EnableIO on element 1, disable element 0, set
//    kAudioOutputUnitProperty_CurrentDevice, kAudioOutputUnitProperty_
//    SetInputCallback, AudioUnitRender in the callback).
//  • Apple CoreAudio "AudioUnitProperties.h" / "AUComponent.h" headers.
//  • The AUHAL element/scope convention: element 1 == INPUT (mic),
//    element 0 == OUTPUT (speaker). Input audio appears on the OUTPUT
//    scope of element 1 (the data "comes out of" the input element).
//

import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Observation
import os

// MARK: - Shared protocol

/// The public surface `RecordingSession` depends on for microphone
/// capture. Both `AudioRecorder` (AVAudioEngine) and
/// `CoreAudioMicRecorder` (direct AUHAL) conform, so the session can
/// pick an implementation at init time behind a setting flag without
/// any call-site changing. Every member here is exactly what
/// `RecordingSession` reads off `recorder.*` today (verified against
/// RecordingSession.swift: elapsed, levelDB, spectrumBands,
/// archivedParts, buffers, start, stop, pause, resume,
/// stopArchivingKeepTranscribing, archivedFrameCount,
/// archiveWriteErrorsSummary, archivedFileURL, reset).
///
/// MainActor-isolated to match both conformers (`@Observable @MainActor`).
@MainActor
protocol MicRecording: AnyObject {
    // Observable, UI-facing state.
    var levelDB: Float { get }
    var elapsed: TimeInterval { get }
    var spectrumBands: [Float] { get }
    var archivedFileURL: URL? { get }
    var archivedParts: [URL] { get }

    // Truthful disk-write accounting (post-stop audit in RecordingSession).
    var archivedFrameCount: UInt64 { get }
    var archiveWriteErrorsSummary: (count: Int, first: (any Error)?) { get }

    /// Subscribe to PCM buffers. MUST be read BEFORE `start()` so the
    /// continuation is installed before audio begins flowing.
    var buffers: AsyncStream<AudioChunk> { get }

    func start(archiveURL: URL?, preferredDeviceUID: String?) throws
    func pause()
    func resume() throws
    func stop()
    func reset()

    /// Stop writing the on-disk archive but keep yielding buffers to the
    /// transcriber (low-disk → transcript-only).
    func stopArchivingKeepTranscribing()
}

// AudioRecorder already matches this surface exactly — declare the
// conformance from here so we don't edit AudioRecorder.swift. (Its
// `start` has default args; the protocol requirement is still satisfied
// because a method with defaults fulfills a no-default requirement.)
extension AudioRecorder: MicRecording {}

// MARK: - CoreAudioMicRecorder

@Observable
@MainActor
final class CoreAudioMicRecorder: MicRecording {
    enum RecordingState: Equatable {
        case idle
        case recording
        /// Output unit stopped but the file handle, continuation and
        /// device binding are preserved. `resume()` re-reads the format,
        /// rolls a new part if it changed, and starts the unit again —
        /// writes continue appending (audio time jumps, wall clock
        /// doesn't, by design — mirrors AudioRecorder.pause/resume).
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
    /// Published from the render callback via `Task @MainActor`,
    /// rate-limited to ~30 Hz — identical contract to AudioRecorder.
    private(set) var spectrumBands: [Float] = Array(
        repeating: 0,
        count: SpectrumAnalyzer.bandCount
    )

    // MARK: - Audio unit + format

    /// The HAL output audio unit configured for INPUT capture. Created
    /// in `start()`, torn down in `stop()`. `nonisolated(unsafe)` is NOT
    /// used — we only touch this from the MainActor (lifecycle) and pass
    /// the opaque handle into the C render callback via the refcon box,
    /// never reading the property from the render thread.
    @ObservationIgnored
    private var audioUnit: AudioComponentInstance?

    /// Client (output-scope, element 1) format we set on the unit: the
    /// device's REAL input rate, float32, non-interleaved, same channel
    /// count the device reports. This is also the format of every
    /// `AVAudioPCMBuffer` we hand downstream and the format the archive
    /// `AVAudioFile` is opened with. Captured in `configureUnit`.
    @ObservationIgnored
    private var clientFormat: AVAudioFormat?

    /// AVAudioFormat object cached for buffer wrapping (same value as
    /// `clientFormat`; kept distinct only for readability at the call
    /// site in the render callback's refcon).
    @ObservationIgnored
    private var audioFile: AVAudioFile?

    @ObservationIgnored
    private var bufferContinuation: AsyncStream<AudioChunk>.Continuation?

    // MARK: - Timing

    @ObservationIgnored
    private var elapsedTimer: Timer?
    @ObservationIgnored
    private var startedAt: Date?
    /// Sum of completed active intervals before the current one — so a
    /// pause/resume cycle measures audio captured, not wall clock.
    /// Identical semantics to AudioRecorder.
    @ObservationIgnored
    private var accumulatedActiveSec: TimeInterval = 0

    // MARK: - Collaborators

    @ObservationIgnored
    private let analyzer = SpectrumAnalyzer()
    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "CoreAudioMicRecorder")

    // MARK: - Cross-thread boxes (same lock-box patterns as AudioRecorder)

    /// Thread-safe write-failure accumulator (render callback can't reach
    /// MainActor per buffer). Surfaced as a single summary at `stop()`.
    @ObservationIgnored
    private let writeErrors = WriteErrorBox()
    /// Frames that successfully landed on disk via `audioFile.write`.
    /// RecordingSession compares against `elapsed * sampleRate` to tell
    /// `.captured` from `.truncated`. Reset on each `start()`.
    @ObservationIgnored
    private let framesWritten = FrameCountBox()
    /// Render-thread → MainActor bridge for the last-buffer arrival time,
    /// read by the recovery watchdog to detect a silently-dead device.
    @ObservationIgnored
    private let bufferTimestamp = TimestampBox()
    /// Render-thread → MainActor liveness bridge (RMS above floor).
    @ObservationIgnored
    private let micLiveness = LivenessBox()
    /// Render-thread write gate (low-disk → transcript-only without
    /// tearing down capture). Default open; closed by
    /// `stopArchivingKeepTranscribing()`, reopened on each `start()`.
    @ObservationIgnored
    private let archiveGate = AtomicFlag(initial: true)

    // MARK: - Device / route state

    /// Stashed at `start()` so route-change recovery can re-pin to the
    /// same device choice. Empty string == "follow system default".
    @ObservationIgnored
    private var activePreferredDeviceUID: String = ""
    /// The device we're currently bound to (authoritative, set by US at
    /// bind time, not read back from the unit). nil until first bind.
    @ObservationIgnored
    private var boundDeviceID: AudioDeviceID?
    @ObservationIgnored
    private var lastBoundInputUID: String?

    /// CoreAudio default-input-device listener block + install flag.
    @ObservationIgnored
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored
    private var defaultInputListenerInstalled = false
    /// Stream-format listener on the *bound device's* input scope —
    /// catches an in-place sample-rate flip (e.g. the device renegotiates
    /// 44.1→48 kHz without the default-device selector changing). We need
    /// this because, unlike AVAudioEngine, nobody auto-reconfigures the
    /// AUHAL for us.
    @ObservationIgnored
    private var deviceFormatListenerBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored
    private var deviceFormatListenerDeviceID: AudioDeviceID?
    /// Wall-clock debounce — macOS often emits a route change 2–3 times
    /// in rapid succession as the graph settles. Mirrors AudioRecorder.
    @ObservationIgnored
    private var lastReconfigureAt: Date?

    // MARK: - Recovery watchdog

    @ObservationIgnored
    private var recoveryWatchdog: Timer?
    @ObservationIgnored
    private var recoveryGeneration: Int = 0
    @ObservationIgnored
    private var silenceMonitor: Timer?

    // MARK: - Archive parts

    /// Every .caf written this session. First entry == `archivedFileURL`.
    /// Extra entries appear only when a mid-session route change brought
    /// a new input format (mirrors AudioRecorder's part logic).
    @ObservationIgnored
    private(set) var archivedParts: [URL] = []
    @ObservationIgnored
    private var partCounter: Int = 0

    var archivedFrameCount: UInt64 { framesWritten.snapshot() }
    var archiveWriteErrorsSummary: (count: Int, first: (any Error)?) { writeErrors.snapshot() }

    // MARK: - API: buffers

    /// Subscribe to PCM buffers as they arrive. Read this **before**
    /// `start()` so the continuation is installed before the first
    /// `AudioUnitRender`. Same contract as `AudioRecorder.buffers`.
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

    // MARK: - API: start

    /// Begin capturing microphone audio via a HAL Output AudioUnit.
    /// Pass an `archiveURL` to also write a .caf. `preferredDeviceUID`
    /// is the stable device UID the user picked; empty/nil follows the
    /// macOS system default. Throws `DaisyError` on unrecoverable setup
    /// failure (no device, format read failed, unit won't initialize).
    func start(archiveURL: URL? = nil, preferredDeviceUID: String? = nil) throws {
        guard state != .recording else { return }
        lastError = nil

        activePreferredDeviceUID = preferredDeviceUID ?? ""

        // Resolve the device BEFORE creating the unit so we read the
        // right device's real format.
        let deviceID = resolveInputDeviceID(uid: activePreferredDeviceUID)
        guard deviceID != 0 else {
            throw DaisyError.noMicrophone
        }

        // Create + configure the unit (this also reads the real format
        // and stores `clientFormat`).
        let unit = try makeAndConfigureUnit(deviceID: deviceID)
        audioUnit = unit
        boundDeviceID = deviceID
        lastBoundInputUID = AudioInputDevices.uid(for: deviceID)

        guard let format = clientFormat, format.channelCount > 0 else {
            disposeUnit()
            throw DaisyError.noMicrophone
        }

        // Open the archive at the device's REAL format.
        if let archiveURL {
            do {
                audioFile = try AVAudioFile(forWriting: archiveURL, settings: format.settings)
                archivedFileURL = archiveURL
                archivedParts = [archiveURL]
                partCounter = 1
            } catch {
                disposeUnit()
                throw DaisyError.audioEngineFailed(error.localizedDescription)
            }
        } else {
            audioFile = nil
            archivedFileURL = nil
            archivedParts = []
            partCounter = 0
        }

        // Reset cross-thread accounting for a fresh session.
        writeErrors.reset()
        framesWritten.reset()
        bufferTimestamp.reset()
        micLiveness.reset(to: Date())
        archiveGate.set(true)

        // Wire the render context (sets the input callback) BEFORE
        // initialize — the callback reads this box, and the canonical
        // AUHAL ordering is callback-then-initialize.
        installRenderContext(format: format)

        // Initialize now that the callback is in place.
        do {
            try initializeUnit(unit)
        } catch {
            // initializeUnit disposed the unit; clear our handle + box.
            audioUnit = nil
            renderContext = nil
            audioFile = nil
            archivedFileURL = nil
            throw error
        }

        // Route-change listeners. These do the job AVAudioEngine's
        // ConfigurationChange notification + our CoreAudio listener did
        // in AudioRecorder, but here they're the ONLY recovery trigger
        // (no engine to tell us anything).
        installDefaultInputListener()
        installDeviceFormatListener(for: deviceID)

        // Start pulling audio.
        let startStatus = AudioOutputUnitStart(unit)
        guard startStatus == noErr else {
            removeDeviceFormatListener()
            removeDefaultInputListener()
            disposeUnit()
            audioFile = nil
            archivedFileURL = nil
            throw DaisyError.audioEngineFailed("AudioOutputUnitStart failed (status \(startStatus))")
        }

        startedAt = Date()
        elapsed = 0
        accumulatedActiveSec = 0
        state = .recording

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        startSilenceMonitor()
        // Same arrival watchdog AudioRecorder arms at initial start:
        // AudioOutputUnitStart can return success while the device
        // delivers 0 frames. On no-buffers-in-5s, reconfigure (re-resolve
        // device + re-read format) rather than burning the meeting on a
        // dead callback.
        armRecoveryWatchdog(escalateToReconfigure: true)

        log.info("CoreAudioMicRecorder started on device \(deviceID, privacy: .public) at \(format.sampleRate, privacy: .public) Hz / \(format.channelCount, privacy: .public) ch")
    }

    // MARK: - API: pause / resume

    /// Soft pause. Stops the output unit but keeps the file handle,
    /// continuation and device binding alive — `resume()` re-arms the
    /// unit and writes continue appending. Matches AudioRecorder.pause().
    func pause() {
        guard state == .recording, let unit = audioUnit else { return }
        cancelRecoveryWatchdog()
        stopSilenceMonitor()
        let status = AudioOutputUnitStop(unit)
        if status != noErr {
            log.error("AudioOutputUnitStop (pause) failed: status \(status, privacy: .public)")
        }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        if let startedAt {
            accumulatedActiveSec += Date().timeIntervalSince(startedAt)
        }
        startedAt = nil
        levelDB = -160
        spectrumBands = Array(repeating: 0, count: SpectrumAnalyzer.bandCount)
        state = .paused
        log.info("CoreAudioMicRecorder paused after \(self.elapsed, privacy: .public)s")
    }

    /// Resume after `pause()`. Re-resolves the device, re-reads its real
    /// format, rolls the archive into a new `.partN.caf` if the format
    /// changed (the device may have switched while we were paused — same
    /// scenario AudioRecorder.resume() guards against), reinstalls the
    /// render context, and restarts the unit.
    func resume() throws {
        guard state == .paused else { return }

        // Re-resolve the device — the user may have switched mics in
        // Settings, or unplugged a headset, while paused.
        let deviceID = resolveInputDeviceID(uid: activePreferredDeviceUID)
        guard deviceID != 0 else {
            log.error("Resume failed — no input device available.")
            throw DaisyError.audioEngineFailed("No audio input device available. Connect a mic and try again.")
        }

        // If the device changed, we must rebuild the unit (the AUHAL is
        // bound to the OLD AudioDeviceID and its client format was
        // negotiated for the old device). If it's the same device, a
        // re-configure of format on the existing unit is enough, but
        // rebuilding is simplest and always-correct — do that.
        do {
            try rebuildUnit(on: deviceID, reason: "resume")
        } catch {
            throw DaisyError.audioEngineFailed("Mic device couldn't reinitialize on resume: \(error.localizedDescription)")
        }

        startedAt = Date()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        state = .recording
        armRecoveryWatchdog()
        startSilenceMonitor()
        log.info("CoreAudioMicRecorder resumed")
    }

    // MARK: - API: stop

    func stop() {
        // Tolerate stop-from-paused (the explicit Stop & save path may
        // come straight from a paused session) — mirrors AudioRecorder.
        guard state == .recording || state == .paused else { return }
        removeDefaultInputListener()
        removeDeviceFormatListener()
        cancelRecoveryWatchdog()
        stopSilenceMonitor()

        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
        }
        disposeUnit()

        bufferContinuation?.finish()
        bufferContinuation = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        audioFile = nil  // closes the file (flushes header + frames)
        analyzer.reset()
        spectrumBands = Array(repeating: 0, count: SpectrumAnalyzer.bandCount)
        state = .stopped
        log.info("CoreAudioMicRecorder stopped after \(self.elapsed, privacy: .public)s")

        // Surface render-thread write failures (identical UX to
        // AudioRecorder.stop()).
        let (errCount, firstErr) = writeErrors.snapshot()
        if errCount > 0 {
            let firstMessage = firstErr?.localizedDescription ?? "unknown"
            log.error("\(errCount, privacy: .public) audio buffer write(s) failed. First: \(firstMessage, privacy: .public)")
            if errCount > 25 {
                ToastCenter.shared.show(
                    "Audio archive may be incomplete — \(errCount) write errors.",
                    style: .warning
                )
            }
        }

        if archivedParts.count > 1 {
            let names = archivedParts.map(\.lastPathComponent).joined(separator: ", ")
            log.warning("Recording split across \(self.archivedParts.count, privacy: .public) parts due to format change(s): \(names, privacy: .public)")
            ToastCenter.shared.show(
                "Recording saved as \(archivedParts.count) parts — mic format changed mid-session.",
                style: .info
            )
        }
    }

    /// Stop archiving to disk but keep the callback + transcription
    /// running (low-disk → transcript-only). Audio written so far is
    /// kept and finalized at `stop()`. Identical contract to
    /// AudioRecorder.stopArchivingKeepTranscribing().
    func stopArchivingKeepTranscribing() {
        archiveGate.set(false)
        log.warning("Mic archiving stopped (low disk) — transcription continues, no further audio written")
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

    // MARK: - Unit creation + configuration

    /// Create a `kAudioUnitSubType_HALOutput` AudioUnit, enable input
    /// (element 1), disable output (element 0), pin it to `deviceID`,
    /// read the device's REAL input ASBD, set our float32 client format
    /// on the output scope of element 1, install the input callback, and
    /// initialize. Stores `clientFormat`. Throws on any hard failure.
    ///
    /// NB element/scope convention for an AUHAL configured as input:
    ///   • element (bus) 1 = INPUT (the mic side)
    ///   • element (bus) 0 = OUTPUT (the speaker side — disabled here)
    ///   • the captured audio is read from the OUTPUT scope of element 1
    ///     (the data "flows out of" the input element toward us).
    private func makeAndConfigureUnit(deviceID: AudioDeviceID) throws -> AudioComponentInstance {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw DaisyError.audioEngineFailed("HAL output AudioComponent not found")
        }
        var unitOptional: AudioComponentInstance?
        var status = AudioComponentInstanceNew(comp, &unitOptional)
        guard status == noErr, let unit = unitOptional else {
            throw DaisyError.audioEngineFailed("AudioComponentInstanceNew failed (status \(status))")
        }

        // From here on, dispose the unit if anything throws.
        func fail(_ message: String) -> DaisyError {
            AudioComponentInstanceDispose(unit)
            return DaisyError.audioEngineFailed(message)
        }

        // 1. Enable INPUT on element 1.
        var enableInput: UInt32 = 1
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input,
            Self.inputElement,
            &enableInput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else { throw fail("EnableIO(input, element 1) failed (status \(status))") }

        // 2. Disable OUTPUT on element 0 — we only capture.
        var disableOutput: UInt32 = 0
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output,
            Self.outputElement,
            &disableOutput,
            UInt32(MemoryLayout<UInt32>.size)
        )
        guard status == noErr else { throw fail("EnableIO(output, element 0) disable failed (status \(status))") }

        // 3. Pin the unit to the resolved device. This MUST happen after
        //    EnableIO and before reading the input format — the format
        //    we read back is the format of THIS device.
        var mutableDeviceID = deviceID
        status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw fail("Set CurrentDevice failed (status \(status), device \(deviceID))") }

        // 4. Read the device's REAL input stream format from the unit's
        //    INPUT scope of element 1 — this is the hardware format the
        //    AUHAL will actually deliver. (We could read it off the
        //    device via AudioInputDevices.streamFormatSampleRate, but the
        //    unit's own input-scope ASBD is the authoritative thing the
        //    render side will hand us — channel count included.)
        var hwFormat = AudioStreamBasicDescription()
        var hwSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            Self.inputElement,
            &hwFormat,
            &hwSize
        )
        guard status == noErr, hwFormat.mSampleRate > 0 else {
            throw fail("Read input StreamFormat failed (status \(status), rate \(hwFormat.mSampleRate))")
        }

        // Cross-check against CoreAudio's direct device read. On the
        // hardware this class exists for, these AGREE (that's the whole
        // point — CoreAudio reports the truth). If they disagree, trust
        // the device's input-scope rate (CoreAudio's truth) and log it;
        // we don't crash. We rebuild our client ASBD from the real rate
        // regardless.
        let realRate: Double
        if let deviceRate = AudioInputDevices.streamFormatSampleRate(for: deviceID),
           abs(deviceRate - hwFormat.mSampleRate) > 0.5 {
            log.warning("Unit input rate \(hwFormat.mSampleRate, privacy: .public) Hz disagrees with device input-scope \(deviceRate, privacy: .public) Hz. Using device rate.")
            log.warning("Rate diag: \(AudioInputDevices.streamRateDiagnostics(for: deviceID), privacy: .public)")
            realRate = deviceRate
        } else {
            realRate = hwFormat.mSampleRate
        }

        // Preserve the device's channel count (built-in mic is mono;
        // some interfaces are stereo). Clamp to at least 1.
        let channels = max(1, hwFormat.mChannelsPerFrame)

        // 5. Build our CLIENT format: float32, non-interleaved (planar),
        //    at the real rate, matching channel count. Non-interleaved
        //    Float32 is exactly what AVAudioPCMBuffer/SpectrumAnalyzer/
        //    AudioConverter expect (floatChannelData[ch]).
        guard let client = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: realRate,
            channels: channels,
            interleaved: false
        ) else {
            throw fail("Couldn't build client AVAudioFormat (rate \(realRate), ch \(channels))")
        }
        clientFormat = client

        // Apply the client ASBD to the OUTPUT scope of element 1 — the
        // scope we read captured audio from. The AUHAL converts the
        // device's native format to this for us internally (this is the
        // ONE conversion we explicitly own and control, vs AVAudioEngine's
        // hidden shared-AUHAL SRC that gets stuck).
        var clientASBD = client.streamDescription.pointee
        status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            Self.inputElement,
            &clientASBD,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard status == noErr else { throw fail("Set client StreamFormat (output scope, element 1) failed (status \(status))") }

        // NB the input render callback and `AudioUnitInitialize` are NOT
        // done here. The canonical AUHAL recipe (Apple TN2091,
        // TheAmazingAudioEngine, keijiro/AudioJackPlugin) sets
        // `kAudioOutputUnitProperty_SetInputCallback` BEFORE
        // `AudioUnitInitialize`, and our callback needs the per-(re)start
        // `RenderContext` box (which captures the AVAudioFile +
        // continuation). So the caller does, in order:
        //   makeAndConfigureUnit → installRenderContext (sets callback)
        //   → initializeUnit → AudioOutputUnitStart.
        // The unit returned here is configured + format-locked but NOT
        // yet initialized.
        return unit
    }

    /// `AudioUnitInitialize` the configured unit. Split out of
    /// `makeAndConfigureUnit` so it runs AFTER the input callback is
    /// installed (canonical ordering — see the note in
    /// `makeAndConfigureUnit`). Disposes the unit on failure and throws.
    private func initializeUnit(_ unit: AudioComponentInstance) throws {
        let status = AudioUnitInitialize(unit)
        guard status == noErr else {
            AudioComponentInstanceDispose(unit)
            throw DaisyError.audioEngineFailed("AudioUnitInitialize failed (status \(status))")
        }
    }

    // MARK: - Render context (refcon box) + callback wiring

    /// Strongly-held render context. The C callback receives an
    /// unretained pointer to this; it is created here and released only
    /// after the unit is disposed (in `disposeUnit`), so the pointer the
    /// callback holds is always valid while the callback can fire.
    @ObservationIgnored
    private var renderContext: RenderContext?

    /// Build the `RenderContext` the render callback reads, point the
    /// AUHAL's input callback at it, and stash the AudioUnit handle
    /// inside it (the callback needs the unit to call AudioUnitRender).
    private func installRenderContext(format: AVAudioFormat) {
        guard let unit = audioUnit else { return }

        // Fresh grace window so the silence monitor doesn't trip during
        // the brief no-buffer transition after (re)install — same as
        // AudioRecorder.installInputTap.
        micLiveness.reset(to: Date())

        let ctx = RenderContext(
            owner: self,
            audioUnit: unit,
            format: format,
            continuation: bufferContinuation,
            audioFile: audioFile,
            analyzer: analyzer,
            writeErrors: writeErrors,
            framesWritten: framesWritten,
            bufferTimestamp: bufferTimestamp,
            micLiveness: micLiveness,
            archiveGate: archiveGate
        )
        renderContext = ctx

        // Unretained pointer — RenderContext outlives the unit by
        // construction (disposeUnit removes the callback before nil-ing
        // the box).
        let refcon = Unmanaged.passUnretained(ctx).toOpaque()
        var callbackStruct = AURenderCallbackStruct(
            inputProc: coreAudioMicInputCallback,
            inputProcRefCon: refcon
        )
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        if status != noErr {
            log.error("SetInputCallback failed (status \(status, privacy: .public))")
        }
    }

    /// Stop + uninitialize + dispose the unit and clear the render
    /// context. Order matters: tear down the callback path FIRST (stop +
    /// uninitialize) so no callback can be in-flight, THEN release the
    /// refcon box.
    private func disposeUnit() {
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        audioUnit = nil
        // Safe to release the box now — the unit (and its callback) is
        // gone, so no render thread holds the pointer any more.
        renderContext = nil
    }

    // MARK: - Device resolution + binding

    /// Resolve `uid` to a concrete `AudioDeviceID`. Three paths, same as
    /// AudioRecorder.applyPreferredInputDevice:
    ///   1. User pinned a device that's connected → use it.
    ///   2. User pinned but it's gone → fall back to system default.
    ///   3. User picked "System default" → current default.
    /// Returns 0 if no input device exists at all (caller throws
    /// `.noMicrophone`).
    private func resolveInputDeviceID(uid: String) -> AudioDeviceID {
        if !uid.isEmpty, let pinned = AudioInputDevices.deviceID(forUID: uid) {
            return pinned
        }
        if !uid.isEmpty {
            log.warning("Saved mic UID \(uid, privacy: .public) not connected — falling back to system default")
        }
        return AudioInputDevices.systemDefaultInputID()
    }

    // MARK: - Route-change recovery

    /// Tear down the current unit and build a fresh one bound to
    /// `deviceID`, re-reading its real format and rolling the archive
    /// into a new `.partN.caf` if the format differs from what we were
    /// writing. The CoreAudio analogue of AudioRecorder's
    /// `rebuildEngineAndRetry` + the format-roll logic — but far simpler
    /// because there's no hidden cached format to fight: we re-read the
    /// truth from CoreAudio every time. Used by `resume()` and by the
    /// route-change path. Throws on hard failure (caller decides whether
    /// to fall to paused).
    private func rebuildUnit(on deviceID: AudioDeviceID, reason: String) throws {
        // Capture the format we were writing at, to detect a change.
        let oldFormat = clientFormat

        // Remove the device-format listener for the OLD device; we'll
        // reinstall for the new one after configuring.
        removeDeviceFormatListener()

        // Dispose the old unit (stops the callback, releases the refcon).
        disposeUnit()

        // Build + configure the new unit (reads the new real format into
        // `clientFormat`).
        let unit = try makeAndConfigureUnit(deviceID: deviceID)
        audioUnit = unit
        boundDeviceID = deviceID
        lastBoundInputUID = AudioInputDevices.uid(for: deviceID) ?? lastBoundInputUID

        guard let newFormat = clientFormat, newFormat.channelCount > 0 else {
            disposeUnit()
            throw DaisyError.noMicrophone
        }

        // Roll the archive if the format changed — AVAudioFile can't
        // accept frames in a format different from the one it was opened
        // with, so the alternative is silent data loss (the exact bug
        // AudioRecorder's part logic exists to prevent).
        let formatChanged = !(oldFormat.map { Self.formatsAreEqual($0, newFormat) } ?? false)
        if formatChanged, let baseURL = archivedFileURL {
            audioFile = nil
            partCounter += 1
            let newPartURL = Self.makePartURL(base: baseURL, part: partCounter)
            do {
                audioFile = try AVAudioFile(forWriting: newPartURL, settings: newFormat.settings)
                archivedParts.append(newPartURL)
                let oldRate = oldFormat?.sampleRate ?? 0
                log.warning("[\(reason, privacy: .public)] format changed (\(oldRate, privacy: .public) Hz → \(newFormat.sampleRate, privacy: .public) Hz). Archive rolled to \(newPartURL.lastPathComponent, privacy: .public).")
            } catch {
                log.error("[\(reason, privacy: .public)] failed to open part \(self.partCounter, privacy: .public): \(error.localizedDescription, privacy: .public). Continuing without archive for this part.")
                audioFile = nil
            }
        }

        // Wire the render context (sets callback) against the new unit +
        // (possibly new) file, initialize, reinstall the device-format
        // listener, and start.
        installRenderContext(format: newFormat)
        do {
            try initializeUnit(unit)
        } catch {
            audioUnit = nil
            renderContext = nil
            throw error
        }
        installDeviceFormatListener(for: deviceID)

        let startStatus = AudioOutputUnitStart(unit)
        guard startStatus == noErr else {
            throw DaisyError.audioEngineFailed("AudioOutputUnitStart failed on \(reason) (status \(startStatus))")
        }
    }

    /// Deterministic route-change handler. macOS changed the default
    /// input device, or the bound device renegotiated its format. Re-
    /// resolve the device, rebuild the unit against the truth, roll a
    /// part if needed. Debounced (macOS fires these 2–3×). Not invoked
    /// while paused/stopped.
    private func handleRouteChange(trigger: String) {
        guard state == .recording else {
            log.info("Route change ignored (state=\(String(describing: self.state), privacy: .public), trigger=\(trigger, privacy: .public))")
            return
        }
        if let last = lastReconfigureAt, Date().timeIntervalSince(last) < 2.0 {
            log.info("Route change debounced — last reconfigure \(Date().timeIntervalSince(last), privacy: .public)s ago (trigger=\(trigger, privacy: .public))")
            return
        }
        lastReconfigureAt = Date()
        log.warning("Mic route change (\(trigger, privacy: .public)) — reconfiguring deterministically")

        // Decide which device to bind. Same Bluetooth-hijack guard as
        // AudioRecorder: an UNPINNED session whose new default input is
        // Bluetooth keeps the device we were on (AirPods-for-output drags
        // the default input onto their SCO mic, which often delivers
        // silence). A pinned mic always follows its UID; a wired/USB
        // change is intended, so follow it.
        let newDefaultID = AudioInputDevices.systemDefaultInputID()
        let newDefaultIsBluetooth = newDefaultID != 0 && AudioInputDevices.isBluetooth(newDefaultID)

        let targetID: AudioDeviceID
        if activePreferredDeviceUID.isEmpty,
           newDefaultIsBluetooth,
           let keepUID = lastBoundInputUID,
           let keepID = AudioInputDevices.deviceID(forUID: keepUID) {
            log.info("Route change, no pinned mic — new default is Bluetooth; keeping current device (UID \(keepUID, privacy: .public), id \(keepID, privacy: .public)) to avoid a BT-output hijack.")
            targetID = keepID
        } else {
            targetID = resolveInputDeviceID(uid: activePreferredDeviceUID)
        }

        guard targetID != 0 else {
            log.error("Route change — no usable input device. Falling to paused.")
            fallToPaused()
            ToastCenter.shared.show(
                "Mic disconnected — recording paused. Connect a mic and hit Resume.",
                style: .warning
            )
            return
        }

        do {
            try rebuildUnit(on: targetID, reason: "route-change")
            log.info("Route-change recovery succeeded — recording continues on device \(targetID, privacy: .public)")
            let body = archivedParts.count > 1
                ? "Mic device changed — recording continues in a new file (\(archivedParts.count) parts so far)."
                : "Mic device changed — recording continues."
            ToastCenter.shared.show(body, style: .info)
            // Unit can report started while the device delivers nothing.
            // Watchdog falls us to paused if no buffer arrives within 5s.
            armRecoveryWatchdog()
        } catch {
            log.error("Route-change rebuild failed: \(error.localizedDescription, privacy: .public). Falling to paused.")
            fallToPaused()
            ToastCenter.shared.show(
                "Mic changed — recording paused. Hit Resume to continue.",
                style: .warning
            )
        }
    }

    /// Centralised "drop to paused" — preserves `accumulatedActiveSec`,
    /// clears the level/spectrum, stops the unit. Mirrors
    /// AudioRecorder.fallToPaused().
    private func fallToPaused() {
        cancelRecoveryWatchdog()
        stopSilenceMonitor()
        lastReconfigureAt = nil  // let a follow-up recover immediately
        if let unit = audioUnit {
            AudioOutputUnitStop(unit)
        }
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

    // MARK: - CoreAudio listeners

    /// `kAudioHardwarePropertyDefaultInputDevice` listener — catches the
    /// system default flipping (AirPods connect, USB plug/unplug, user
    /// re-routes input in Control Centre).
    private func installDefaultInputListener() {
        guard !defaultInputListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleRouteChange(trigger: "default-input")
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated),
            block
        )
        if status == noErr {
            defaultInputListenerBlock = block
            defaultInputListenerInstalled = true
            log.info("Default input device listener installed")
        } else {
            log.error("Failed to install default input listener: status=\(status, privacy: .public)")
        }
    }

    private func removeDefaultInputListener() {
        guard defaultInputListenerInstalled, let block = defaultInputListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated),
            block
        )
        defaultInputListenerBlock = nil
        defaultInputListenerInstalled = false
    }

    /// Listener on the BOUND device's input-scope stream format. Catches
    /// an in-place sample-rate flip on the device we're recording (the
    /// device renegotiates 44.1↔48 kHz without the default selector
    /// changing). AVAudioEngine handled this case via its own
    /// ConfigurationChange; here it's on us.
    private func installDeviceFormatListener(for deviceID: AudioDeviceID) {
        removeDeviceFormatListener()
        guard deviceID != 0 else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleRouteChange(trigger: "device-format")
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            DispatchQueue.global(qos: .userInitiated),
            block
        )
        if status == noErr {
            deviceFormatListenerBlock = block
            deviceFormatListenerDeviceID = deviceID
            log.info("Device-format listener installed for device \(deviceID, privacy: .public)")
        } else {
            log.error("Failed to install device-format listener for \(deviceID, privacy: .public): status=\(status, privacy: .public)")
        }
    }

    private func removeDeviceFormatListener() {
        guard let block = deviceFormatListenerBlock, let deviceID = deviceFormatListenerDeviceID else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.global(qos: .userInitiated), block)
        deviceFormatListenerBlock = nil
        deviceFormatListenerDeviceID = nil
    }

    // MARK: - Recovery watchdog (arrival)

    /// Arm a one-shot timer that checks `bufferTimestamp` after start /
    /// recovery. No buffer strictly after the arm time ⇒ the device is
    /// delivering nothing. At INITIAL start (`escalateToReconfigure`) we
    /// re-resolve + rebuild once before giving up; otherwise we fall to
    /// paused. Generation guard makes a stale fired timer a no-op under
    /// route flapping. Mirrors AudioRecorder.armRecoveryWatchdog.
    private func armRecoveryWatchdog(deadline: TimeInterval = 5.0, escalateToReconfigure: Bool = false) {
        cancelRecoveryWatchdog()
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        let armedAt = Date()
        recoveryWatchdog = Timer.scheduledTimer(withTimeInterval: deadline, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkRecoveryProgress(armedAt: armedAt, generation: generation, escalateToReconfigure: escalateToReconfigure)
            }
        }
    }

    private func cancelRecoveryWatchdog() {
        recoveryWatchdog?.invalidate()
        recoveryWatchdog = nil
        recoveryGeneration &+= 1
    }

    private func checkRecoveryProgress(armedAt: Date, generation: Int, escalateToReconfigure: Bool) {
        guard generation == recoveryGeneration else {
            log.info("Stale recovery watchdog (gen \(generation, privacy: .public) ≠ \(self.recoveryGeneration, privacy: .public)) — ignoring.")
            return
        }
        recoveryWatchdog = nil
        guard state == .recording else { return }
        if let c = bufferTimestamp.snapshot(), c > armedAt { return }  // healthy

        if escalateToReconfigure {
            log.error("Recovery watchdog fired at start — no buffers post-arm. Rebuilding before pausing.")
            let deviceID = resolveInputDeviceID(uid: activePreferredDeviceUID)
            if deviceID != 0 {
                do {
                    try rebuildUnit(on: deviceID, reason: "watchdog-start")
                    armRecoveryWatchdog()  // non-escalating; a 2nd failure falls to paused
                    return
                } catch {
                    log.error("Start-time rebuild failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        } else {
            log.error("Recovery watchdog fired — no audio buffers post-arm. Falling to paused.")
        }
        fallToPaused()
        ToastCenter.shared.show(
            "Mic stopped delivering audio — recording paused. Hit Resume to retry.",
            style: .warning
        )
    }

    // MARK: - Mic silence watchdog (signal level, not arrival)

    private func startSilenceMonitor() {
        stopSilenceMonitor()
        micLiveness.reset(to: Date())
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

    /// Signal-level dead-input check. If mic RMS has stayed below the
    /// liveness floor for `micSilenceWindowSec` (zero excursions above),
    /// the input is delivering silence — BT-SCO, hardware mute, dead
    /// device — so pause and tell the user. Identical to AudioRecorder.
    private func checkMicSilence() {
        guard state == .recording else { return }
        let snap = micLiveness.snapshot()
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

    // MARK: - Helpers

    private func tick() {
        guard let startedAt else { return }
        elapsed = accumulatedActiveSec + Date().timeIntervalSince(startedAt)
    }

    /// Receive a rate-limited (≤30 Hz) level + spectrum sample computed
    /// on the render thread and publish it to the Observable surface.
    /// Called via `Task { @MainActor [weak owner] }` from `RenderContext.
    /// process` — the same hop AudioRecorder's tap closure does inline.
    /// Ignored once we're no longer recording so a late in-flight Task
    /// doesn't repaint a stopped/paused widget.
    fileprivate func publishLevel(_ level: Float, bands: [Float]?) {
        guard state == .recording else { return }
        levelDB = level
        if let bands { spectrumBands = bands }
    }

    /// AUHAL input element == 1, output element == 0 (Apple convention).
    private static let inputElement: AudioUnitElement = 1
    private static let outputElement: AudioUnitElement = 0

    /// 33 ms = ~30 Hz cap on spectrum/level publishes — matches the
    /// widget's TimelineView. Static so it survives unit rebuilds.
    /// `nonisolated(unsafe)` because it's read/written only on the single
    /// render thread inside the C callback path (see RenderContext.process).
    nonisolated(unsafe) fileprivate static var lastSpectrumPublishRefTime: TimeInterval = 0
    fileprivate static let spectrumPublishIntervalSec: TimeInterval = 1.0 / 30.0

    /// Liveness floor / window — copied verbatim from AudioRecorder so
    /// both recorders trip the silence watchdog at the same thresholds.
    fileprivate static let micLivenessFloorDB: Float = -80
    private static let micSilenceWindowSec: TimeInterval = 10
    private static let silenceMonitorIntervalSec: TimeInterval = 2

    nonisolated private static func formatsAreEqual(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
            && a.isInterleaved == b.isInterleaved
    }

    /// `microphone.caf` → `microphone.part2.caf`. Identical to
    /// AudioRecorder.makePartURL so downstream part-aware wiring is
    /// format-compatible across the two recorders.
    nonisolated private static func makePartURL(base: URL, part: Int) -> URL {
        let ext = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        let dir = base.deletingLastPathComponent()
        return dir.appendingPathComponent("\(stem).part\(part).\(ext)")
    }
}

// MARK: - Render context (the box the C callback reads)

/// Everything the render callback needs, captured once at install time
/// so the hot path never touches MainActor-isolated `self`. Held by
/// `CoreAudioMicRecorder.renderContext`; an unretained pointer to it is
/// the AUHAL input-callback refcon.
///
/// `@unchecked Sendable`: the callback runs on a single CoreAudio render
/// thread, and the only mutable shared state lives behind the lock-boxes
/// (WriteErrorBox / FrameCountBox / TimestampBox / LivenessBox /
/// AtomicFlag). The `AVAudioFile` and `AsyncStream.Continuation` are the
/// same objects AudioRecorder ferries across the same boundary — written
/// only from the single render thread, never concurrently.
private final class RenderContext: @unchecked Sendable {
    /// Weak back-reference to the owning recorder, used ONLY to hop
    /// level/spectrum to its `@MainActor publishLevel(_:bands:)` — exactly
    /// the `Task { @MainActor [weak self] }` pattern AudioRecorder's tap
    /// closure uses inline. Weak so the render thread never extends the
    /// recorder's lifetime; the hop is a no-op if it's gone.
    weak var owner: CoreAudioMicRecorder?

    let audioUnit: AudioComponentInstance
    let format: AVAudioFormat
    let continuation: AsyncStream<AudioChunk>.Continuation?
    let audioFile: AVAudioFile?
    let analyzer: SpectrumAnalyzer
    let writeErrors: WriteErrorBox
    let framesWritten: FrameCountBox
    let bufferTimestamp: TimestampBox
    let micLiveness: LivenessBox
    let archiveGate: AtomicFlag

    init(
        owner: CoreAudioMicRecorder,
        audioUnit: AudioComponentInstance,
        format: AVAudioFormat,
        continuation: AsyncStream<AudioChunk>.Continuation?,
        audioFile: AVAudioFile?,
        analyzer: SpectrumAnalyzer,
        writeErrors: WriteErrorBox,
        framesWritten: FrameCountBox,
        bufferTimestamp: TimestampBox,
        micLiveness: LivenessBox,
        archiveGate: AtomicFlag
    ) {
        self.owner = owner
        self.audioUnit = audioUnit
        self.format = format
        self.continuation = continuation
        self.audioFile = audioFile
        self.analyzer = analyzer
        self.writeErrors = writeErrors
        self.framesWritten = framesWritten
        self.bufferTimestamp = bufferTimestamp
        self.micLiveness = micLiveness
        self.archiveGate = archiveGate
    }

    /// Pull `inNumberFrames` of input audio via `AudioUnitRender`, wrap
    /// into an `AVAudioPCMBuffer`, then: yield an `AudioChunk`, write to
    /// the archive, and feed the spectrum/level (rate-limited). Runs on
    /// the CoreAudio render thread — keep allocation/locking minimal.
    func process(
        ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        inTimeStamp: UnsafePointer<AudioTimeStamp>,
        inBusNumber: UInt32,
        inNumberFrames: UInt32
    ) -> OSStatus {
        // Allocate a host buffer for this slice. AVAudioPCMBuffer's
        // backing storage is allocated here; this is the one unavoidable
        // per-callback allocation (AVAudioEngine's tap allocates one too,
        // internally). Float32 non-interleaved matches `format`.
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: inNumberFrames) else {
            return kAudio_ParamError
        }
        pcm.frameLength = inNumberFrames

        // Render directly into the PCM buffer's mutable AudioBufferList.
        // `mutableAudioBufferList` exposes the buffer's own channel
        // pointers; AudioUnitRender fills them in place — no extra copy.
        let abl = pcm.mutableAudioBufferList
        let renderStatus = AudioUnitRender(
            audioUnit,
            ioActionFlags,
            inTimeStamp,
            inBusNumber,
            inNumberFrames,
            abl
        )
        guard renderStatus == noErr else {
            // Don't yield a partial/garbage buffer; just report. A flood
            // of these would show up as silence → the silence watchdog
            // pauses the session.
            return renderStatus
        }

        // Atomic arrival mark — read by the MainActor recovery watchdog.
        bufferTimestamp.mark(Date())

        // Archive write (gated). Same try/accumulate pattern as
        // AudioRecorder's tap: only count frames that actually landed.
        if archiveGate.value, let file = audioFile {
            do {
                try file.write(from: pcm)
                framesWritten.add(UInt64(pcm.frameLength))
            } catch {
                writeErrors.record(error)
            }
        }

        // Hand the buffer to the transcriber. `AVAudioTime(audioTimeStamp:
        // sampleRate:)` takes a pointer to the timestamp; `inTimeStamp` is
        // already an `UnsafePointer<AudioTimeStamp>`, so pass it straight
        // through (no local copy / inout dance needed).
        let avTime = AVAudioTime(audioTimeStamp: inTimeStamp, sampleRate: format.sampleRate)
        continuation?.yield(AudioChunk(pcm: pcm, time: avTime))

        // Rate-limited spectrum + level (≤30 Hz), identical gate to
        // AudioRecorder.installInputTap.
        let nowRefTime = Date().timeIntervalSinceReferenceDate
        if nowRefTime - CoreAudioMicRecorder.lastSpectrumPublishRefTime > CoreAudioMicRecorder.spectrumPublishIntervalSec {
            CoreAudioMicRecorder.lastSpectrumPublishRefTime = nowRefTime
            let peak = Self.peakLevelDB(of: pcm)
            micLiveness.record(
                rms: Self.rmsLevelDB(of: pcm),
                at: Date(),
                floor: CoreAudioMicRecorder.micLivenessFloorDB
            )
            var bands: [Float]? = nil
            if let ch = pcm.floatChannelData?[0] {
                let frames = Int(pcm.frameLength)
                let sampleRate = pcm.format.sampleRate
                let bufferPtr = UnsafeBufferPointer(start: ch, count: frames)
                bands = analyzer.bands(from: bufferPtr, sampleRate: sampleRate)
            }
            // Hop to MainActor for the Observable publish — same shape as
            // AudioRecorder's `Task { @MainActor [weak self] in self?.levelDB
            // = peak; ... }`. `[weak owner]` so a buffer racing teardown
            // can't pin a stopped recorder; `publishLevel` itself guards on
            // `state == .recording`.
            let levelToPublish = peak
            let bandsToPublish = bands
            Task { @MainActor [weak owner] in
                owner?.publishLevel(levelToPublish, bands: bandsToPublish)
            }
        }

        return noErr
    }

    // Level helpers — copied from AudioRecorder (nonisolated statics).
    nonisolated static func peakLevelDB(of buffer: AVAudioPCMBuffer) -> Float {
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

    nonisolated static func rmsLevelDB(of buffer: AVAudioPCMBuffer) -> Float {
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
        return 10 * log10(meanSquare)
    }
}

// MARK: - C render callback (free function)

/// The AUHAL input render callback. Recovers the `RenderContext` from the
/// refcon and delegates to `process`. Must be a free C function (no
/// captured context) — that's why the box pointer travels in the refcon.
private func coreAudioMicInputCallback(
    inRefCon: UnsafeMutableRawPointer,
    ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    inTimeStamp: UnsafePointer<AudioTimeStamp>,
    inBusNumber: UInt32,
    inNumberFrames: UInt32,
    ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    // Unretained — the box is alive for as long as the unit (and thus
    // this callback) can fire; CoreAudioMicRecorder.disposeUnit() removes
    // the callback before releasing the box.
    let ctx = Unmanaged<RenderContext>.fromOpaque(inRefCon).takeUnretainedValue()
    return ctx.process(
        ioActionFlags: ioActionFlags,
        inTimeStamp: inTimeStamp,
        inBusNumber: inBusNumber,
        inNumberFrames: inNumberFrames
    )
}

// MARK: - Cross-thread lock-boxes
//
// Local copies of the same primitives AudioRecorder defines privately,
// renamed to avoid colliding with its `private` types in the same module.
// Identical behaviour; `OSAllocatedUnfairLock` is the same lock primitive
// AudioRecorder uses for its render-thread → MainActor bridges.

/// Accumulates archive-write failures off the render thread; one summary
/// surfaced at stop().
final class WriteErrorBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<(count: Int, first: (any Error)?)>(initialState: (0, nil))
    func record(_ error: any Error) {
        lock.withLock { state in
            state.count += 1
            if state.first == nil { state.first = error }
        }
    }
    func snapshot() -> (count: Int, first: (any Error)?) { lock.withLock { $0 } }
    func reset() { lock.withLock { $0 = (0, nil) } }
}

/// Frames that successfully landed on disk.
final class FrameCountBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<UInt64>(initialState: 0)
    func add(_ frames: UInt64) { lock.withLock { $0 &+= frames } }
    func snapshot() -> UInt64 { lock.withLock { $0 } }
    func reset() { lock.withLock { $0 = 0 } }
}

/// Last-buffer arrival timestamp bridge (render → MainActor watchdog).
final class TimestampBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Date?>(initialState: nil)
    func mark(_ at: Date) { lock.withLock { $0 = at } }
    func snapshot() -> Date? { lock.withLock { $0 } }
    func reset() { lock.withLock { $0 = nil } }
}

/// Mic signal liveness bridge (render → MainActor silence monitor).
final class LivenessBox: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<(aboveFloorAt: Date?, lastRMS: Float)>(initialState: (nil, -160))
    func record(rms: Float, at: Date, floor: Float) {
        lock.withLock { state in
            state.lastRMS = rms
            if rms > floor { state.aboveFloorAt = at }
        }
    }
    func snapshot() -> (aboveFloorAt: Date?, lastRMS: Float) { lock.withLock { $0 } }
    func reset(to date: Date?) { lock.withLock { $0 = (date, -160) } }
}

/// Render-thread write gate (transcript-only mode without teardown).
final class AtomicFlag: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Bool>
    init(initial: Bool) { lock = OSAllocatedUnfairLock(initialState: initial) }
    var value: Bool { lock.withLock { $0 } }
    func set(_ v: Bool) { lock.withLock { $0 = v } }
}
