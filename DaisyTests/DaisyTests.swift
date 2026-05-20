//
//  DaisyTests.swift
//  DaisyTests
//
//  Pure-function smoke suite. Locks in the highest-bug-yield logic
//  surfaces the pre-1.0.3 audit recommended. No async, no UI, no
//  network — each test is a few-millisecond pure unit assertion.
//

import Testing
import Foundation
@testable import Daisy

@Suite("Smoke suite (pure-function regression locks)")
struct DaisyTests {

    // MARK: - resolveSummaryLocaleHint precedence
    //
    // 1.0.3 flipped precedence: explicit picker wins over content
    // detection. This test pins that contract so a future refactor
    // doesn't silently restore detection-first behaviour and
    // recreate the "I picked Polish, why is it Russian?" UX bug.

    @Test("Explicit picker beats content detection")
    func summaryLocaleHint_explicitPickerWins() {
        let hint = RecordingSession.resolveSummaryLocaleHint(
            transcript: "Спасибо за встречу. Передам команде вашу позицию по бюджету и срокам. Завтра пришлю комментарии.",
            transcriptLocale: "ru-RU",
            summaryLanguageOverride: "pl"
        )
        #expect(hint == "pl")
    }

    @Test("Auto + content detection returns detected language")
    func summaryLocaleHint_autoUsesDetector() {
        let hint = RecordingSession.resolveSummaryLocaleHint(
            transcript: "Спасибо за встречу. Передам команде вашу позицию по бюджету и срокам. Завтра пришлю комментарии.",
            transcriptLocale: "auto",
            summaryLanguageOverride: SummaryLanguage.auto.id
        )
        #expect(hint == "ru")
    }

    @Test("Empty transcript with explicit picker still returns picker")
    func summaryLocaleHint_emptyTranscriptStillRespectsPicker() {
        let hint = RecordingSession.resolveSummaryLocaleHint(
            transcript: "",
            transcriptLocale: "auto",
            summaryLanguageOverride: "de"
        )
        #expect(hint == "de")
    }

    // MARK: - CloudSummaryDTO decode tolerance
    //
    // Pre-1.0.3 the decoder threw keyNotFound the moment Sonnet
    // emitted {"lede": "...", "sections": [...]}. 1.0.3 added
    // alias remapping + balanced-brace JSON extraction. These tests
    // pin that tolerance.

    @Test("Decodes the canonical schema cleanly")
    func cloudDTO_decodeCanonical() throws {
        let json = """
        {
          "summary": "Sales call with Altabel.",
          "sections": [
            {
              "title": "Pricing",
              "bullets": [
                { "text": "Monthly subscription with included credits", "children": [] }
              ]
            }
          ],
          "actionItems": ["Maria: send the contract by Thursday"],
          "clientFollowUp": "Thanks for the call..."
        }
        """
        let dto = try CloudSummaryDTO.decode(from: json)
        let summary = dto.toMeetingSummary()
        #expect(summary.summary == "Sales call with Altabel.")
        #expect(summary.sections.count == 1)
        #expect(summary.sections.first?.title == "Pricing")
        #expect(summary.actionItems.count == 1)
        #expect(summary.actionItems.first?.hasPrefix("Maria") == true)
    }

    @Test("Decodes 'lede' alias as summary")
    func cloudDTO_aliasLedeBecomesSummary() throws {
        let json = """
        {
          "lede": "Pricing call recap.",
          "outline": [],
          "action_items": [],
          "follow_up": ""
        }
        """
        let dto = try CloudSummaryDTO.decode(from: json)
        let summary = dto.toMeetingSummary()
        #expect(summary.summary == "Pricing call recap.")
    }

    @Test("Strips Markdown fences and trailing prose")
    func cloudDTO_stripFencesAndTrailingProse() throws {
        let json = """
        Here is the meeting summary:

        ```json
        {
          "summary": "Test.",
          "sections": [],
          "actionItems": [],
          "clientFollowUp": ""
        }
        ```

        Hope that helps!
        """
        let dto = try CloudSummaryDTO.decode(from: json)
        #expect(dto.toMeetingSummary().summary == "Test.")
    }

    // MARK: - RecordingSession.folderAllowed
    //
    // Auto-send folder allow-list. Empty set means "any folder";
    // non-empty restricts. Used by both Notion and MCP auto-send
    // paths. If this regresses, sessions silently route to the
    // wrong destination or get blocked.

    @Test("Empty allow-list permits every folder")
    func folderAllowed_emptyAllowsAll() {
        #expect(RecordingSession.folderAllowed("work", allowed: []) == true)
        #expect(RecordingSession.folderAllowed("personal", allowed: []) == true)
        #expect(RecordingSession.folderAllowed("notes", allowed: []) == true)
    }

    @Test("Non-empty allow-list restricts to listed slugs")
    func folderAllowed_restrictsToListed() {
        let allowed: Set<String> = ["work", "client-x"]
        #expect(RecordingSession.folderAllowed("work", allowed: allowed) == true)
        #expect(RecordingSession.folderAllowed("client-x", allowed: allowed) == true)
        #expect(RecordingSession.folderAllowed("personal", allowed: allowed) == false)
        #expect(RecordingSession.folderAllowed("notes", allowed: allowed) == false)
    }

    // MARK: - LanguageDetector confidence + scope gating
    //
    // Pinned because hallucinated language detection on short or
    // mixed text is what triggers the "summary came back in
    // Japanese" class of bugs. The detector intentionally returns
    // nil below threshold so the fallback path runs.

    @Test("Sub-16-char input returns nil")
    func languageDetector_tooShortReturnsNil() {
        #expect(LanguageDetector.detect("hi") == nil)
        #expect(LanguageDetector.detect("привет!") == nil)
    }

    @Test("Confident Russian detection")
    func languageDetector_clearRussianReturnsRu() {
        let detected = LanguageDetector.detect(
            "Спасибо за встречу. Передам команде вашу позицию по бюджету. Завтра пришлю комментарии."
        )
        #expect(detected == "ru")
    }

    @Test("Confident English detection")
    func languageDetector_clearEnglishReturnsEn() {
        let detected = LanguageDetector.detect(
            "Thanks for jumping on the call. I'll send the budget breakdown by Thursday morning."
        )
        #expect(detected == "en")
    }

    // MARK: - SummaryLabels localisation
    //
    // The UI structural headers (Meeting / Next actions / Follow-up
    // for client / partner) follow the summary language. 1.0.2
    // shipped this for 11 languages — pin so a future refactor
    // doesn't silently revert one of the translations.

    @Test("Russian labels match expected Cyrillic")
    func summaryLabels_russianMatch() {
        let labels = SummaryLabels.for(language: "ru")
        #expect(labels.meeting == "Встреча")
        #expect(labels.nextActions == "Следующие шаги")
        #expect(labels.followUp == "Ответ клиенту / партнёру")
    }

    @Test("Unknown / nil language falls through to English")
    func summaryLabels_unknownReturnsEnglish() {
        let labels1 = SummaryLabels.for(language: nil)
        let labels2 = SummaryLabels.for(language: "xx-XX")
        let labels3 = SummaryLabels.for(language: "auto")
        for labels in [labels1, labels2, labels3] {
            #expect(labels.meeting == "Meeting")
            #expect(labels.nextActions == "Next actions")
            #expect(labels.followUp == "Follow-up for client / partner")
        }
    }
}
