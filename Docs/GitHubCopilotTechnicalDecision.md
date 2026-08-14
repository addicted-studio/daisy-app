# GitHub Copilot integration technical decision

Status: **Proposed for an internal prototype only** (DAISY-AUTH-11).

## Decision

Daisy should use a bundled, signed Go helper built on the official GitHub
Copilot SDK. It must not depend on a separately installed `copilot` or `gh`
executable.

The helper uses the SDK's default child-process transport: the SDK talks JSON-RPC
over stdio to a pinned Copilot CLI runtime. The experimental in-process transport
is out of scope. The official Go bundler embeds a compatible runtime in the
helper, so a release has one versioned integration boundary and no system `PATH`
fallback.

The helper is packaged inside `Daisy.app/Contents/Helpers`, signed before the
outer app bundle, and launched directly without a shell. The SDK version, CLI
runtime version, archive checksum, license, and notices are pinned in the build.
A clean-machine codesign, notarization, first-launch extraction, and Gatekeeper
test is a release gate.

Local discovery on 2026-08-14 found neither `copilot` nor `gh` installed. Requiring
an installed CLI would therefore add setup friction and allow SDK/CLI version
skew without improving the security boundary.

## GitHub OAuth and credentials

Daisy registers a GitHub App with device flow enabled. Device flow is suitable
for desktop applications and requires only the public client ID, not a client
secret or callback backend:

1. Daisy requests a device code and shows GitHub's verification URL and user code.
2. Daisy polls no faster than GitHub's returned interval and handles `slow_down`,
   denial, expiry, cancellation, and network errors.
3. The access token, optional refresh token, and their expirations are stored only
   in macOS Keychain under a Daisy-owned service. Non-secret account metadata may
   be stored in app settings.
4. Daisy passes the current access token to the helper through its private stdin
   protocol, never through arguments, the environment, stdout, or logs. The SDK
   receives it as `gitHubToken` with `useLoggedInUser: false`.

Before starting a new flow, the helper may call the SDK auth-status API with no
explicit token to discover an existing Copilot CLI OAuth login or `gh` fallback.
If the user chooses that identity, the original application continues to own the
credential: Copilot CLI stores its OAuth token in macOS Keychain under service
`copilot-cli`, and Daisy neither reads nor copies it.

The helper removes `COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`, direct API
token variables, and BYOK provider variables from the inherited environment.
This prevents an unrelated shell token or provider key from silently replacing
the account selected in the UI.

Disconnect deletes Daisy-owned tokens from Keychain. For a reused CLI identity it
only disconnects Daisy and does not remove another application's shared token.
The UI links to the relevant GitHub application settings when the user wants to
revoke authorization server-side.

## Model selection

The helper obtains the account's current choices with `listModels()`, including
capabilities, billing information, and policy availability. Daisy stores only
the selected model ID in settings and passes it as the SDK session `model`.
It must not ship a hard-coded list or silently substitute a model. If the saved
ID is no longer available, the connection becomes `needs attention` and the user
chooses another returned model.

The UI must show that Copilot SDK prompts consume the user's Copilot allowance
and that model cost can differ. Model discovery and one small test summary are
the only operations allowed before the user explicitly selects Copilot.

## File and tool isolation

Copilot's default SDK mode exposes coding-agent tools, so the default is unsafe
for meeting transcripts. Every summary session must use all of these controls:

- client mode `empty`, which removes built-in tools and ambient host integration;
- a fresh empty `0700` working directory and isolated `baseDirectory` per request;
- no custom tools, MCP servers, plugins, skills, custom instructions, or memory;
- an empty available-tool set;
- an `OnPermissionRequest` handler that rejects every request;
- an `OnPreToolUse` hook that denies every attempted tool call;
- no workspace RPC calls;
- deletion of the SDK session and temporary directories after completion.

The helper accepts one bounded JSON request on stdin and emits one bounded JSON
response on stdout. The transcript is included only in the prompt. The response
must validate against Daisy's shared meeting-summary schema before it crosses
back into the app. Runtime, stdout, stderr, and cancellation are bounded, and raw
runtime diagnostics are never returned to the UI or logs.

`mode: empty` is the primary capability boundary. The permission handler, hook,
and empty working directory are fail-closed defense in depth. Any SDK version
that cannot provide all three programmatic controls is incompatible with Daisy.

## Licensing and release restriction

- The official SDK source is MIT licensed. Its license and the notices for the
  pinned embedded CLI/runtime and all third-party components must ship with Daisy.
- Each user still needs an eligible GitHub account and Copilot subscription (or
  plan allowance). Usage is charged under Copilot's normal SDK/CLI billing and
  organization or enterprise policies still apply.
- The SDK is currently Public Preview. GitHub states it may not be production
  ready, and its published pre-release license terms limit preview software to
  evaluation/internal development and prohibit external distribution and active
  production use.

Therefore AUTH-12 may proceed only as an internal, non-production spike. Public
distribution of the Copilot provider is blocked until the SDK becomes generally
available or GitHub gives written terms that permit Daisy's external production
distribution. Legal review must also confirm the pinned CLI/runtime notices
before shipping.

## AUTH-12 acceptance gate

Implementation can start after this decision is accepted, but it is not
releaseable until the preview restriction is cleared. The spike must prove:

1. universal helper build, signing, notarization, and first launch on a clean Mac;
2. existing-login reuse plus Daisy's GitHub App device flow, refresh, and logout;
3. live model listing and unavailable-model handling;
4. valid structured summary output with all tool paths disabled;
5. errors for missing subscription, expired auth, policy denial, quota/rate limit,
   timeout, cancellation, malformed output, and incompatible runtime;
6. no transcript, session, or raw diagnostic residue after the request.

## Primary references

- https://github.com/github/copilot-sdk
- https://github.com/github/copilot-sdk/blob/main/go/README.md
- https://docs.github.com/en/copilot/how-tos/copilot-sdk/auth/authenticate
- https://docs.github.com/en/copilot/how-tos/copilot-sdk/setup/github-oauth
- https://docs.github.com/en/copilot/how-tos/copilot-sdk/setup/multi-tenancy
- https://docs.github.com/en/copilot/how-tos/copilot-sdk/troubleshooting/compatibility
- https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/authenticate-copilot-cli
- https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app
- https://docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features
- https://docs.github.com/en/site-policy/github-terms/github-pre-release-license-terms
