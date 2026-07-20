import type { Metadata } from "next";

import { Prose } from "@/components/docs/Prose";

export const metadata: Metadata = {
  title: "Three recording modes",
  description:
    "Meeting, dictation, and voice notes — what they capture, where the text goes, and how to switch between them.",
};

export default function RecordingModesPage() {
  return (
    <Prose>
      <h1>Three recording modes</h1>
      <p>
        Daisy ships three recording modes, all backed by the same
        on-device Whisper transcription engine. They differ in{" "}
        <em>what they capture</em> and <em>where the text lands</em>.
        The widget centre changes colour so you know at a glance which
        mode is active.
      </p>

      <h2>Meeting (orange)</h2>
      <p>
        Captures your microphone <strong>and</strong> the other side
        of the call together — Zoom, Google Meet, Telegram, Webex,
        anything that plays audio on your Mac. No bot in the meeting,
        no link to install for participants. The widget centre matches
        the macOS systemOrange mic-active indicator at the top of your
        screen, so you can tell at a glance that something is listening.
      </p>
      <p>
        Trigger:
      </p>
      <ul>
        <li>Click the widget</li>
        <li>
          Hotkey (default <code>⌘⇧R</code>, configurable in{" "}
          <strong>Settings → Recording → Shortcuts</strong>)
        </li>
        <li>
          Calendar auto-start — if you connected Google Calendar,
          Daisy can offer to auto-record meetings as they begin (see{" "}
          <strong>Settings → Recording → Meetings</strong>)
        </li>
      </ul>
      <p>
        Output: one full Markdown recording in your Library folder with
        transcript, summary, and action items.
      </p>

      <h2>Voice notes (coral)</h2>
      <p>
        Quick one-off thoughts captured the way a voice memo app would
        — microphone only, no system audio, no meeting context. Hit
        a hotkey, talk, hit it again. The transcript lands in your
        Library as a standalone recording.
      </p>
      <p>
        Trigger:
      </p>
      <ul>
        <li>
          Hotkey (configurable on the Voice notes row in{" "}
          <strong>Settings → Recording → Shortcuts</strong>) — single
          tap to start, single tap to stop
        </li>
        <li>
          Or click the widget when the widget is already set to
          voice-notes mode
        </li>
      </ul>
      <p>
        The widget centre goes pink-coral while capturing — deliberately
        off the recording-orange axis so meetings and voice notes read
        as two different dots at peripheral vision.
      </p>
      <p>
        Output: same Markdown recording format as meetings, just with
        only one speaker (you).
      </p>

      <h2>Dictation (lilac)</h2>
      <p>
        Wispr Flow-style. Hold a hotkey, talk naturally, release. The
        transcribed text gets pasted at your cursor in whatever app
        you&rsquo;re typing in. No recording, no Library file — just
        text-to-cursor.
      </p>
      <p>
        Trigger:
      </p>
      <ul>
        <li>
          Hold the hotkey set on the Dictation row in{" "}
          <strong>Settings → Recording → Shortcuts</strong>. The{" "}
          <code>Fn</code> (globe) key is supported as an option but
          requires Accessibility permission (CGEventTap).
        </li>
      </ul>
      <p>
        The widget centre goes vivid lilac while dictating — same
        colour-state vocabulary as the rest of Daisy.
      </p>
      <p>
        Output: text pasted at your cursor via Accessibility ⌘V. Your
        previous clipboard contents are restored 10 seconds after the
        paste so dictation doesn&rsquo;t trash whatever you had
        copied.
      </p>

      <h2>Switching between modes</h2>
      <p>
        Each mode has its own hotkey, set on its row in{" "}
        <strong>Settings → Recording → Shortcuts</strong>. The fastest
        way to switch is to use the hotkey of the mode you want — Daisy
        starts that mode straight away, whatever the widget last did.
      </p>
      <p>
        Pick whichever hotkey you reach for most (usually meetings) and
        let it become muscle memory; the other two are a keystroke away
        when you want a different mode for one specific capture.
      </p>

      <h2>Where the text goes — summary</h2>
      <ul>
        <li>
          <strong>Meeting</strong> → Library folder, one Markdown file
          per recording with summary + transcript + action items.
        </li>
        <li>
          <strong>Voice notes</strong> → Library folder, one Markdown
          file per recording, same shape as a meeting (just shorter).
        </li>
        <li>
          <strong>Dictation</strong> → pasted at your cursor. Nothing
          saved to Library. If you want a record of what you dictated,
          use Voice notes instead.
        </li>
      </ul>
    </Prose>
  );
}
