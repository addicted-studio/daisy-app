//
//  AudioConverter.swift
//  Daisy
//
//  Wraps AVAudioConverter to turn arbitrary input PCM buffers (any sample
//  rate, any channel count, interleaved or not) into the format Whisper
//  expects: 16 kHz, mono, 32-bit float.
//

import Foundation
import AVFoundation

final class AudioConverter {
    let outputFormat: AVAudioFormat
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init?(inputFormat: AVAudioFormat) {
        self.inputFormat = inputFormat
        guard let output = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { return nil }
        self.outputFormat = output
        guard let conv = AVAudioConverter(from: inputFormat, to: output) else { return nil }
        self.converter = conv
    }

    /// Convert one input buffer and return the resulting 16 kHz mono Float
    /// samples. Returns nil only on hard converter failure; an empty array
    /// is possible during silence-suppressing rate conversions.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let estimatedOutFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard estimatedOutFrames > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: estimatedOutFrames) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error || error != nil {
            return nil
        }

        guard let ch = outBuffer.floatChannelData?[0] else { return [] }
        let count = Int(outBuffer.frameLength)
        guard count > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: ch, count: count))
    }
}

/// Decodes finished on-disk `.caf` archives back into the 16 kHz mono
/// Float32 sample array Whisper + FluidAudio expect.
///
/// Why this exists: live transcription runs off an in-memory rolling
/// buffer (`Transcriber.allSamples`) capped at 30 minutes and trimmed
/// when the live pass falls behind on a long/dense recording. The
/// trimmed audio is gone from memory — but it's always on disk in the
/// `.caf` archive, which the recorder writes frame-for-frame for the
/// WHOLE session. The post-Stop final pass decodes the archive here so
/// the saved transcript covers the entire recording regardless of how
/// far live transcription lagged or how much the buffer trimmed.
///
/// `nonisolated` + `enum` (no state) so the decode can run on a
/// background `Task.detached` off the `@MainActor` Transcriber — it's
/// CPU + IO heavy (hundreds of MB on a multi-hour session) and must
/// not block the main thread.
enum AudioArchiveDecoder {
    /// Decode one or more `.caf` archives to a single 16 kHz mono Float32
    /// array, concatenated in the given order. Each file is converted
    /// independently — mid-session route changes roll the mic archive into
    /// `microphone.partN.caf` files that may carry different native formats,
    /// so a single shared converter can't span them. Missing / unreadable /
    /// header-only (zero-frame) parts are skipped. Returns `nil` only when
    /// NOTHING decoded (so the caller can fall back to the in-memory buffer);
    /// a partial decode (one bad part among several good ones) still returns
    /// what was recovered.
    nonisolated static func decodeToMono16k(urls: [URL]) -> [Float]? {
        guard !urls.isEmpty else { return nil }
        guard let out = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,   // Whisper's required input rate
            channels: 1,
            interleaved: false
        ) else { return nil }

        var samples: [Float] = []
        var anyDecoded = false
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let part = decodeFile(url: url, to: out), !part.isEmpty else { continue }
            samples.append(contentsOf: part)
            anyDecoded = true
        }
        return anyDecoded ? samples : nil
    }

    /// Write a 16 kHz mono Float32 sample array to a `.caf` at `url`,
    /// overwriting any existing file. Used to materialise a side-note
    /// audio excerpt sliced (and mic+system mixed) out of a meeting's own
    /// archive. Written in 30 s blocks so we never build one giant PCM
    /// buffer. Returns whether the write succeeded.
    @discardableResult
    nonisolated static func writeMono16kCAF(samples: [Float], to url: URL) -> Bool {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: 16_000,
                  channels: 1,
                  interleaved: false
              ) else { return false }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let block = 16_000 * 30
            var offset = 0
            while offset < samples.count {
                let n = min(block, samples.count - offset)
                guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                                 frameCapacity: AVAudioFrameCount(n)),
                      let ch = buf.floatChannelData?[0] else { return false }
                samples.withUnsafeBufferPointer { src in
                    ch.update(from: src.baseAddress!.advanced(by: offset), count: n)
                }
                buf.frameLength = AVAudioFrameCount(n)
                try file.write(from: buf)
                offset += n
            }
            return true
        } catch {
            return false
        }
    }

    /// Stream-decode a single file in ~10 s blocks so we never hold the
    /// whole native-rate file in memory at once (only the 16 kHz result
    /// grows). Returns an empty array for a zero-frame file, `nil` on a
    /// hard open/convert failure.
    nonisolated private static func decodeFile(url: URL, to out: AVAudioFormat) -> [Float]? {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            return nil
        }
        let inFormat = file.processingFormat
        let totalFrames = file.length
        guard totalFrames > 0, inFormat.sampleRate > 0 else { return [] }
        guard let converter = AVAudioConverter(from: inFormat, to: out) else { return nil }

        // One pull = ~10 s of input audio at the file's native rate.
        let inBlock = AVAudioFrameCount(max(inFormat.sampleRate, 16_000) * 10)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inBlock) else { return nil }

        // AVAudioConverter's input block is `@Sendable`; in a nonisolated
        // context it can't capture the non-Sendable file + buffer directly.
        // Hand it ONE `@unchecked Sendable` box instead — AVFoundation calls
        // the block synchronously on this thread for the lifetime of each
        // convert(), so there's no real concurrent access to make unsafe.
        let feed = CAFDecodeFeed(file: file, inBuf: inBuf, blockFrames: inBlock)

        var result: [Float] = []
        result.reserveCapacity(Int(Double(totalFrames) * 16_000 / inFormat.sampleRate) + 1024)

        let ratio = out.sampleRate / inFormat.sampleRate
        // Downsampling (ratio < 1) means one input block always fits in the
        // sized output buffer; the +1024 slack covers resampler look-ahead.
        let outCap = AVAudioFrameCount(Double(inBlock) * ratio + 1024)

        while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: outCap) else { break }
            var convError: NSError?
            // Pointer type is inferred here (it's an autoreleasing pointer in
            // the imported AVFoundation signature); we only set its pointee.
            let status = converter.convert(to: outBuf, error: &convError) { _, inStatus in
                if let buf = feed.readNext() {
                    inStatus.pointee = .haveData
                    return buf
                }
                inStatus.pointee = .endOfStream
                return nil
            }

            if let ch = outBuf.floatChannelData?[0], outBuf.frameLength > 0 {
                result.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(outBuf.frameLength)))
            }

            if status == .error || status == .endOfStream { break }
            // .haveData → keep pulling; .inputRanDry can't occur (the input
            // block only ever returns .haveData or .endOfStream).
        }
        return result
    }
}

/// Mutable per-file decode state handed to `AVAudioConverter`'s
/// `@Sendable` input block. AVFoundation invokes the block synchronously
/// on the calling thread within a single `convert(...)` — there is no
/// real cross-thread sharing — so `@unchecked Sendable` is sound and lets
/// the (nonisolated) decode closure capture one Sendable reference instead
/// of the non-Sendable `AVAudioFile` + `AVAudioPCMBuffer` directly.
nonisolated private final class CAFDecodeFeed: @unchecked Sendable {
    private let file: AVAudioFile
    private let inBuf: AVAudioPCMBuffer
    private let blockFrames: AVAudioFrameCount
    private var reachedEOF = false

    init(file: AVAudioFile, inBuf: AVAudioPCMBuffer, blockFrames: AVAudioFrameCount) {
        self.file = file
        self.inBuf = inBuf
        self.blockFrames = blockFrames
    }

    /// Read the next block from the file. Returns the filled buffer, or
    /// `nil` once the file is exhausted (caller signals `.endOfStream`).
    func readNext() -> AVAudioPCMBuffer? {
        if reachedEOF { return nil }
        inBuf.frameLength = 0
        do {
            try file.read(into: inBuf, frameCount: blockFrames)
        } catch {
            reachedEOF = true
            return nil
        }
        if inBuf.frameLength == 0 {
            reachedEOF = true
            return nil
        }
        return inBuf
    }
}
