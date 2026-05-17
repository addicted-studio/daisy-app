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

    /// Begin capturing microphone audio. Pass an `archiveURL` to also write
    /// a .caf file for later replay/re-processing.
    func start(archiveURL: URL? = nil) throws {
        guard state != .recording else { return }
        lastError = nil

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0 else {
            throw DaisyError.noMicrophone
        }

        if let archiveURL {
            do {
                audioFile = try AVAudioFile(forWriting: archiveURL, settings: format.settings)
                archivedFileURL = archiveURL
            } catch {
                throw DaisyError.audioEngineFailed(error.localizedDescription)
            }
        } else {
            audioFile = nil
            archivedFileURL = nil
        }

        // Capture references for the render-thread tap closure.
        let continuationRef = bufferContinuation
        let fileRef = audioFile
        let analyzerRef = analyzer
        let writeErrorsRef = writeErrors
        writeErrors.reset()

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            // Render thread — keep work minimal. Buffer-write failures
            // are accumulated and surfaced once at stop() rather than
            // touching MainActor state per buffer.
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
            // samples is ~0.5 ms on Apple Silicon — safe on render thread.
            var bands: [Float]? = nil
            if let ch = buffer.floatChannelData?[0] {
                let frames = Int(buffer.frameLength)
                let pcm = Array(UnsafeBufferPointer(start: ch, count: frames))
                let sampleRate = buffer.format.sampleRate
                bands = analyzerRef.bands(from: pcm[...], sampleRate: sampleRate)
            }

            Task { @MainActor [weak self] in
                self?.levelDB = peak
                if let b = bands {
                    self?.spectrumBands = b
                }
            }
        }

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
        log.info("AudioRecorder resumed")
    }

    func stop() {
        // Tolerate stop-from-paused too: the explicit Stop & save
        // path may come straight from a paused session.
        guard state == .recording || state == .paused else { return }
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
