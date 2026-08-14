# Account-backed summary providers: QA matrix

This matrix is the release gate for DAISY-AUTH-18. Automated rows use mocked
processes and accounts; rows marked **Live** must be run with disposable test
accounts on a release-signed build. Never use a transcript containing customer
or production data.

## Automated coverage

| Scenario | ChatGPT / Codex | Cursor | Evidence |
| --- | --- | --- | --- |
| App installed / missing | Covered | Covered | Executable locator and account-manager tests |
| Signed in / signed out | Covered | Covered | Mock account-manager tests |
| Session expired | Covered | Covered | Provider-specific expired-session tests |
| Limit exhausted | Covered | Covered | Shared `limitReached` state tests |
| Unavailable saved model | Covered in shared UI | Covered in shared UI | Picker preserves the saved ID and labels it unavailable |
| Timeout / cancellation | Covered | Covered | Shared runner tests |
| Long transcript | Covered | Covered | Provider prompt tests preserve the complete input |
| Concurrent requests | Covered | Covered | Shared runner isolation test |
| Prompt injection | Covered | Covered | Provider boundary tests keep transcript text in untrusted input |
| Transcript absent from surfaced diagnostics | Covered | Covered | Shared runner and provider error-sanitization tests |
| File and shell restrictions | Empty folder, approvals/tools disabled | Empty folder, deny policy, no `--force` | Process-contract tests and security decision |

## Live release matrix

Run every row in English and Russian. Record the app version, macOS version,
provider client version, account plan, selected model, result, and a screenshot
with personal data hidden.

| Scenario | ChatGPT / Codex | Cursor account (Experimental) | Cursor API key |
| --- | --- | --- | --- |
| Client absent shows install guidance | Pending Live | Pending Live | Pending Live |
| Client installed but signed out | Pending Live | Pending Live | N/A |
| Complete browser sign-in | Pending Live | Pending Live | N/A |
| Cancel browser sign-in | Pending Live | Pending Live | N/A |
| Disconnect and reconnect | Pending Live | Pending Live | N/A |
| Start while offline | Pending Live | Pending Live | Pending Live |
| Exhausted or test-limited account | Pending Live | Pending Live | Pending Live |
| Previously selected model becomes unavailable | Pending Live | Pending Live | Pending Live |
| Quit Daisy during an active request | Pending Live | Pending Live | Pending Live |
| One-hour synthetic transcript | Pending Live | Pending Live | Pending Live |
| Transcript asks the agent to read/write a sentinel file | Pending Live | Pending Live | Pending Live |
| First-use cloud disclosure appears once | Pending Live | Pending Live | N/A |
| Request count, result and duration survive relaunch | Pending Live | Pending Live | N/A |

For the sentinel test, create a disposable file containing random test text.
The summary must not contain it, the file must remain byte-for-byte unchanged,
and no new files may remain in the request directory. Cursor account mode remains
Experimental even after this passes because Cursor does not document a switch
that disables every agent tool.

## Release exit criteria

- All Live rows pass on the oldest supported macOS and the current macOS.
- No raw provider diagnostics, credentials, or transcript fragments appear in
  Console, UI errors, crash reports, or retained temporary directories.
- Russian controls fit without truncating the account actions or warnings.
- A failed or cancelled request is counted as a request with its result, but no
  token or price estimate is shown for an account-backed request.

## Current workstation inventory (2026-08-14)

- ChatGPT's bundled Codex helper is installed at
  `/Applications/ChatGPT.app/Contents/Resources/codex` (`codex-cli
  0.147.0-alpha.6.5`).
- `Cursor.app` is installed, but the separate `cursor-agent` executable is not.
  Cursor live rows therefore require installing Cursor Agent CLI first.
- No live login, provider request, or quota-consuming test was run while
  preparing this matrix.
