//
//  SystemAudioCapture.swift
//  Daisy
//
//  Loopback capture of system audio (the "other side" of the meeting)
//  via ScreenCaptureKit. We exclude our own process so we don't loop
//  Daisy back onto itself.
//

import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreAudio
import CoreMedia
import os

/// Intentionally NOT @Observable — UI does not bind to this class directly,
/// and the @Observable macro's auto-applied @ObservationTracked conflicts
/// with the `nonisolated` storage we need for the audio render callback.
@MainActor
final class SystemAudioCapture: NSObject, SCStreamDelegate, SCStreamOutput {
    enum CaptureState: Equatable {
        case idle
        case starting
        case capturing
        /// Stream torn down but bufferContinuation is preserved so
        /// upstream consumers (Transcriber) keep their for-await
        /// loops alive across pause/resume.
        case paused
        case stopped
    }

    private(set) var state: CaptureState = .idle
    private(set) var lastError: String?

    /// Peak amplitude of the most recent system-audio buffer, in dB
    /// (where 0 dB == full scale, -160 dB == silence). Updated from
    /// the SCStream output queue at ~10 Hz (rate-limited so we don't
    /// pound MainActor every 20 ms). Surfaces in the widget so the
    /// user can see, mid-meeting, whether system audio capture is
    /// actually receiving the remote side. -160 dB persistently
    /// while `state == .capturing` means trouble (BT output, no
    /// permission to capture the foreground app, etc.).
    private(set) var peakLevelDB: Float = -160

    /// Wall-clock time the last audio sample buffer arrived from
    /// SCStream. nil between sessions or before the FIRST sample
    /// has ever arrived. Used by `checkForSilentCapture()` to fire
    /// a "we're getting no audio" warning toast when the stream is
    /// nominally `.capturing` but no buffers are flowing — the
    /// classic ScreenCaptureKit-on-Bluetooth-output failure mode.
    private(set) var lastSampleAt: Date?

    /// True after the FIRST sample buffer of this session has been
    /// processed. Drives the difference between
    ///   "capture started, no audio yet — give it 30 s"
    /// and
    ///   "capture has been delivering audio, then went silent".
    /// Reset to false on each `start()` from idle/stopped (not on
    /// resume — running totals carry across pause/resume).
    private(set) var hasReceivedAudio: Bool = false

    /// Wall-clock time `start()` flipped state to `.capturing`,
    /// used to compute the "never received any audio" timeout.
    private var captureStartedAt: Date?

    /// Latches `true` the first time `checkForSilentCapture()` fires
    /// its warning toast, so users see the message once per session
    /// instead of every 5 s. Reset on `start()`.
    private var silenceWarningFired: Bool = false

    /// MainActor timer that polls `lastSampleAt` while `state ==
    /// .capturing`. Cheap (5 s cadence, no audio touched). Killed
    /// in `pause()`/`stop()`.
    private var silenceMonitorTimer: Timer?

    /// CoreAudio property-listener block for the default-output-
    /// device change. Held so we can remove it on stop()/pause()
    /// without retain-cycling. SCStream itself has no notion of
    /// "output device changed" — when the user plugs in AirPods or
    /// flips Sound output in Control Centre mid-meeting, the
    /// already-bound SCStream goes silent without notice. This
    /// listener lets us tear it down + restart against the new
    /// default output so audio keeps flowing.
    private var outputDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    /// True after the property listener has been successfully
    /// installed. Drives idempotency in install/remove pairs.
    private var outputDeviceListenerInstalled: Bool = false

    /// Latches `true` while a route-change-induced restart is in
    /// progress. `handleOutputDeviceChange` is `@MainActor`-isolated
    /// (whole class is) so this property is only ever read/written
    /// from MainActor — pre-1.0.3 had a misleading
    /// `nonisolated(unsafe)` annotation.
    ///
    /// Paired with `lastRestartAt` for a 2 s cooldown: CoreAudio
    /// fires the property listener multiple times for a single
    /// user-perceived change (sleep/wake re-emits hours later, mode
    /// switches re-emit ~200ms apart). The bool alone leaks the
    /// race window between the `defer { …InFlight = false }` and
    /// the next listener invocation.
    private var outputRestartInFlight: Bool = false
    private var lastOutputRestartAt: Date?

    /// Rate-limit gate for SCStream → MainActor UI updates. The
    /// audio output queue can fire ~50 callbacks/sec at 48 kHz
    /// with typical CMSampleBuffer sizes; we only need ~10 Hz to
    /// drive a level meter. Stored as a raw Double seconds-since-
    /// reference-date because nonisolated(unsafe) Date access is
    /// awkward and Double atomic-ish reads are fine for a gate.
    nonisolated(unsafe) private var lastUIUpdateRefTime: Double = 0

    /// Fire the silent-capture warning after this many seconds of
    /// `.capturing` state with no buffers received. 30 s is a
    /// compromise — short enough that users learn quickly,
    /// long enough not to fire on transient stream-startup delays.
    private static let silentCaptureTimeoutSec: TimeInterval = 30

    private var stream: SCStream?
    /// nonisolated(unsafe) so the audio render callback can yield without
    /// hopping to main. AsyncStream.Continuation.yield is documented as
    /// thread-safe.
    nonisolated(unsafe) private var bufferContinuation: AsyncStream<AudioChunk>.Continuation?

    /// File URL to archive the captured system audio into. Set in
    /// `start(archiveURL:)`; the audio render callback lazily opens
    /// an `AVAudioFile` on the FIRST sample so the writer's format
    /// matches what SCStream actually delivers (we don't have to
    /// hand-roll a settings dict that might disagree). nil disables
    /// archiving — transcription path still works either way.
    ///
    /// `nonisolated(unsafe)` because the audio callback writes from
    /// the `outputQueue`, not main. **All MainActor-side mutations**
    /// (start/stop/pause and the output-device-change recovery)
    /// **MUST go through `outputQueue.sync { ... }`** to fence behind
    /// any in-flight sample-buffer callback. Pre-1.0.3 the MainActor
    /// did `archiveWriter = nil` directly after `stopCapture()`, and
    /// in-flight callbacks could still call `archiveWriter?.write(...)`
    /// → race against the nil write, occasional torn ExtAudioFile
    /// state, very-occasional truncated tail of system_audio.caf.
    nonisolated(unsafe) private var archiveURL: URL?
    nonisolated(unsafe) private var archiveWriter: AVAudioFile?

    private let outputQueue = DispatchQueue(
        label: "app.essazanov.Daisy.SystemAudioOutput",
        qos: .userInitiated
    )
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "SystemAudio")

    /// PCM stream of system audio. Read this **before** `start()`.
    var buffers: AsyncStream<AudioChunk> {
        AsyncStream { continuation in
            self.bufferContinuation = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.bufferContinuation = nil
            }
        }
    }

    func start(archiveURL: URL? = nil) async throws {
        guard state == .idle || state == .stopped || state == .paused else { return }
        // Only adopt a new archive URL on a fresh start. Resume
        // (state == .paused) keeps the writer that was opened
        // during the original start, so the file accumulates one
        // contiguous recording across pause/resume cycles instead
        // of clobbering itself.
        if state == .idle || state == .stopped {
            self.archiveURL = archiveURL
            self.archiveWriter = nil
            // Reset level-meter and silence-monitor state on fresh
            // start. Resume keeps them so a brief pause/resume cycle
            // doesn't re-trigger the silent-capture warning.
            peakLevelDB = -160
            lastSampleAt = nil
            hasReceivedAudio = false
            silenceWarningFired = false
        }
        state = .starting
        lastError = nil

        let newStream: SCStream
        do {
            newStream = try await buildAndStartSystemAudioStream()
        } catch {
            state = .idle
            lastError = error.localizedDescription
            throw error
        }

        self.stream = newStream
        state = .capturing
        captureStartedAt = Date()
        startSilenceMonitor()
        installOutputDeviceListener()

        // Eager archive placeholder — creates a zero-byte
        // `system_audio.caf` on disk right at session start. The
        // lazy-open path in `stream(_:didOutputSampleBuffer:_:)`
        // will overwrite this with a real AVAudioFile on the FIRST
        // delivered sample buffer. If SCStream never delivers any
        // audio (the classic BT-loopback failure mode), the file
        // stays at zero bytes — making "capture armed but received
        // nothing" diagnosable from the artifact alone (vs the
        // pre-fix behaviour where no file at all meant the post-
        // mortem couldn't tell capture-never-started from capture-
        // received-nothing).
        if let url = self.archiveURL {
            let created = FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: nil
            )
            if created {
                log.info("System audio archive placeholder created: \(url.lastPathComponent, privacy: .public)")
            } else {
                log.error("Failed to create system audio archive placeholder at \(url.path, privacy: .public)")
            }
        }

        // Bluetooth output detection — known to break SCStream's
        // audio loopback on multiple macOS Tahoe builds. SCK binds
        // to the default output, but the BT stack lives outside the
        // CoreAudio loopback path, so SCStream reports `.capturing`
        // and delivers zero buffers. Surface a heads-up at session
        // start so the user can switch outputs BEFORE the meeting,
        // not discover the silent failure post-meeting.
        //
        // The silence-monitor toast (`checkForSilentCapture`) is
        // the safety net for cases where output changes mid-session
        // or this initial BT check misses (e.g. transport type
        // reported as "unknown" for some BT devices).
        if Self.currentOutputDeviceIsBluetooth() {
            log.warning("Default output is Bluetooth — SCStream loopback may not deliver frames")
            ToastCenter.shared.show(
                "Bluetooth headphones detected — Daisy may not capture the remote side. Use built-in speakers, wired headphones, or install BlackHole for reliable system-audio capture.",
                style: .warning
            )
        }

        log.info("SystemAudio capturing")
    }

    /// Query CoreAudio for the default output device's transport
    /// type and return `true` if it's any flavour of Bluetooth.
    /// Used at `start()` time to surface the BT loopback caveat
    /// before the meeting begins. Returns `false` on any property
    /// query error — never block the start path on a diagnostic.
    nonisolated private static func currentOutputDeviceIsBluetooth() -> Bool {
        // 1. Resolve default output device ID.
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultOutAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let idStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutAddress,
            0, nil,
            &size, &deviceID
        )
        guard idStatus == noErr, deviceID != kAudioObjectUnknown else { return false }

        // 2. Read its transport type.
        var transportType: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let tStatus = AudioObjectGetPropertyData(
            deviceID, &transportAddress, 0, nil, &size, &transportType
        )
        guard tStatus == noErr else { return false }

        // Both classic BT and BLE transports map to the same
        // SCK loopback failure mode in practice. Catch both.
        return transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Build + start a fresh SCStream against the current default
    /// output. Extracted from `start()` so the route-change handler
    /// (`handleOutputDeviceChange`) can rebuild against the new
    /// device without copying the dance. Throws `DaisyError.
    /// audioEngineFailed` on any failure; caller is responsible for
    /// resetting state.
    private func buildAndStartSystemAudioStream() async throws -> SCStream {
        // 1. Discover shareable content + the display we'll attach to.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            throw DaisyError.audioEngineFailed("Could not enumerate displays: \(error.localizedDescription)")
        }

        guard let display = content.displays.first else {
            throw DaisyError.audioEngineFailed("No displays available for screen capture.")
        }

        // Exclude our own app from the audio loopback.
        let ourApps = content.applications.filter {
            Bundle.main.bundleIdentifier == $0.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ourApps,
            exceptingWindows: []
        )

        // 2. Audio-only config (we still capture a 2×2 video frame because
        //    SCStream requires *some* video output to function).
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        // 3. Build + start stream.
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()
        } catch {
            throw DaisyError.audioEngineFailed("Could not start system audio: \(error.localizedDescription)")
        }
        return stream
    }

    // MARK: - Default-output-device change observer

    /// Install a CoreAudio property listener for the default-output-
    /// device selector. When the user plugs in AirPods, unplugs them,
    /// or flips Sound output via Control Centre mid-meeting, this
    /// fires and we rebuild the SCStream against the new default —
    /// otherwise SCK stays bound to the OLD device and the remote
    /// side stops landing in the recording without any visible
    /// indication.
    ///
    /// Block-based variant (vs the C-callback variant) because the
    /// closure can capture `[weak self]` cleanly and dispatch back to
    /// MainActor; the C variant requires a raw `void*` self pointer
    /// and is more bookkeeping for the same effect.
    private func installOutputDeviceListener() {
        guard !outputDeviceListenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // CoreAudio dispatches the block on the queue we pass
            // below — already off main. Hop back to MainActor for
            // the actual restart logic.
            Task { @MainActor [weak self] in
                await self?.handleOutputDeviceChange()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.global(qos: .userInitiated),
            block
        )
        if status == noErr {
            outputDeviceListenerBlock = block
            outputDeviceListenerInstalled = true
            log.info("Output device listener installed")
        } else {
            log.error("Failed to install output device listener: status=\(status, privacy: .public)")
        }
    }

    /// Remove the property listener installed by
    /// `installOutputDeviceListener`. Idempotent.
    private func removeOutputDeviceListener() {
        guard outputDeviceListenerInstalled, let block = outputDeviceListenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
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
            log.error("Failed to remove output device listener: status=\(status, privacy: .public)")
        }
        outputDeviceListenerBlock = nil
        outputDeviceListenerInstalled = false
    }

    /// Tear down + rebuild the SCStream when macOS reports a default-
    /// output-device change. Debounces concurrent fires (macOS often
    /// emits the property change 2–3 times in rapid succession as the
    /// audio graph settles).
    private func handleOutputDeviceChange() async {
        guard state == .capturing else { return }
        guard !outputRestartInFlight else { return }
        // Wall-clock cooldown — defer-only debounce leaks the gap
        // between `outputRestartInFlight = false` and the next
        // CoreAudio fire (sleep/wake can re-emit hours later, the
        // bool alone isn't enough).
        if let last = lastOutputRestartAt,
           Date().timeIntervalSince(last) < 2.0 {
            return
        }
        outputRestartInFlight = true
        defer {
            outputRestartInFlight = false
            lastOutputRestartAt = Date()
        }

        log.info("Default output device changed mid-capture — restarting SCStream")

        // Tear down current stream cleanly. Failures here don't
        // block the restart attempt — we'll just have a dangling
        // stream the kernel cleans up.
        if let s = stream {
            do { try await s.stopCapture() }
            catch { log.error("Stop for route change failed: \(error.localizedDescription, privacy: .public)") }
        }
        stream = nil

        do {
            let newStream = try await buildAndStartSystemAudioStream()
            self.stream = newStream
            // Reset the silence-warning latch — fresh stream gets a
            // fresh 30 s timeout to deliver audio.
            silenceWarningFired = false
            captureStartedAt = Date()
            lastSampleAt = nil
            ToastCenter.shared.show(
                "Output device changed — system audio capture continues.",
                style: .info
            )
        } catch {
            log.error("Restart for output device change failed: \(error.localizedDescription, privacy: .public)")
            // Don't kill the rest of the recording session — mic
            // capture is in a separate AudioRecorder instance and
            // is unaffected by SCStream failure. Just surface to the
            // user so they can stop & restart if they need the
            // remote side captured.
            state = .stopped
            ToastCenter.shared.show(
                "Output changed and Daisy couldn't restart system audio capture. Stop & restart the session if you need the remote side recorded.",
                style: .warning
            )
        }
    }

    /// Begin polling for the silent-capture condition. Polls every
    /// 5 s while `state == .capturing`. Cheap MainActor timer —
    /// touches no audio state, just reads `lastSampleAt` / start time
    /// and compares against `silentCaptureTimeoutSec`.
    private func startSilenceMonitor() {
        silenceMonitorTimer?.invalidate()
        silenceMonitorTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkForSilentCapture() }
        }
    }

    /// Stop the silence-monitor timer. Safe to call when no timer
    /// is installed.
    private func stopSilenceMonitor() {
        silenceMonitorTimer?.invalidate()
        silenceMonitorTimer = nil
    }

    /// Detect the "SCStream is nominally capturing but delivering no
    /// audio" failure mode. Classic causes on macOS Tahoe:
    ///
    ///   - default output is Bluetooth headphones (SCK's loopback
    ///     doesn't reach the BT stack on a number of macOS builds),
    ///   - Screen Recording permission was granted at runtime but
    ///     the foreground app's audio path isn't actually visible,
    ///   - output device hot-swapped mid-session (separate task —
    ///     output-device-change observer, #165).
    ///
    /// We fire a toast once per session. The UI surface for repeat
    /// occurrences (a dim system-audio dot in the widget) lives in
    /// the widget refactor (#168) — this is the audible warning.
    private func checkForSilentCapture() {
        guard state == .capturing, !silenceWarningFired else { return }

        let now = Date()
        let silentDuration: TimeInterval
        if let lastSampleAt {
            // We DID get audio at some point — measure gap since
            // last delivered buffer.
            silentDuration = now.timeIntervalSince(lastSampleAt)
        } else if let captureStartedAt {
            // No buffers since session start — measure age of the
            // capture itself.
            silentDuration = now.timeIntervalSince(captureStartedAt)
        } else {
            return
        }

        guard silentDuration >= Self.silentCaptureTimeoutSec else { return }

        silenceWarningFired = true
        let neverGotAudio = !hasReceivedAudio
        let msg = neverGotAudio
            ? "System audio capture is on but no sound is reaching Daisy. The remote side won't be recorded — check your output device (Bluetooth headphones can't be captured on macOS)."
            : "System audio went silent — the remote side may not be recording anymore. Check your output device."
        log.warning("Silent SCStream detected after \(Int(silentDuration), privacy: .public)s (hasReceivedAudio=\(self.hasReceivedAudio, privacy: .public))")
        ToastCenter.shared.show(msg, style: .warning)
    }

    func stop() async {
        stopSilenceMonitor()
        removeOutputDeviceListener()
        captureStartedAt = nil
        peakLevelDB = -160
        guard let s = stream else {
            if state != .paused { state = .stopped }
            else { state = .stopped }
            // Close archive even if no stream is active (covers the
            // already-paused → stop transition). Still gated through
            // outputQueue.sync for symmetry — if an old stream's
            // callback is somehow still pending, we serialize behind
            // it.
            outputQueue.sync {
                archiveWriter = nil
                archiveURL = nil
            }
            return
        }
        do { try await s.stopCapture() }
        catch { log.error("Stop error: \(error.localizedDescription, privacy: .public)") }
        stream = nil
        bufferContinuation?.finish()
        bufferContinuation = nil
        // Fence behind any in-flight sample-buffer callback. After
        // `stopCapture()` returns, ScreenCaptureKit promises no NEW
        // buffers will be delivered, but a callback currently mid-
        // execution on outputQueue can still touch archiveWriter.
        // `outputQueue.sync` on a serial queue blocks until that
        // callback finishes, then runs our block (which nils out
        // the writer, triggering ExtAudioFile dispose under the
        // same queue — atomic w.r.t. any callback).
        outputQueue.sync {
            archiveWriter = nil
            archiveURL = nil
        }
        state = .stopped
    }

    /// Soft pause: tear down the SCStream but keep the
    /// bufferContinuation alive so the upstream Transcriber's
    /// for-await loop doesn't terminate. ScreenCaptureKit has no
    /// native pause — we rebuild a fresh stream in `resume()` and
    /// route it to the same continuation.
    func pause() async {
        guard state == .capturing, let s = stream else { return }
        stopSilenceMonitor()
        removeOutputDeviceListener()
        peakLevelDB = -160
        do { try await s.stopCapture() }
        catch { log.error("Pause error: \(error.localizedDescription, privacy: .public)") }
        stream = nil
        state = .paused
        log.info("SystemAudio paused")
    }

    /// Resume after `pause()`: build a new SCStream with the same
    /// config and route its output to the existing continuation.
    func resume() async throws {
        guard state == .paused else { return }
        // Re-run the full discover + filter + config dance — display
        // topology can change while we were paused (Mac plugged into
        // a different monitor, etc.).
        try await start()
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of outputType: SCStreamOutputType) {
        guard outputType == .audio,
              CMSampleBufferIsValid(sampleBuffer),
              let pcm = Self.pcmBuffer(from: sampleBuffer) else {
            return
        }
        let chunk = AudioChunk(pcm: pcm, time: AVAudioTime(hostTime: mach_absolute_time()))
        bufferContinuation?.yield(chunk)

        // Publish a rate-limited level meter + sample-arrival
        // timestamp to MainActor. SCStream can fire ~50 callbacks/s
        // at 48 kHz with typical CMSampleBuffer sizes; the widget
        // and silence monitor only need ~10 Hz. The gate ensures we
        // don't pound the MainActor queue.
        let nowRefTime = Date().timeIntervalSinceReferenceDate
        if nowRefTime - lastUIUpdateRefTime > 0.1 {
            lastUIUpdateRefTime = nowRefTime
            let peak = Self.peakLevelDB(of: pcm)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.peakLevelDB = peak
                self.lastSampleAt = Date()
                self.hasReceivedAudio = true
            }
        }

        // Archive write — lazily open AVAudioFile on the first
        // sample so we use the actual stream format (avoids
        // settings-dict drift between what we declared and what SCK
        // delivers). All access happens on `outputQueue`, which is
        // single-threaded, so no race on archiveWriter / archiveURL.
        guard let url = archiveURL else { return }
        if archiveWriter == nil {
            do {
                archiveWriter = try AVAudioFile(
                    forWriting: url,
                    settings: pcm.format.settings,
                    commonFormat: pcm.format.commonFormat,
                    interleaved: pcm.format.isInterleaved
                )
            } catch {
                // Don't keep retrying every sample if open failed —
                // disable archiving for the rest of the session.
                // Transcription continues unaffected.
                log.error("System audio archive open failed: \(error.localizedDescription, privacy: .public)")
                archiveURL = nil
                return
            }
        }
        do {
            try archiveWriter?.write(from: pcm)
        } catch {
            // One sample's write failure shouldn't trash the whole
            // recording — log and move on. Persistent failures will
            // pollute the log but the live transcript stays intact.
            log.error("System audio archive write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Peak amplitude (in dB, where 0 dB = full-scale) over the
    /// frames in `buffer`. Mirrors `AudioRecorder.peakLevelDB(of:)`
    /// — kept inline here so this class doesn't import the mic
    /// recorder's private static helper. Cheap: O(frames × channels)
    /// over a single PCMBuffer, runs on the SCStream output queue.
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

    // MARK: - SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.lastError = error.localizedDescription
            self?.state = .stopped
        }
    }

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer

    nonisolated private static func pcmBuffer(from sample: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sample),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: format.channelCount,
                mDataByteSize: 0,
                mData: nil
            )
        )

        let err = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard err == noErr else { return nil }

        let srcABL = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        if format.isInterleaved {
            if let src = srcABL[0].mData,
               let dst = buffer.audioBufferList.pointee.mBuffers.mData {
                memcpy(dst, src, Int(srcABL[0].mDataByteSize))
            }
        } else {
            let dstABL = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for ch in 0..<min(srcABL.count, dstABL.count) {
                if let src = srcABL[ch].mData, let dst = dstABL[ch].mData {
                    memcpy(dst, src, Int(srcABL[ch].mDataByteSize))
                }
            }
        }
        return buffer
    }
}
