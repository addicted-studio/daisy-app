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

    private var stream: SCStream?
    /// nonisolated(unsafe) so the audio render callback can yield without
    /// hopping to main. AsyncStream.Continuation.yield is documented as
    /// thread-safe.
    nonisolated(unsafe) private var bufferContinuation: AsyncStream<AudioChunk>.Continuation?

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

    func start() async throws {
        guard state == .idle || state == .stopped || state == .paused else { return }
        state = .starting
        lastError = nil

        // 1. Discover shareable content + the display we'll attach to.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
        } catch {
            state = .idle
            lastError = error.localizedDescription
            throw DaisyError.audioEngineFailed("Could not enumerate displays: \(error.localizedDescription)")
        }

        guard let display = content.displays.first else {
            state = .idle
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
            state = .idle
            lastError = error.localizedDescription
            throw DaisyError.audioEngineFailed("Could not start system audio: \(error.localizedDescription)")
        }

        self.stream = stream
        state = .capturing
        log.info("SystemAudio capturing")
    }

    func stop() async {
        guard let s = stream else {
            if state != .paused { state = .stopped }
            else { state = .stopped }
            return
        }
        do { try await s.stopCapture() }
        catch { log.error("Stop error: \(error.localizedDescription, privacy: .public)") }
        stream = nil
        bufferContinuation?.finish()
        bufferContinuation = nil
        state = .stopped
    }

    /// Soft pause: tear down the SCStream but keep the
    /// bufferContinuation alive so the upstream Transcriber's
    /// for-await loop doesn't terminate. ScreenCaptureKit has no
    /// native pause — we rebuild a fresh stream in `resume()` and
    /// route it to the same continuation.
    func pause() async {
        guard state == .capturing, let s = stream else { return }
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
