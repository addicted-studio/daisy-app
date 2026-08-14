# Account-backed summary providers: staged release

This is the DAISY-AUTH-19 delivery plan after GitHub Copilot was parked.

## Stage 1 — foundation

Ship the provider-neutral connection preference, account-state protocol,
constrained process runner, canonical summary schema, migrations, and mocked
tests. Existing OpenAI users remain on API-key mode and keep their key and model.

## Stage 2 — ChatGPT / Codex first

Enable ChatGPT-account mode behind the OpenAI provider. Gate release on live
login/logout, model discovery, plan-limit display, structured summaries, and
the full QA matrix. Monitor sanitized failure categories and request success
rates only; do not collect transcript content or credentials.

## Stage 3 — Cursor Experimental

Enable Cursor API-key mode and opt-in account mode with the Experimental label.
Keep the documented deny policy, empty request directory, bounded process, and
no-`--force` invariant as release gates. Cursor account mode must be independently
disableable if client updates break the process contract.

## Stage 4 — final UX and localization

Release the shared API/account selector, shared account state rows, first-use
cloud disclosure, English/Russian strings, and local 28-day request accounting.
Account-backed usage shows provider/model/request count/duration/result and the
message “Included in subscription · uses provider limit”; it never estimates
tokens or price.

## Parked — GitHub Copilot

DAISY-AUTH-12 and DAISY-AUTH-13 are intentionally excluded. Resume only after
the SDK distribution restriction documented in
`GitHubCopilotTechnicalDecision.md` is cleared and the internal prototype passes
its acceptance gate.

## Rollback

The existing API-key blocks remain the compatibility path. If an account route
must be disabled, force only that provider's connection selector back to API key;
do not delete stored API keys, API models, account-model preferences, or usage
history. Cursor can be disabled independently from ChatGPT / Codex.
