# Design — client tagging for Daisy sessions

> **Status:** proposal for 1.0.6.
> **Trigger:** 2026-05-21 Granola comparison highlighted that Granola
> groups sessions by client in the sidebar — useful when you have
> 20+ meetings to scan back through. Egor's constraint: **no separate
> Client entity, no CRM-ification**. Folder semantics already cover
> "Work / Personal / Calls"; client is one more axis on top.

## TL;DR

A new optional `client` string on each session. Auto-suggested from
the dominant attendee email domain when the session has a calendar
binding. Stored in frontmatter, surfaced as a chip in History, and
usable as a filter alongside the existing folder filter.

No new entities. No CRM table. No "Client management UI". The
filename of an Obsidian note stays the source of truth.

## Why not a separate Client entity

- Forces user maintenance ("oops, my CRM and my session folder are
  out of sync")
- Doubles the surface area for state Daisy has to keep consistent
- Granola has it — and it's the single most "feature-creep" surface
  of their app, judging by their support traffic
- 80% of the value comes from "let me filter History by client" —
  that's a tag, not an entity

## Data model

### Frontmatter

Add one new key alongside the existing `daisy_folder`:

```yaml
daisy_client: "Acme Inc"
```

- Empty / missing → "no client tagged". UI shows the session under
  "Untagged" group when client-filter is engaged.
- Free-form string. No normalization, no canonical list. User can
  type "Acme", "Acme Inc", "ACME" — three different tags, three
  different filter values. That's accepted UX cost — pretending we
  know better than the user about how their clients should be
  named is a worse failure mode.

### AppSettings — none

Tags live on the session, not on user prefs. No additional
UserDefaults keys.

### StoredSession

New field:

```swift
struct StoredSession {
    // ...existing...
    let client: String   // empty == untagged
}
```

Parsed from `daisy_client:` in `parseFrontmatter` (existing
function in SessionStore). Empty default for sessions saved before
1.0.6 — clean migration, no schema bump.

## Auto-suggestion (the smart bit)

At session start when `boundMeeting != nil`:

1. Look at `boundMeeting.attendees` (array of names captured from
   EKEvent / Google Calendar).
2. Cross-reference with attendee EMAIL DOMAINS (need to extend
   `DaisyMeeting.attendeeEmails: [String]` — currently we only
   project names).
3. Drop:
   - The user's own domain (inferred from the EventKit "default"
     account, or from the first attendee marked as organizer's
     own domain — heuristic, will be wrong for shared inboxes).
   - Free-mail domains (gmail.com, outlook.com, icloud.com, etc.
     — hardcoded short blocklist).
4. The remaining most-frequent domain becomes the suggestion. e.g.
   3 attendees from `@mediacube.io`, 1 from `@owlsgroup.io`, user
   is on `@mydomain.com` → suggestion = "mediacube" (strip TLD,
   title-case → "Mediacube").
5. Suggestion is written to `pendingClientSuggestion`, NOT directly
   to `session.client`. UI surfaces it as a confirmable chip
   ("Client: Mediacube · change") with one click to dismiss /
   replace.

### Why dominant-attendee-domain instead of meeting title or location

Tested on the Garna-Mediacube recording: meeting title was
"Owls' Group | Garna" — too noisy to parse reliably ("|" delimiter
is convention, not contract). Attendee domain is structurally
clean.

## UI surfaces

### HistoryView sidebar

Reuse the existing folder sidebar pattern, add a second section
below folders:

```
┌─────────────────┐
│ FOLDERS         │
│   Inbox        12│
│   Work         34│
│   Notes         5│
│                  │
│ CLIENTS         │
│   Mediacube     6│
│   Acme Inc      3│
│   Owls' Group   2│
│   Untagged      4│
└─────────────────┘
```

- Click a client → filter sessions list to that client (intersect
  with current folder filter if any).
- Counts update live as sessions tagged / untagged / deleted.
- No drag-drop reorder. Sorted by count desc, then alphabetically.

### Session row in History list

If `session.client.nonEmpty`, show a small chip after the title:

```
Mediacube Q3 review                    [Mediacube]  Today 14:30
```

Chip color matches the inferred client's "calendar color" if
available (`daisy_event_color` would need to flow from
`DaisyMeeting.calendarColorHex` into the session frontmatter —
already wired for events, not yet for client chips).

### Session detail header

Editable text field under the title for `client`. Empty placeholder:
"Add client tag…". Auto-completes against previously-seen client
names (cheap — read distinct values from StoredSession cache).

## Edge cases

- **Multiple meetings, same calendar event recurring**: same auto-
  suggestion fires each time, idempotent. User sees the chip pre-
  filled, doesn't have to do anything.
- **Internal team meeting (no external domain)**: suggestion path
  returns nil. No chip shown. User can type one manually if they
  want to group internal meetings ("Engineering all-hands").
- **Manual override of suggestion**: user-typed value wins forever.
  The auto-suggestion is fire-once at session start, not a
  recurring overwrite.
- **Renaming a client**: out of scope for 1.0.6. User has to bulk-
  edit frontmatter in their text editor if they want to consolidate
  "ACME" → "Acme Inc". Future feature: right-click on sidebar
  client → Rename across all sessions.

## Out of scope (explicit non-goals)

- No client profiles ("notes on this client", "last contact date").
- No CRM features (deal stage, pipeline value).
- No client-level analytics.
- No client-aware summarization (passing prior session context into
  the LLM prompt).
- No team sharing of client tags across users (Daisy is local).

These belong in a CRM, not Daisy.

## Implementation cost estimate

- `AppSettings` — 0 changes
- `AppSettings + DaisyMeeting + StoredSession + SessionStore` —
  ~30 LOC for frontmatter round-trip
- `RecordingSession` — ~25 LOC for auto-suggest pipeline + apply on
  bind
- `LibraryView` — ~80 LOC for client sidebar section + filter
  intersect
- `SessionDetailView` — ~30 LOC for editable client field
- Tests — 4 unit tests (suggestion logic, blocklist, frontmatter
  parse, filter intersect)

Total: ~165 LOC + 4 tests. Half a day's work end-to-end.

## Open questions to confirm before implementing

1. Free-mail domain blocklist — hardcode in app, or settings-
   editable? Default hardcode, no UI.
2. Multi-client sessions — what if 3 attendees from Acme and 2
   from Beta? Pick most frequent. If tied, pick the one whose
   domain appears first in the event's attendees list (stable).
3. Display name normalization — strip ".io", ".com" from domain,
   title-case the first part. "mydaisy.io" → "Mydaisy". Acceptable.
4. Auto-suggest on calendar-bound voice notes? Probably no — voice
   notes are personal, client tagging doesn't fit. Gate the
   suggestion on `currentMode == .meeting`.
