//
//  ClientSuggestion.swift
//  Daisy
//
//  Best-effort inference of "which client is this meeting with?"
//  from a calendar event's attendee email list. Pure function, no
//  side effects — call once at session start (in RecordingSession)
//  with the bound DaisyMeeting; result is either a normalised
//  client name (`"Mediacube"`) or nil (no clear external client).
//
//  Heuristic — not magic:
//   • Strip free-mail domains (gmail, outlook, yahoo, icloud…) since
//     personal addresses don't identify a client organisation.
//   • Count remaining domains across all attendees.
//   • Pick the most frequent. Ties broken by first-appearance order
//     in the attendees list (stable across re-runs of the same
//     event).
//   • Normalise the winning domain to a display name: strip TLD,
//     strip "www" / "mail" / "calendar" subdomains, title-case the
//     first label. `mediacube.io` → "Mediacube", `acme.co.uk` →
//     "Acme".
//
//  Self-detection (skipping the user's own domain) is intentionally
//  NOT done here — EventKit's `isCurrentUser` flag is unreliable on
//  EKParticipant, and inferring "self" from the organizer field
//  guesses wrong for shared mailboxes. The dominant-domain
//  heuristic naturally handles the common "1 internal + 3 external"
//  meeting by picking the external side, since the external side
//  outnumbers the user.
//

import Foundation

enum ClientSuggestion {

    /// Best-effort inference. Returns nil when no usable signal
    /// (no attendees, only free-mail addresses, attendee list
    /// empty). Empty string never returned — caller can treat nil
    /// as "leave the client tag empty, don't pre-fill".
    static func suggest(from emails: [String]) -> String? {
        guard !emails.isEmpty else { return nil }

        // Extract domain part of each email, in input order.
        var orderedDomains: [String] = []
        var counts: [String: Int] = [:]
        for raw in emails {
            guard let domain = extractDomain(from: raw) else { continue }
            guard !isFreeMailDomain(domain) else { continue }
            counts[domain, default: 0] += 1
            if !orderedDomains.contains(domain) {
                orderedDomains.append(domain)
            }
        }
        guard !counts.isEmpty else { return nil }

        // Pick most frequent. Tie-breaker: first appearance in
        // attendees list. We walk the ordered list and pick the
        // first one whose count equals the max.
        let maxCount = counts.values.max() ?? 0
        guard let winningDomain = orderedDomains.first(where: { counts[$0] == maxCount }) else {
            return nil
        }

        return normalizeDisplayName(domain: winningDomain)
    }

    // MARK: - Internals

    /// Pull the lowercased domain part out of an email address.
    /// Returns nil for malformed inputs.
    static func extractDomain(from email: String) -> String? {
        let trimmed = email.lowercased().trimmingCharacters(in: .whitespaces)
        guard let atIdx = trimmed.firstIndex(of: "@") else { return nil }
        let domain = String(trimmed[trimmed.index(after: atIdx)...])
        guard !domain.isEmpty, domain.contains(".") else { return nil }
        return domain
    }

    /// True if `domain` is one of the well-known free-mail providers
    /// — personal addresses that don't identify a client org and
    /// shouldn't drive the suggestion.
    static func isFreeMailDomain(_ domain: String) -> Bool {
        return freeMailDomains.contains(domain)
    }

    /// Convert a domain to a display-friendly client name.
    /// Examples:
    ///   "mediacube.io"        → "Mediacube"
    ///   "acme.co.uk"          → "Acme"
    ///   "owls-group.com"      → "Owls-group"
    ///   "mail.mydaisy.io"     → "Mydaisy"   (subdomain stripped)
    ///   "calendar.google.com" → would never reach here (free-mail)
    static func normalizeDisplayName(domain: String) -> String {
        // Strip common service-y subdomains so "mail.acme.io" becomes
        // "Acme", not "Mail".
        var parts = domain.split(separator: ".").map(String.init)
        while let first = parts.first,
              subdomainsToStrip.contains(first),
              parts.count > 1 {
            parts.removeFirst()
        }
        // First label is the organisation name.
        guard let stem = parts.first, !stem.isEmpty else { return domain }
        return titleCase(stem)
    }

    /// "mediacube" → "Mediacube", "owls-group" → "Owls-group".
    /// Capitalise only the very first letter so multi-word slugs
    /// like "owls-group" don't end up as "Owls-Group" (looks
    /// over-formatted).
    private static func titleCase(_ s: String) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased() + s.dropFirst()
    }

    /// Subdomain labels stripped before title-casing — these are
    /// usually service-level prefixes, not the organisation name.
    private static let subdomainsToStrip: Set<String> = [
        "www", "mail", "calendar", "smtp", "imap", "email", "mx",
    ]

    /// Free-mail provider domains skipped during suggestion. Not
    /// exhaustive — sticks to the obvious set; weird regional
    /// providers will sneak through and pollute one suggestion
    /// before the user fixes it manually. Acceptable cost.
    private static let freeMailDomains: Set<String> = [
        "gmail.com", "googlemail.com",
        "outlook.com", "hotmail.com", "live.com", "msn.com",
        "yahoo.com", "yahoo.co.uk", "yahoo.co.jp", "ymail.com",
        "icloud.com", "me.com", "mac.com",
        "proton.me", "protonmail.com", "pm.me",
        "fastmail.com", "fastmail.fm",
        "aol.com",
        "yandex.ru", "yandex.com", "ya.ru",
        "mail.ru", "bk.ru", "inbox.ru", "list.ru",
        "qq.com", "163.com", "126.com",
        "tutanota.com", "tutanota.de",
        "gmx.com", "gmx.de",
        "zoho.com",
    ]
}
