# Daisy

A local-first meeting recorder and AI notes app for macOS.

Daisy captures meeting audio (microphone + system audio loopback via ScreenCaptureKit), transcribes it on-device with Whisper, and produces a Granola-style outline with action items and a draft client follow-up. Audio never leaves the Mac unless the user explicitly enables a cloud LLM provider (Anthropic / OpenAI / MCP) for the summary step — and even then the user supplies their own API key.

End-user installation, FAQ, and the privacy story live at **<https://mydaisy.io>**. This README is for people building Daisy from source.

## Status

- Latest stable release: see [`scripts/release-notes/`](./scripts/release-notes/) and <https://mydaisy.io/appcast.xml>
- Deployment target: macOS 14 Sonoma (Apple Intelligence summarizer requires macOS 26 Tahoe)
- Apple Silicon and Intel x86_64 universal binary
- Signed with Developer ID, notarized, stapled, Sparkle EdDSA-signed for in-app updates

## Build from source

Requirements:

- Xcode 16+ with the macOS 26 SDK installed
- An active Apple Developer account if you want to run a signed local build (unsigned builds are fine for development inside Xcode)

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
```

Key services that drive the app:

- `AudioRecorder` — `AVAudioEngine` mic tap, route-change recovery, archive `.caf` writer
- `SystemAudioCapture` — `SCStream` loopback for the remote side of a meeting, BT-output detection, silent-capture warnings
- `Transcriber` — WhisperKit on-device transcription with Silero VAD pre-pass
- `RecordingSession` — orchestrates a session, owns calendar binding and auto-stop scheduling
- `Summarizer` — multi-provider cloud / on-device LLM dispatch (Apple Intelligence, Anthropic, OpenAI, MCP)
- `SparkleUpdater` — wraps Sparkle 2 against `https://mydaisy.io/appcast.xml`

## Release flow

```bash
DAISY_AUTO_PUSH=1 ./scripts/release.sh <shortVersion> <buildNumber>
```

Six steps: archive → export → notarize → DMG → publish to the [daisy-web](https://github.com/addicted-studio/daisy-web) repo → inject an `<item>` into `appcast.xml` and commit. Vercel auto-deploys the site within a couple of minutes.

Release notes for each version go in `scripts/release-notes/<shortVersion>.md` as a flat markdown bullet list (`- one line per change`). The script extracts those bullets and embeds them in the appcast `<description>` so Sparkle shows them in its update sheet.

## Support and contact

- Product issues, feature requests, general questions → file an issue on this repo or email **essazanov@pm.me**
- Security disclosures → see [`SECURITY.md`](./SECURITY.md)
- End-user docs → <https://mydaisy.io/support>
- Privacy policy → <https://mydaisy.io/privacy>

## Credits

- [Sparkle](https://sparkle-project.org) — in-app auto-updates
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax — Apple Silicon Whisper inference
- [FluidAudio](https://github.com/FluidInference/FluidAudio) — speaker diarization
- [FoundationModels](https://developer.apple.com/documentation/foundationmodels) — on-device summarization via Apple Intelligence (macOS 26+)

## License

See [`LICENSE`](./LICENSE).
