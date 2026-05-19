//
//  SpectrumAnalyzer.swift
//  Daisy
//
//  Reduces a rolling window of mono PCM samples into 6 normalized
//  spectrum bands using a Hann-windowed 2048-point FFT (vDSP).
//
//  Tuned for the daisy widget — not scientific analysis:
//    • Voice-friendly Hz band edges (80, 160, 320, 640, 1280, 2560, 5120)
//    • RMS within each band (smoother than peak-pick)
//    • dB clamp (-55…-20) so conversation volume maps to 0…1 instead of
//      flat-lining near zero with linear scaling
//    • Asymmetric attack/decay smoothing for "petals bloom and settle"
//    • Per-band hysteresis noise gate (no chatter on speech tails)
//    • Pre-allocated working buffers (no allocations per call)
//    • Lock around mutable state — `reset()` is safe to call from any
//      thread while `bands(…)` is mid-flight on the audio render thread
//

import Foundation
import Accelerate
import os.lock

final class SpectrumAnalyzer: @unchecked Sendable {
    static let bandCount = 6
    private static let log2n = 11
    private static let fftN = 1 << log2n  // 2048 — ~23 Hz/bin at 48 kHz

    /// Hz edges separating the 6 bands. Concentrated on the vocal range
    /// (fundamental ~80-300 Hz, formants ~500-3500 Hz). Treble band ends
    /// at 5.12 kHz — anything higher is sibilance / noise.
    private static let bandEdgesHz: [Float] = [80, 160, 320, 640, 1280, 2560, 5120]

    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]

    // Pre-allocated working buffers — the render thread never hits the heap.
    private var pcm:        [Float]
    private var windowed:   [Float]
    private var realIn:     [Float]
    private var imagIn:     [Float]
    private var realOut:    [Float]
    private var imagOut:    [Float]
    private var magnitudes: [Float]

    /// Smoothed band values (carry over between calls). Asymmetric
    /// attack/decay so petals snap up but glide down.
    private var smoothed: [Float] = Array(repeating: 0, count: bandCount)
    private let attack: Float = 0.55
    private let decay:  Float = 0.32

    /// dB envelope — values below floorDB read as silent (0), values at
    /// or above ceilDB read as full (1). Tuned for typical mic input
    /// where conversational speech peaks around -25 to -20 dBFS.
    private let floorDB: Float = -55
    private let ceilDB:  Float = -20

    /// Per-band hysteresis noise gate. Open above `gateOpen`, close
    /// below `gateClose`. Prevents chatter when a single band wobbles
    /// across one threshold.
    private let gateOpen:  Float = 0.18
    private let gateClose: Float = 0.08
    private var gateIsOpen: Bool = false

    /// Locks all mutable state for safe cross-thread `reset()`.
    private let lock = OSAllocatedUnfairLock()

    init() {
        let n = Self.fftN
        let half = n / 2
        fft = vDSP.FFT(
            log2n: vDSP_Length(Self.log2n),
            radix: .radix2,
            ofType: DSPSplitComplex.self
        )!
        window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: n,
            isHalfWindow: false
        )
        pcm        = Array(repeating: 0, count: n)
        windowed   = Array(repeating: 0, count: n)
        realIn     = Array(repeating: 0, count: half)
        imagIn     = Array(repeating: 0, count: half)
        realOut    = Array(repeating: 0, count: half)
        imagOut    = Array(repeating: 0, count: half)
        magnitudes = Array(repeating: 0, count: half)
    }

    /// Compute spectrum bands from the trailing window of mono samples.
    /// Returns `bandCount` floats in 0…1.
    ///
    /// **Takes `UnsafeBufferPointer<Float>` directly** so the audio
    /// render thread doesn't allocate an intermediate Swift Array on
    /// every tap callback (pre-1.0.3 the caller did
    /// `Array(UnsafeBufferPointer(start: ch, count: frames))` and
    /// re-sliced; that ~16 KB alloc per buffer at 100 Hz had a real
    /// chance of priority-inverting against the render thread's
    /// internal locks during malloc slow paths). The buffer's
    /// backing memory is borrowed for the duration of this call
    /// only — we copy what we need into our pre-allocated `pcm`
    /// scratch space immediately.
    func bands(from samples: UnsafeBufferPointer<Float>, sampleRate: Double) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        let n = Self.fftN
        let half = n / 2

        // 1. Pad / truncate input into the working buffer. Take the
        //    TRAILING `n` samples (suffix of the input buffer); for
        //    shorter inputs the tail is zero-padded. Matches the
        //    pre-1.0.3 layout exactly so the Hann window + FFT
        //    output are unchanged.
        for i in 0..<n { pcm[i] = 0 }
        let total = samples.count
        let copyCount = min(total, n)
        let srcStart = total - copyCount   // negative-safe via min above
        for i in 0..<copyCount {
            pcm[i] = samples[srcStart + i]
        }

        // 2. Hann window.
        vDSP.multiply(pcm, window, result: &windowed)

        // 3. Pack windowed reals into split-complex form.
        windowed.withUnsafeBufferPointer { winPtr in
            winPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cplxPtr in
                realIn.withUnsafeMutableBufferPointer { rp in
                    imagIn.withUnsafeMutableBufferPointer { ip in
                        var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                        vDSP_ctoz(cplxPtr, 2, &split, 1, vDSP_Length(half))
                    }
                }
            }
        }

        // 4. Forward FFT.
        realIn.withUnsafeMutableBufferPointer { realInPtr in
            imagIn.withUnsafeMutableBufferPointer { imagInPtr in
                realOut.withUnsafeMutableBufferPointer { realOutPtr in
                    imagOut.withUnsafeMutableBufferPointer { imagOutPtr in
                        let inSplit = DSPSplitComplex(
                            realp: realInPtr.baseAddress!,
                            imagp: imagInPtr.baseAddress!
                        )
                        var outSplit = DSPSplitComplex(
                            realp: realOutPtr.baseAddress!,
                            imagp: imagOutPtr.baseAddress!
                        )
                        fft.forward(input: inSplit, output: &outSplit)
                    }
                }
            }
        }

        // 5. Magnitudes. In Apple's real-FFT packing, realOut[0] = DC
        //    and imagOut[0] = Nyquist (the imaginary slot of bin 0 is
        //    reused for the highest real bin). Handle DC specially; we
        //    don't use Nyquist for any voice band.
        let scale = 2.0 / Float(n)
        magnitudes[0] = abs(realOut[0]) * scale
        for i in 1..<half {
            let r = realOut[i]
            let im = imagOut[i]
            magnitudes[i] = sqrt(r * r + im * im) * scale
        }

        // 6. RMS within each voice-tuned Hz band.
        let binHz = Float(sampleRate) / Float(n)
        var raw = [Float](repeating: 0, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let loHz = Self.bandEdgesHz[b]
            let hiHz = Self.bandEdgesHz[b + 1]
            let loBin = max(1, Int(loHz / binHz))
            let hiBin = min(half - 1, Int(hiHz / binHz))
            guard hiBin >= loBin else { continue }
            var sumSq: Float = 0
            var count = 0
            for i in loBin...hiBin {
                let v = magnitudes[i]
                sumSq += v * v
                count += 1
            }
            raw[b] = count > 0 ? sqrt(sumSq / Float(count)) : 0
        }

        // 7. Convert to dB and clamp to 0…1.
        let eps: Float = 1e-7
        for i in 0..<Self.bandCount {
            let db = 20.0 * log10(raw[i] + eps)
            let norm = (db - floorDB) / (ceilDB - floorDB)
            raw[i] = max(0, min(1, norm))
        }

        // 8. Per-band hysteresis gate. Open when any band crosses the
        //    open threshold; close only when every band falls below
        //    the close threshold. Once closed, force all bands to 0
        //    so the decay envelope pulls petals back to rest.
        let peak = raw.max() ?? 0
        if gateIsOpen {
            if peak < gateClose { gateIsOpen = false }
        } else {
            if peak > gateOpen { gateIsOpen = true }
        }
        if !gateIsOpen {
            for i in 0..<Self.bandCount { raw[i] = 0 }
        }

        // 9. Asymmetric smoothing.
        for i in 0..<Self.bandCount {
            let prev = smoothed[i]
            let next = raw[i]
            let coef = next > prev ? attack : decay
            smoothed[i] = prev + (next - prev) * coef
        }
        return smoothed
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        for i in 0..<Self.bandCount {
            smoothed[i] = 0
        }
        gateIsOpen = false
    }
}
