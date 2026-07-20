import type { Metadata } from "next";

import { Prose } from "@/components/docs/Prose";
import { LATEST_DMG_URL, LATEST_VERSION } from "@/lib/latestVersion";

export const metadata: Metadata = {
  title: "Installation",
  description:
    "Download the signed Daisy DMG, drag to Applications, grant macOS permissions on first launch.",
};

export default function InstallationPage() {
  return (
    <Prose>
      <h1>Installation</h1>
      <p>
        Daisy ships as a signed, notarised DMG straight from{" "}
        <a href="https://mydaisy.io">mydaisy.io</a>. No installer, no
        login, no telemetry hand-off — the same binary that runs on my
        Mac runs on yours.
      </p>

      <h2>Requirements</h2>
      <ul>
        <li>
          Apple Silicon Mac (M1 / M2 / M3 / M4). Intel Macs aren&rsquo;t
          supported — on-device transcription needs the Neural Engine
          to be fast enough to feel instant.
        </li>
        <li>
          macOS 14 (Sonoma) or newer. Apple Intelligence summaries
          additionally require macOS 26 (Tahoe).
        </li>
        <li>
          About 500 MB of disk for the app + first-run Whisper model
          download.
        </li>
      </ul>

      <h2>Download</h2>
      <p>
        Pull the latest DMG from{" "}
        <a href={LATEST_DMG_URL}>
          mydaisy.io/downloads/Daisy-{LATEST_VERSION}.dmg
        </a>{" "}
        or grab any historical release from the{" "}
        <a
          href="https://github.com/addicted-studio/daisy-app/releases"
          target="_blank"
          rel="noreferrer"
        >
          GitHub Releases page
        </a>
        .
      </p>
      <p>
        Open the DMG, drag the Daisy icon into the <code>Applications</code>{" "}
        folder, eject the DMG. From here you can delete the .dmg file
        itself — the app is fully self-contained inside{" "}
        <code>/Applications/Daisy.app</code>.
      </p>

      <h2>First launch</h2>
      <p>
        Launch Daisy from <code>/Applications</code> or via Spotlight.
        macOS will check the notarisation signature and, on first run,
        ask you to confirm the open. This is one-time per Mac.
      </p>
      <p>
        Daisy then walks you through its system permissions in
        sequence. Each is required for a specific feature — you can
        skip any of them, but the feature it gates won&rsquo;t work
        until granted:
      </p>
      <ul>
        <li>
          <strong>Microphone</strong> — required for recording your own
          voice. Without this, all recording modes return empty
          transcripts.
        </li>
        <li>
          <strong>Screen Recording</strong> — required for{" "}
          <em>system audio</em> capture (the other side of Zoom / Meet
          calls). Without this, Daisy records only your microphone, so
          meetings with remote attendees won&rsquo;t capture what they
          said.
        </li>
        <li>
          <strong>Calendar</strong> — optional. Lets Daisy read your
          schedule so it can title meetings, pull attendees, and offer
          to auto-record events as they begin.
        </li>
        <li>
          <strong>Accessibility</strong> — required only if you plan to
          use the Dictation mode (auto-paste at cursor needs to send
          ⌘V on your behalf). Optional otherwise.
        </li>
        <li>
          <strong>Notifications</strong> — optional. Lets Daisy alert
          you when a recording starts, finishes, or needs attention.
        </li>
      </ul>
      <p>
        Each permission opens the relevant pane in{" "}
        <strong>System Settings → Privacy &amp; Security</strong>. Flip
        the toggle, return to Daisy, click <strong>Continue</strong>.
      </p>

      <h2>Sparkle auto-updates</h2>
      <p>
        Daisy uses Sparkle for in-app updates, signed with EdDSA. The
        first time the app starts it registers a daily check against{" "}
        <a
          href="https://mydaisy.io/appcast.xml"
          target="_blank"
          rel="noreferrer"
        >
          mydaisy.io/appcast.xml
        </a>
        . When a new release is available you&rsquo;ll see a small
        prompt — review the changes, click <strong>Install Update</strong>,
        Daisy restarts on the new version.
      </p>
      <p>
        To check manually: <strong>Daisy → About → Check for Updates</strong>.
        Disable auto-checks in <strong>Settings → General → Updates</strong>{" "}
        if you prefer manual.
      </p>

      <h2>If something goes wrong</h2>
      <p>
        <strong>&ldquo;Daisy is damaged and can&rsquo;t be opened&rdquo;</strong>{" "}
        — the DMG download was incomplete or modified. Re-download from
        mydaisy.io. The signature check should succeed on a fresh copy.
      </p>
      <p>
        <strong>App won&rsquo;t launch / instantly quits</strong> — make
        sure you&rsquo;re on Apple Silicon (Apple menu → About This Mac
        → Chip starts with &ldquo;Apple&rdquo;). If you are, the crash
        is likely a bug worth filing on{" "}
        <a
          href="https://github.com/addicted-studio/daisy-app/issues/new/choose"
          target="_blank"
          rel="noreferrer"
        >
          GitHub Issues
        </a>
        .
      </p>
      <p>
        <strong>Permissions dialog never appears</strong> — open Daisy{" "}
        <strong>Settings → Permissions</strong> for the live status of
        all five (microphone / screen recording / calendar /
        accessibility / notifications). Click the row to jump straight
        into the relevant System Settings pane.
      </p>
    </Prose>
  );
}
