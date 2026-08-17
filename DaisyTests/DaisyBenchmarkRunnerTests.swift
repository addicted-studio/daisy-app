//
//  DaisyBenchmarkRunnerTests.swift
//  DaisyTests
//
//  Opt-in executable benchmark surface. Normal test runs return immediately;
//  Benchmarks/run_daisy.sh supplies an audio path and output path to exercise
//  the exact archive decoder, Whisper final profile, and diarizer the app uses.
//

import Foundation
import CryptoKit
import Testing
@testable import Daisy

@Suite("Daisy benchmark runner")
@MainActor
struct DaisyBenchmarkRunnerTests {
    nonisolated struct Request: Decodable {
        let audioPath: String
        let outputPath: String
        let originalAudioName: String
        let language: String
        let speakerCount: String

        enum CodingKeys: String, CodingKey {
            case audioPath = "audio_path"
            case outputPath = "output_path"
            case originalAudioName = "original_audio_name"
            case language
            case speakerCount = "speaker_count"
        }
    }

    nonisolated struct OutputSegment: Codable {
        let start: Double
        let end: Double
        let speaker: String?
        let text: String
    }

    nonisolated struct OutputDiarizationSegment: Codable {
        let start: Double
        let end: Double
        let speaker: String
    }

    nonisolated struct Output: Codable {
        let schemaVersion: Int
        let product: String
        let version: String
        let build: String
        let engine: String
        let language: String?
        let audioPath: String
        let audioSHA256: String
        let audioDurationSeconds: Double
        let modelLoadSeconds: Double
        let processingSeconds: Double
        let detectedSpeakers: Int
        let requestedSpeakerCount: Int?
        let diarizationSegments: [OutputDiarizationSegment]
        let segments: [OutputSegment]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case product, version, build, engine, language
            case audioPath = "audio_path"
            case audioSHA256 = "audio_sha256"
            case audioDurationSeconds = "audio_duration_seconds"
            case modelLoadSeconds = "model_load_seconds"
            case processingSeconds = "processing_seconds"
            case detectedSpeakers = "detected_speakers"
            case requestedSpeakerCount = "requested_speaker_count"
            case diarizationSegments = "diarization_segments"
            case segments
        }
    }

    @Test("Run the product pipeline when benchmark paths are supplied")
    func runProductPipeline() async throws {
        let environment = ProcessInfo.processInfo.environment
        let request: Request?
        if let audioPath = environment["DAISY_BENCHMARK_AUDIO"],
           let outputPath = environment["DAISY_BENCHMARK_OUTPUT"],
           !audioPath.isEmpty,
           !outputPath.isEmpty {
            request = Request(
                audioPath: audioPath,
                outputPath: outputPath,
                originalAudioName: URL(fileURLWithPath: audioPath).lastPathComponent,
                language: environment["DAISY_BENCHMARK_LANGUAGE"] ?? "",
                speakerCount: environment["DAISY_BENCHMARK_SPEAKER_COUNT"] ?? ""
            )
        } else if let data = try? Data(contentsOf: URL(fileURLWithPath: "/tmp/daisy-benchmark-request.plist")) {
            request = try PropertyListDecoder().decode(Request.self, from: data)
        } else {
            request = nil
        }
        guard let request else {
            return
        }

        let audioURL = URL(fileURLWithPath: request.audioPath).standardizedFileURL
        let outputURL = URL(fileURLWithPath: request.outputPath).standardizedFileURL
        let language = request.language.isEmpty ? nil : request.language
        let requestedSpeakers = Int(request.speakerCount)

        let samples = try #require(AudioArchiveDecoder.decodeToMono16k(urls: [audioURL]))
        #expect(!samples.isEmpty)

        FluidAudioNetworkGuard.engage()
        let loadStarted = Date()
        async let whisperLoad: Void = WhisperEngine.shared.ensureLoaded()
        async let diarizerLoad: Void = DiarizationEngine.shared.ensureLoaded()
        _ = await (whisperLoad, diarizerLoad)
        let modelLoadSeconds = Date().timeIntervalSince(loadStarted)
        #expect(WhisperEngine.shared.isReady)
        #expect(DiarizationEngine.shared.isAvailable)

        let processingStarted = Date()
        async let whisperSegments = WhisperEngine.shared.transcribe(
            samples: samples,
            language: language,
            profile: .full
        )
        async let diarization = DiarizationEngine.shared.diarizeFull(
            samples: samples,
            numSpeakers: requestedSpeakers
        )
        let (words, speakers) = try await (whisperSegments, diarization)
        let processingSeconds = Date().timeIntervalSince(processingStarted)

        let transcriptSegments = words.map { segment in
            TranscriptSegment(
                id: UUID(),
                startedAt: Date(timeIntervalSince1970: segment.start),
                text: segment.text,
                isFinal: true,
                source: .systemAudio,
                speakerId: nil,
                endSec: segment.end,
                startSec: segment.start
            )
        }
        let merged = DiarizationEngine.mergeBySpeaker(
            segments: transcriptSegments,
            diarization: speakers.spans
        )

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let output = Output(
            schemaVersion: 1,
            product: "Daisy",
            version: version,
            build: build,
            engine: "WhisperKit \(WhisperEngine.shared.modelID) + FluidAudio",
            language: language,
            audioPath: request.originalAudioName,
            audioSHA256: try sha256(audioURL),
            audioDurationSeconds: Double(samples.count) / 16_000,
            modelLoadSeconds: modelLoadSeconds,
            processingSeconds: processingSeconds,
            detectedSpeakers: Set(speakers.spans.map(\.speakerId)).count,
            requestedSpeakerCount: requestedSpeakers,
            diarizationSegments: speakers.spans.map {
                OutputDiarizationSegment(start: $0.startSec, end: $0.endSec, speaker: $0.speakerId)
            },
            segments: merged.map {
                OutputSegment(start: $0.startSec, end: $0.endSec, speaker: $0.speakerId, text: $0.text)
            }
        )

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(output).write(to: outputURL, options: .atomic)
        #expect(FileManager.default.fileExists(atPath: outputURL.path))
    }

    nonisolated private func sha256(_ url: URL) throws -> String {
        // CryptoKit is already available on every supported macOS release.
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
