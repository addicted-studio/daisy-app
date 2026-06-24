# Daisy

A local-first meeting recorder, push-to-talk dictation tool, and AI-notes app for macOS — with a local MCP server so Claude Desktop and Cursor can query your transcripts without anything leaving the Mac.

Daisy captures meeting audio (microphone + system-audio loopback via ScreenCaptureKit), transcribes it on-device with Whisper on the Neural Engine, and produces a Granola-style outline with action items and a draft follow-up. Audio and transcripts never leave the Mac unless you explicitly enable a cloud LLM provider for the summary step — and even then you supply your own API key.

End-user installation, FAQ, and the privacy story live at **<https://mydaisy.io>**. This README is for people building Daisy from source.

## What it does

Three capture modes, one app:

- **Meetings** — records both sides of a call (your mic + the other side via system-audio loopback), no bot joining the meeting. On-device transcription + diarization (`Remote A` / `Remote B`, with optional mic-side attribution), a summary, action items, and a draft follow-up.
- **Push-to-talk dictation** — hold a hotkey, speak, and the text is pasted at your cursor in any app. Whisper by default, or on-device Parakeet (FluidAudio) for lower latency; a custom-vocabulary dictionary fixes names/jargon, and a rolling 24-hour history lets you re-copy.
- **Voice notes** — quick one-off thoughts saved to your Library. Optional: import existing **Apple Voice Memos** as flat transcripts (on-device, opt-in, needs Full Disk Access).

The differentiator: Daisy ships a **local MCP server** bound to `127.0.0.1` that exposes your sessions as a queryable, actionable data source to any MCP client (Claude Desktop, Cursor). Because the transcript is already local, Daisy can be a local-only MCP source — something cloud meeting tools structurally can't offer.

## Status

- Latest release: see [`scripts/release-notes/`](./scripts/release-notes/) and <https://mydaisy.io/appcast.xml>. Beta ships from `main`; stable is promoted from a soaked beta (see [`RELEASING.md`](./RELEASING.md)).
- Deployment target: macOS 14 Sonoma. The Apple Intelligence summarizer requires macOS 26 Tahoe; everything else runs on 14+.
- Apple Silicon (M1+). Signed with Developer ID, notarized, stapled, Sparkle EdDSA-signed for in-app updates.
- License: **Apache 2.0** (see [`LICENSE`](./LICENSE)). Full public source — build it and verify there's no telemetry.

## Build from source

Requirements:

- Xcode 16+ with the macOS 26 SDK installed
- An active Apple Developer account if you want a signed local build (unsigned builds are fine for development inside Xcode)

Clone and open:

```bash
git clone https://github.com/addicted-studio/daisy-app.git
cd daisy-app
open Daisy.xcodeproj
```

The Swift Package Manager dependencies (Sparkle, WhisperKit/ArgmaxCore, FluidAudio) resolve on first project load. Hit Run; the app launches.

## Project layout

```
Daisy/                  → SwiftUI app sources (PBXFileSystemSynchronizedRootGroup)
DaisyTests/             → unit tests
DaisyUITests/           → UI tests
Daisy.xcodeproj/        → Xcode project
scripts/
  release.sh            → end-to-end release: archive → notarize → DMG → sign → Sparkle appcast
  release-notes/        → per-version markdown bullets consumed by release.sh
  dmgbuild_settings.py  → dmgbuild config (Python) for the installer DMG
  assets/               → DMG background, app icons
build/                  → archive output (gitignored)
RELEASING.md            → branch/channel model and the release/promote/hotfix flows
```

Key services that drive the app:

- `CoreAudioMicRecorder` — CoreAudio mic capture with route-change recovery and the archive `.caf` writer (replaced the old AVAudioEngine tap to fix route-change/Bluetooth dropouts)
- `SystemAudioCapture` — `SCStream` loopback for the remote side of a meeting, Bluetooth-output detection, silent-capture warnings
- `Transcriber` / `WhisperEngine` — WhisperKit on-device transcription with a Silero VAD pre-pass
- `ParakeetEngine` — FluidAudio Parakeet-TDT, the optional low-latency dictation engine (Whisper is the default)
- Diarization + speaker memory — FluidAudio (Pyannote) labels remote voices; named speakers are remembered locally by a short voice fingerprint
- `DictationPaste` — pastes dictated text at the cursor via the Accessibility API, restoring your prior clipboard
- `RecordingSession` — orchestrates a session, owns calendar binding and auto-stop scheduling
- `Summarizer` — multi-provider LLM dispatch: Apple Intelligence (on-device), Anthropic, OpenAI, Ollama, LM Studio (local), or an MCP summarizer
- `MCPServer` — the local MCP server on `127.0.0.1`; exposes nine tools (five read, four act) to Claude Desktop / Cursor
- `VoiceMemoScanner` / `VoiceMemoIngestor` — opt-in, on-device import of Apple Voice Memos to Markdown transcripts
- Sparkle 2 — in-app auto-updates against `https://mydaisy.io/appcast.xml`

## MCP server

Daisy's MCP server turns your recordings into a live data source for AI clients, entirely on-device. Enable it in **Connections → MCP server**, click **Add to Claude Desktop**, and the config is written for you. Nine tools, scoped to safe, reversible operations (no deleting, no editing transcript bodies):

- **Read** — `list_sessions`, `get_session`, `search_sessions`, `list_folders`, `list_destinations`
- **Act** — `resummarize_session`, `set_session_title`, `rename_speaker`, `route_session_to_destination` (Notion / Linear / Slack / webhook)

Docs: <https://mydaisy.io/docs/mcp>.

## Release flow

```bash
DAISY_AUTO_PUSH=1 ./scripts/release.sh <shortVersion> <buildNumber> [stable|beta]
```

Beta is the default channel from `main`; stable is promoted from a soaked beta with `./scripts/release.sh promote <version>` (no rebuild). Six steps: archive → export → notarize → DMG → publish to the [daisy-web](https://github.com/addicted-studio/daisy-web) repo → inject an `<item>` into `appcast.xml` and commit. Vercel auto-deploys the site within a couple of minutes. Full branch/channel model and the hotfix flow are in [`RELEASING.md`](./RELEASING.md).

Release notes for each version go in `scripts/release-notes/<shortVersion>.md` as a flat markdown bullet list (`- one line per change`). The script extracts those bullets and embeds them in the appcast `<description>` so Sparkle shows them in its update sheet.

## Support and contact

- Questions, ideas, show-and-tell → [GitHub Discussions](https://github.com/addicted-studio/daisy-app/discussions)
- Product issues, feature requests → file an issue on this repo or email **essazanov@pm.me**
- Security disclosures → see [`SECURITY.md`](./SECURITY.md)
- Procurement / security review / tailored deployment → email **essazanov@pm.me**
- End-user docs → <https://mydaisy.io/docs> · Privacy → <https://mydaisy.io/privacy>

## Credits

- [Sparkle](https://sparkle-project.org) — in-app auto-updates
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax — Apple Silicon Whisper inference
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — Parakeet ASR + speaker diarization
- [FoundationModels](https://developer.apple.com/documentation/foundationmodels) — on-device summarization via Apple Intelligence (macOS 26+)

## License

[Apache 2.0](./LICENSE).
