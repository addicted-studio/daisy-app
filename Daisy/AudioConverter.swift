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
