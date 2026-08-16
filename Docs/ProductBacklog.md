# Daisy Product Backlog

## Extended ChatGPT subscription limits

**Status:** Backlog — not scheduled

When the Codex App Server returns these fields, extend the Home limits card
with conditional account details:

- Show the additional ChatGPT credit balance only when credits are available.
- Show the personal spend limit, current spend, remaining percentage, and reset
  date only when the account has an individual spend control configured.
- Do not estimate a remaining message count. Consumption varies with the model,
  context size, reasoning, tools, and task complexity, so the server-provided
  percentage and reset time are the reliable values.

Keep these details hidden for accounts where the server returns no credits or
no personal spend limit; an empty zero-value row would add noise rather than
useful information.

## Call quality review

**Status:** Backlog — not scheduled

Create a dedicated post-call review with four independent, explainable
assessments. Do not collapse them into a single opaque employee score.

### Assessment areas

1. **Speech and communication**
   - Pace and clarity
   - Filler words
   - Interruptions
   - Speaking/listening ratio
   - Quality of questions

2. **Progress against the meeting plan**
   - Agenda items completed
   - Agenda items skipped
   - Agenda items left unfinished

3. **Presentation quality**
   - Structure of the narrative
   - Clarity of arguments
   - Handling of questions
   - Visual slide quality only when screen recording or slide input is available

4. **Sales script coverage**
   - User-managed, versioned dialogue-script templates
   - Each stage marked as completed, partial, skipped, or not applicable

### Result requirements

- Show each assessment separately.
- Support every AI conclusion with transcript quotes and timestamps.
- Display model confidence and actionable recommendations.
- Distinguish observed metrics from subjective AI assessment.
- Allow a reviewer to inspect why a score was assigned.

### Dependencies

- Reliable speaker diarization for interruptions and speaking/listening ratio.
- A meeting agenda or goal for plan-progress assessment.
- Screen recording or attached slides for visual presentation assessment.
- Script-template settings and version history for sales-script assessment.

### Guardrails

- No single combined employee rating.
- Do not score accent, personality, or other traits unrelated to job performance.
- Employee-facing and manager-facing use must include appropriate consent,
  visibility, and data-retention controls.

## Local privacy filter before cloud AI

**Status:** MVP implemented — broader coverage and review UX remain in backlog

Add an optional local privacy boundary that transforms sensitive content before
it is sent to a remote summary or analysis provider. The product wording must
say **pseudonymization of detected sensitive data**, not promise complete
anonymity: entity detection has both false positives and false negatives, and
de-identified text can sometimes be re-identified from context.

### Implemented MVP

- An off-by-default global switch in Summary settings controls the feature.
- The shared summarizer boundary protects cloud requests while confirmed local
  providers continue receiving the original text.
- On-device detection covers people, organizations, emails, phone numbers,
  URLs, credentials/private keys/tokens, and payment-card numbers.
- People, organizations, and contact data use stable per-request reversible
  tokens; credentials and valid payment-card numbers remain irreversibly
  redacted after the result is restored.
- Title, transcript, and supported task metadata share one mapping, and every
  field of the decoded structured summary is restored locally.
- The mapping exists only in memory; diagnostics contain counts but no detected
  values.
- Settings explicitly state that the feature reduces disclosure risk and does
  not guarantee anonymity.

The remaining backlog includes pipelines that bypass the shared summarizer
(notably plan analysis and attendee web research), strict/custom profiles,
preview and correction UI, project/product/address/ID recognizers, and a
measured English/Russian evaluation corpus.

### Goals

- Keep the original transcript, meeting title, plans, briefs, and attachments
  on the Mac.
- Send a context-preserving pseudonymized copy to remote AI providers.
- Restore safe display names in the structured result before it is shown or
  saved.
- Never send the replacement dictionary, original entity values, or sensitive
  excerpts in logs or telemetry.
- Apply the same policy to every outbound AI feature, not only the standard
  meeting summary: re-summarization, pre-meeting briefs, plan analysis,
  transcript polishing, speaker-name suggestions, morning/catch-up briefs, and
  future call-quality analysis.

### Two protection classes

1. **Reversible pseudonyms for context-bearing entities**
   - People and participant names
   - Companies, customers, vendors, and organizations
   - Project, product, and confidential initiative names
   - Email addresses, phone numbers, URLs/domains, physical addresses, and
     internal account/customer identifiers
   - Replace consistently inside one request with typed tokens such as
     `[PERSON_1]`, `[ORG_1]`, and `[PROJECT_1]`.
   - Keep the mapping local and in memory for the request; restore tokens in
     every field of the structured AI response, including action-item owners,
     evidence quotes, and section text.

2. **Irreversible redaction for secrets and high-risk identifiers**
   - Passwords, API keys, access/refresh tokens, private keys, and connection
     strings
   - Payment-card and bank-account numbers
   - Government, tax, insurance, and similar identity numbers
   - Replace with typed non-restorable markers such as `[REDACTED_API_KEY]`.
     These values should not be reproduced in a summary even locally.

Dates, locations, financial amounts, health information, and job titles are
potential quasi-identifiers but can be essential to a useful summary. Put them
behind a stricter optional profile instead of removing them unconditionally.

### Processing pipeline

1. Determine whether the selected provider is local or remote. Skip the filter
   for a confirmed local provider; treat unknown MCP/custom endpoints as remote
   unless the user explicitly marks them trusted-local.
2. Run detection entirely on-device before the shared provider boundary.
   Combine deterministic recognizers (email, phone, payment data, credentials,
   IDs, URLs) with multilingual local named-entity recognition for people,
   organizations, places, projects, and aliases.
3. Resolve overlapping detections by risk and confidence, then create one
   stable per-request mapping. Repeated mentions and aliases must remain
   referentially consistent so the model can follow the conversation.
4. Transform every outbound field together — title, transcript, plan/script,
   brief context, OCR/screen text, and related task text — so the same entity
   receives the same token everywhere.
5. Send only the transformed payload. Instruct providers to copy pseudonym
   tokens exactly and validate that the response contains no unknown or altered
   tokens.
6. Restore reversible values locally in the decoded structured result. Keep
   irreversible secret markers redacted.
7. Discard the mapping when the request finishes. If durable retry state is
   later required, encrypt it separately with a Keychain-backed key and delete
   it after completion.

Place the first implementation at Daisy's shared summarizer/provider boundary
rather than independently inside each cloud adapter. Add equivalent boundaries
for pipelines that currently bypass the standard summarizer, especially plan
analysis and web-research briefs.

### Settings and review UX

- Global setting: **Protect sensitive data before cloud AI**.
- Profiles: Standard and Strict, plus per-entity toggles.
- Provider-aware explanation showing whether the current route stays local or
  leaves the Mac.
- Optional preview before sending: highlighted detections, entity type,
  confidence, and controls to keep, replace, or add a missed value.
- Per-request status such as “Protected 4 people, 2 companies, 1 email”; never
  include the detected values in diagnostics.
- Allow user-managed always-protect and never-protect dictionaries for company,
  product, and domain-specific vocabulary.
- Make protection visible but non-blocking for normal use. Block transmission
  only when a credential or other never-send secret is detected and cannot be
  safely redacted.

### Accuracy and safety requirements

- Support Russian and English from the first release; evaluate mixed-language
  transcripts separately.
- Preserve speaker labels, timestamps, Markdown structure, URLs needed as
  evidence, and prompt-injection fences.
- Do not let pseudonymization break evidence matching: restore evidence quotes
  before validating them against the local transcript, or validate against the
  transformed transcript and then restore deterministically.
- Never log original text, replacement mappings, sensitive spans, or provider
  responses that may echo the prompt.
- Show an explicit limitation that the filter reduces disclosure risk but does
  not guarantee anonymity.
- Measure precision and recall per entity type on a representative EN/RU test
  corpus before enabling the feature by default.

### Acceptance criteria

- A network-boundary integration test proves that selected original entities
  never reach a remote provider payload.
- Repeated entities and aliases receive stable pseudonyms within a request and
  different mappings across unrelated requests by default.
- The sum of all structured summary fields is restored without leaking raw
  placeholder tokens to the UI.
- Secrets remain redacted after result restoration.
- Overlapping spans, Unicode offsets, email/name collisions, possessives,
  inflected Russian names, titles, plans, retries, and provider errors have
  regression tests.
- Local providers receive the original text and do not pay the accuracy cost of
  unnecessary transformation.
- No raw entity value or mapping is written to UserDefaults, analytics, crash
  reports, or application logs.

### Research basis

- NISTIR 8053: de-identification reduces privacy risk but does not eliminate
  re-identification risk.
- NIST defines pseudonymization as replacing identifiers with pseudonyms to
  hide the data subject's identity.
- Microsoft Presidio separates detection from replace/redact/hash/encrypt
  operators and supports reversible deanonymization; it also documents the
  false-positive/false-negative trade-off and the need to manage stable mappings
  securely.
- OWASP recommends removing, masking, hashing, or encrypting PII, access tokens,
  passwords, database connection strings, and encryption keys rather than
  recording them directly.
