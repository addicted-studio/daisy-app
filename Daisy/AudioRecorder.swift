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
    @ObservationIgnored
    private let analyzer = SpectrumAnalyzer()
    @ObservationIgnored
    private let log = Logger(subsystem: "app.essazanov.Daisy", category: "AudioRecorder")

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

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            // Render thread — keep work minimal.
            try? fileRef?.write(from: buffer)
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
        state = .recording

        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }

        log.info("AudioRecorder started")
    }

    func stop() {
        guard state == .recording else { return }
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
    }

    func reset() {
        if state == .recording { stop() }
        state = .idle
        elapsed = 0
        levelDB = -160
        archivedFileURL = nil
        lastError = nil
    }

    // MARK: - Helpers

    private func tick() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
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
