# Security policy

Thank you for taking the time to look at Daisy's attack surface.

## Reporting a vulnerability

Email **essazanov@pm.me** with the subject prefixed `[SECURITY]`. Please do not file a public GitHub issue for vulnerabilities — disclose privately first, give time for a fix, then we can coordinate public disclosure together.

Helpful things to include:

- Affected Daisy version (Settings → About) and macOS version
- A clear description of the issue and its impact
- Steps to reproduce (a proof-of-concept is welcome)
- Whether you'd like to be credited in the changelog when the fix ships

You can expect a first response within **5 working days**. If the issue is confirmed, we'll agree on a disclosure timeline together — typically 30–90 days depending on severity.

## What's in scope

- **Local MCP HTTP listener** on `127.0.0.1`. Even though it binds loopback-only, the browser sandbox can reach it via `fetch`. Concrete attacks against the Origin / Host / CORS guards, request smuggling, or authentication bypass are all in scope.
- **Google OAuth flow.** The `client_secret` is intentionally public (PKCE loopback flow, see code comments), but issues around redirect URI handling, token storage in Keychain, or scope escalation are in scope.
- **Sparkle update channel.** The appcast endpoint, EdDSA signature verification, and the local update install path. Tampering paths that could deliver an unsigned or wrong-signed build to a user are in scope.
- **Sandbox bypass attempts.** Daisy is sandboxed with audio-input, calendar, network client/server, and user-selected files. Bypasses of those entitlements, or escalation to broader access, are in scope.
- **Local file / Keychain access.** Issues where another local process or another app on the same Mac could read Daisy's stored API keys, session transcripts, or audio files.
- **Audio capture path.** Cases where audio gets uploaded somewhere it shouldn't, including via system audio capture, screenshots, or telemetry.

## What's NOT in scope

- **Third-party LLM API keys leaking through normal use.** Anthropic / OpenAI / MCP keys live in the user's Keychain. When the user opts into cloud summaries, the transcript is sent to that provider over HTTPS — that's the documented behavior, not a vulnerability. The provider's own security is out of scope here.
- **Bugs that require physical access to an unlocked Mac.** Daisy assumes the OS user-session boundary is intact.
- **Self-DoS** (e.g. crashing the app by feeding it malformed local files via UI flows that only the local user can trigger).
- **Issues in dependencies** that don't have a meaningful exploit path through Daisy. Please report those upstream (Sparkle, WhisperKit, etc.).

## Hardening notes

Things that already exist in the codebase, so you can check them off your list:

- MCP server's CORS / Host / Origin guards (`MCPServer.swift`)
- Sparkle EdDSA public key pinned in `Info.plist` as `SUPublicEDKey`
- `os_log` privacy-level audit completed — secrets and transcripts log at `.private`
- App sandbox entitlements in `Daisy.entitlements`
- API keys stored in Keychain via `KeychainStore`, not `UserDefaults`

## PGP

Not currently. If you'd like to encrypt the report, request a key in your first email and we'll arrange one.
