//
//  MeetingPlanAnalysisPipeline.swift
//  Daisy
//

import Foundation
import Observation
import os

nonisolated struct MeetingPlanAnalysisPipeline: Sendable {
    struct Input: Sendable {
        let directory: URL
        let title: String
        let localeHint: String?
        let preparation: MeetingPreparationSnapshot
        let durationSeconds: Double
    }

    struct Response: Decodable {
        let items: [MeetingPlanItemAnalysis]
    }

    enum Result: Equatable {
        case unchanged(MeetingPlanAnalysis)
        case generated(MeetingPlanAnalysis)
    }

    let provider: any MeetingPlanAnalysisProviding

    func run(_ input: Input, force: Bool = false) async throws -> Result {
        guard !input.preparation.planItems.isEmpty else {
            throw MeetingPlanAnalysisValidationError.itemIDs
        }
        let evidenceIndex = try TranscriptEvidenceIndex.load(
            from: input.directory,
            fallbackDuration: input.durationSeconds
        )
        guard !evidenceIndex.segments.isEmpty else {
            throw MeetingPlanAnalysisValidationError.invalidEvidence(
                itemID: input.preparation.planItems.first?.id ?? "p1"
            )
        }
        let planHash = Self.planHash(input.preparation)
        let transcriptHash = MeetingPlanAnalysis.hash(evidenceIndex.transcript)
        if !force,
           let existing = MeetingPlanAnalysis.load(from: input.directory),
           existing.matches(planHash: planHash, transcriptHash: transcriptHash) {
            return .unchanged(existing)
        }

        let raw = try await provider.generate(
            developerInstructions: MeetingPlanAnalysisPrompt.developerInstructions(
                localeHint: input.localeHint
            ),
            userPrompt: MeetingPlanAnalysisPrompt.userPrompt(
                title: input.title,
                planItems: input.preparation.planItems,
                transcript: evidenceIndex.transcript,
                durationSeconds: evidenceIndex.durationSeconds
            ),
            schema: MeetingPlanAnalysisPrompt.schemaData
        )
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: raw)
        } catch {
            throw MeetingPlanAnalysisValidationError.invalidJSON
        }
        try MeetingPlanAnalysisValidator.validate(
            items: decoded.items,
            planItems: input.preparation.planItems,
            evidenceIndex: evidenceIndex
        )
        let byID = Dictionary(uniqueKeysWithValues: decoded.items.map { ($0.itemID, $0) })
        let ordered = input.preparation.planItems.compactMap { byID[$0.id] }
        let analysis = MeetingPlanAnalysis(
            schemaVersion: MeetingPlanAnalysis.currentSchemaVersion,
            promptVersion: MeetingPlanAnalysis.currentPromptVersion,
            planHash: planHash,
            transcriptHash: transcriptHash,
            generatedAt: Date(),
            items: ordered
        )
        try analysis.write(to: input.directory)
        try? FileManager.default.removeItem(
            at: input.directory.appendingPathComponent(MeetingPlanAnalysisErrorRecord.sidecarFilename)
        )
        return .generated(analysis)
    }

    static func planHash(_ preparation: MeetingPreparationSnapshot) -> String {
        let canonical = preparation.planItems.map { "\($0.id)\u{001F}\($0.text)" }
            .joined(separator: "\u{001E}")
        return MeetingPlanAnalysis.hash(canonical)
    }
}

@MainActor
@Observable
final class MeetingPlanAnalysisStore {
    enum State: Equatable {
        case idle
        case analyzing
        case ready(MeetingPlanAnalysis)
        case failed(String)
    }

    static let shared = MeetingPlanAnalysisStore()

    private(set) var states: [String: State] = [:]
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let log = Logger(
        subsystem: "app.essazanov.Daisy",
        category: "PlanAnalysis"
    )

    func state(for session: StoredSession) -> State {
        if let active = states[session.id] { return active }
        if let error = session.planAnalysisError { return .failed(error.message) }
        if let analysis = session.planAnalysis { return .ready(analysis) }
        return .idle
    }

    func analyzeIfNeeded(
        sessionID: String,
        directory: URL,
        title: String,
        localeHint: String?,
        preparation: MeetingPreparationSnapshot,
        durationSeconds: Double,
        force: Bool = false,
        provider: (any MeetingPlanAnalysisProviding)? = nil
    ) {
        guard !preparation.planItems.isEmpty else { return }
        guard tasks[sessionID] == nil else { return }
        states[sessionID] = .analyzing
        let selectedProvider = provider ?? Summarizer.shared.makeMeetingPlanAnalysisProvider()
        let input = MeetingPlanAnalysisPipeline.Input(
            directory: directory,
            title: title,
            localeHint: localeHint,
            preparation: preparation,
            durationSeconds: durationSeconds
        )
        tasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            defer { tasks[sessionID] = nil }
            do {
                let result = try await MeetingPlanAnalysisPipeline(provider: selectedProvider)
                    .run(input, force: force)
                let analysis: MeetingPlanAnalysis
                switch result {
                case .unchanged(let value), .generated(let value): analysis = value
                }
                states[sessionID] = .ready(analysis)
                await SessionStore.shared.reloadSession(id: sessionID)
            } catch is CancellationError {
                states[sessionID] = .idle
            } catch {
                let identity = Self.identity(for: input)
                let record = MeetingPlanAnalysisErrorRecord(
                    schemaVersion: MeetingPlanAnalysis.currentSchemaVersion,
                    promptVersion: MeetingPlanAnalysis.currentPromptVersion,
                    planHash: identity.planHash,
                    transcriptHash: identity.transcriptHash,
                    failedAt: Date(),
                    message: error.localizedDescription
                )
                let existing = MeetingPlanAnalysis.load(from: directory)
                if existing?.matches(
                    planHash: identity.planHash,
                    transcriptHash: identity.transcriptHash
                ) != true {
                    try? FileManager.default.removeItem(
                        at: directory.appendingPathComponent(MeetingPlanAnalysis.sidecarFilename)
                    )
                }
                try? record.write(to: directory)
                states[sessionID] = .failed(record.message)
                log.error("Plan analysis failed: \(record.message, privacy: .public)")
                await SessionStore.shared.reloadSession(id: sessionID)
            }
        }
    }

    func retry(for session: StoredSession) {
        guard let preparation = session.meetingPreparation else { return }
        analyzeIfNeeded(
            sessionID: session.id,
            directory: session.directoryURL,
            title: session.title,
            localeHint: session.locale,
            preparation: preparation,
            durationSeconds: Double(session.durationSec),
            force: true
        )
    }

    private static func identity(
        for input: MeetingPlanAnalysisPipeline.Input
    ) -> (planHash: String, transcriptHash: String) {
        let planHash = MeetingPlanAnalysisPipeline.planHash(input.preparation)
        let index = try? TranscriptEvidenceIndex.load(
            from: input.directory,
            fallbackDuration: input.durationSeconds
        )
        return (planHash, MeetingPlanAnalysis.hash(index?.transcript ?? ""))
    }
}
