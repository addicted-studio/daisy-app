//
//  SensitiveDataProtector.swift
//  Daisy
//
//  Local, per-request privacy transform for cloud summary providers.
//  Context-bearing entities receive reversible typed pseudonyms; secrets and
//  payment-card numbers are redacted irreversibly. The replacement dictionary
//  never leaves this value and is discarded after the provider reply is
//  restored.
//

import Foundation
import NaturalLanguage

nonisolated enum SensitiveEntityKind: String, Sendable, CaseIterable {
    case person = "PERSON"
    case organization = "ORG"
    case email = "EMAIL"
    case phone = "PHONE"
    case url = "URL"
    case secret = "SECRET"
    case paymentCard = "PAYMENT_CARD"

    var isReversible: Bool {
        self != .secret && self != .paymentCard
    }
}

nonisolated struct SensitiveDataProtectionReport: Sendable, Equatable {
    let distinctReplacements: Int
    let redactedOccurrences: Int
}

/// The only object allowed to carry the local token → original dictionary.
/// It is a value type, is never encoded, and is intended to live only across
/// one provider request.
nonisolated struct ProtectedSummaryRequest: Sendable {
    let transcript: String
    let title: String
    let task: SummaryTask
    let report: SensitiveDataProtectionReport

    fileprivate let originalsByToken: [String: String]

    func restore(_ summary: MeetingSummary) -> MeetingSummary {
        MeetingSummary(
            summary: restore(summary.summary),
            sections: summary.sections.map { section in
                SummarySection(
                    title: restore(section.title),
                    bullets: section.bullets.map(restore)
                )
            },
            actionItems: summary.actionItems.map(restore),
            clientFollowUp: restore(summary.clientFollowUp)
        )
    }

    private func restore(_ bullet: SummaryBullet) -> SummaryBullet {
        SummaryBullet(
            text: restore(bullet.text),
            children: bullet.children.map(restore)
        )
    }

    private func restore(_ text: String) -> String {
        originalsByToken.reduce(text) { restored, pair in
            restored.replacingOccurrences(of: pair.key, with: pair.value)
        }
    }
}

nonisolated enum SensitiveDataProtector {
    static func shouldProtect(enabled: Bool, providerIsLocal: Bool) -> Bool {
        enabled && !providerIsLocal
    }

    static func protect(
        transcript: String,
        title: String,
        task: SummaryTask,
        detectNamedEntities: Bool = true
    ) -> ProtectedSummaryRequest {
        var context = Context(detectNamedEntities: detectNamedEntities)

        // Task context first: canonical attendee/company names from calendar
        // metadata become the stable mapping that shorter transcript mentions
        // can reuse.
        let protectedTask = context.protect(task: task)
        let protectedTitle = context.protect(title)
        let protectedTranscript = context.protect(transcript)

        return ProtectedSummaryRequest(
            transcript: protectedTranscript,
            title: protectedTitle,
            task: protectedTask,
            report: SensitiveDataProtectionReport(
                distinctReplacements: context.originalsByToken.count,
                redactedOccurrences: context.redactedOccurrences
            ),
            originalsByToken: context.originalsByToken
        )
    }

    // MARK: - Per-request state

    private struct Context {
        let detectNamedEntities: Bool
        var tokenByEntity: [String: String] = [:]
        var originalsByToken: [String: String] = [:]
        var counters: [SensitiveEntityKind: Int] = [:]
        var personAliases: [String: String] = [:]
        var ambiguousPersonAliases: Set<String> = []
        var redactedOccurrences = 0

        mutating func protect(task: SummaryTask) -> SummaryTask {
            switch task {
            case .meeting:
                return task
            case .preMeetingBrief(let info):
                return .preMeetingBrief(
                    SummaryPrompt.BriefPromptInfo(
                        meetingTitle: protect(info.meetingTitle),
                        attendees: info.attendees.map { protect($0) },
                        lastMetPhrase: info.lastMetPhrase.map { protect($0) },
                        includesWebContext: info.includesWebContext
                    )
                )
            case .voiceProfile, .catchUp, .morningBrief:
                return task
            case .dictationPolish(let instruction):
                return .dictationPolish(instruction: protect(instruction))
            case .transcriptPolish(let context):
                return .transcriptPolish(
                    TranscriptPolisher.PromptContext(
                        attendees: context.attendees.map { protect($0) },
                        vocabulary: context.vocabulary.map { protect($0) },
                        meetingApp: context.meetingApp.map { protect($0) }
                    )
                )
            case .speakerNames(let context):
                return .speakerNames(
                    SpeakerNameSuggester.PromptContext(
                        attendees: context.attendees.map { protect($0) },
                        labels: context.labels
                    )
                )
            }
        }

        mutating func protect(_ text: String) -> String {
            guard !text.isEmpty else { return text }
            let source = text as NSString
            var candidates = structuredCandidates(in: text)
            if detectNamedEntities {
                candidates.append(contentsOf: namedEntityCandidates(in: text))
            }
            let selected = nonOverlapping(candidates)
                .sorted { $0.range.location > $1.range.location }
            guard !selected.isEmpty else { return text }

            let result = NSMutableString(string: text)
            for candidate in selected {
                let original = source.substring(with: candidate.range)
                let replacement: String
                if candidate.kind.isReversible {
                    replacement = token(for: candidate.kind, original: original)
                } else {
                    redactedOccurrences += 1
                    replacement = "[[REDACTED_\(candidate.kind.rawValue)]]"
                }
                result.replaceCharacters(in: candidate.range, with: replacement)
            }
            return result as String
        }

        private mutating func token(for kind: SensitiveEntityKind, original: String) -> String {
            let normalized = Self.normalize(original)
            let key = "\(kind.rawValue)|\(normalized)"
            if let existing = tokenByEntity[key] { return existing }
            if kind == .person,
               !ambiguousPersonAliases.contains(normalized),
               let alias = personAliases[normalized] {
                tokenByEntity[key] = alias
                return alias
            }

            let next = (counters[kind] ?? 0) + 1
            counters[kind] = next
            let token = String(format: "[[DAISY_%@_%03d]]", kind.rawValue, next)
            tokenByEntity[key] = token
            originalsByToken[token] = original

            if kind == .person {
                registerPersonAliases(original: original, token: token)
            }
            return token
        }

        private mutating func registerPersonAliases(original: String, token: String) {
            let pieces = original.split { !$0.isLetter && !$0.isNumber }
                .map { Self.normalize(String($0)) }
                .filter { $0.count >= 3 }
            guard pieces.count > 1 else { return }
            for alias in pieces {
                if let existing = personAliases[alias], existing != token {
                    personAliases.removeValue(forKey: alias)
                    ambiguousPersonAliases.insert(alias)
                } else if !ambiguousPersonAliases.contains(alias) {
                    personAliases[alias] = token
                }
            }
        }

        private static func normalize(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // MARK: Detection

        private func structuredCandidates(in text: String) -> [Candidate] {
            var result: [Candidate] = []
            result += matches(Self.secretURLRegex, in: text, kind: .secret, priority: 120)
            result += matches(Self.privateKeyRegex, in: text, kind: .secret, priority: 115)
            result += matches(Self.credentialRegex, in: text, kind: .secret, priority: 110)
            result += matches(Self.openAIKeyRegex, in: text, kind: .secret, priority: 108)
            result += matches(Self.githubTokenRegex, in: text, kind: .secret, priority: 108)
            result += matches(Self.jwtRegex, in: text, kind: .secret, priority: 108)

            for match in Self.paymentCardRegex.matches(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length)
            ) {
                let value = (text as NSString).substring(with: match.range)
                let digits = value.filter(\.isNumber)
                if (13...19).contains(digits.count), Self.passesLuhn(digits) {
                    result.append(Candidate(range: match.range, kind: .paymentCard, priority: 100))
                }
            }

            result += matches(Self.emailRegex, in: text, kind: .email, priority: 90)
            result += matches(Self.urlRegex, in: text, kind: .url, priority: 85)
            result += matches(Self.phoneRegex, in: text, kind: .phone, priority: 80)
            return result
        }

        private func namedEntityCandidates(in text: String) -> [Candidate] {
            let tagger = NLTagger(tagSchemes: [.nameType])
            tagger.string = text
            var result: [Candidate] = []
            let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
            tagger.enumerateTags(
                in: text.startIndex..<text.endIndex,
                unit: .word,
                scheme: .nameType,
                options: options
            ) { tag, range in
                let kind: SensitiveEntityKind?
                switch tag {
                case .personalName: kind = .person
                case .organizationName: kind = .organization
                default: kind = nil
                }
                if let kind {
                    let nsRange = NSRange(range, in: text)
                    if nsRange.length >= 2 {
                        result.append(
                            Candidate(
                                range: nsRange,
                                kind: kind,
                                priority: kind == .person ? 55 : 50
                            )
                        )
                    }
                }
                return true
            }
            return result
        }

        private func matches(
            _ regex: NSRegularExpression,
            in text: String,
            kind: SensitiveEntityKind,
            priority: Int
        ) -> [Candidate] {
            regex.matches(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length)
            ).map { Candidate(range: $0.range, kind: kind, priority: priority) }
        }

        private func nonOverlapping(_ candidates: [Candidate]) -> [Candidate] {
            let ranked = candidates.sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                if $0.range.length != $1.range.length { return $0.range.length > $1.range.length }
                return $0.range.location < $1.range.location
            }
            var selected: [Candidate] = []
            for candidate in ranked where candidate.range.length > 0 {
                guard !selected.contains(where: {
                    NSIntersectionRange($0.range, candidate.range).length > 0
                }) else { continue }
                selected.append(candidate)
            }
            return selected
        }

        private struct Candidate {
            let range: NSRange
            let kind: SensitiveEntityKind
            let priority: Int
        }

        // MARK: Recognizers

        private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
            // Patterns are compile-time constants covered by unit tests.
            try! NSRegularExpression(pattern: pattern, options: options)
        }

        private static let secretURLRegex = regex(
            #"(?i)https?://[^\s<>()]*(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password)=[^\s<>()&]+[^\s<>()]*"#
        )
        private static let privateKeyRegex = regex(
            #"-----BEGIN(?: [A-Z0-9]+)? PRIVATE KEY-----[\s\S]*?-----END(?: [A-Z0-9]+)? PRIVATE KEY-----"#
        )
        private static let credentialRegex = regex(
            #"(?i)\b(?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|password|passwd|client[_ -]?secret)\b\s*[:=]\s*[\"']?[^\s,;\"']{8,}"#
        )
        private static let openAIKeyRegex = regex(#"\bsk-[A-Za-z0-9_-]{20,}\b"#)
        private static let githubTokenRegex = regex(#"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#)
        private static let jwtRegex = regex(#"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#)
        private static let paymentCardRegex = regex(#"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#)
        private static let emailRegex = regex(
            #"(?i)(?<![A-Z0-9._%+-])[A-Z0-9._%+-]+@[A-Z0-9-]+(?:\.[A-Z0-9-]+)+(?=$|[^A-Z0-9-])"#
        )
        private static let urlRegex = regex(#"(?i)https?://[^\s<>()]+"#)
        private static let phoneRegex = regex(#"(?<![\p{L}\d])\+?\d[\d ()-]{6,}\d(?![\p{L}\d])"#)

        private static func passesLuhn(_ digits: String) -> Bool {
            let values = digits.compactMap(\.wholeNumberValue)
            guard values.count == digits.count else { return false }
            let sum = values.reversed().enumerated().reduce(0) { total, item in
                let (offset, digit) = item
                guard offset.isMultiple(of: 2) == false else { return total + digit }
                let doubled = digit * 2
                return total + (doubled > 9 ? doubled - 9 : doubled)
            }
            return sum.isMultiple(of: 10)
        }
    }
}
