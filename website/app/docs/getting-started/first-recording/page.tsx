import type { Metadata } from "next";

import { Prose } from "@/components/docs/Prose";

export const metadata: Metadata = {
  title: "First recording",
  description:
    "From the install dialog to a finished, summarised Daisy recording in your folder.",
};

export default function FirstRecordingPage() {
  return (
    <Prose>
      <h1>Your first recording</h1>
      <p>
        After install, Daisy lives in two places: a small floating
        widget on your screen (the petal), and a main window you open
        from the menu bar icon or with <code>⌘⇧H</code>. This page
        walks you from the empty Daisy state to a finished, summarised
        transcript sitting in the folder of your choice.
      </p>

      <h2>1. Pick your Library folder</h2>
      <p>
        Open <strong>Settings → General → Storage</strong> (the{" "}
        <strong>Recordings folder</strong> row) and choose the folder
        where Daisy will save your recordings. Common picks:
      </p>
      <ul>
        <li>
          Your <strong>Obsidian vault</strong> — Daisy writes plain
          Markdown with YAML frontmatter, so transcripts become first-
          class notes you can tag, link, and search alongside the rest
          of your vault.
        </li>
        <li>
          <strong>iCloud Drive</strong> — if you want recordings
          accessible across Macs without setting up Obsidian.
        </li>
        <li>
          A dedicated folder under <code>~/Documents</code> — clean
          start, easy to move later.
        </li>
      </ul>
      <p>
        Daisy will create a <code>Daisy/Sessions</code> subfolder
        inside whatever you pick, and write one Markdown file per
        recording.
      </p>

      <h2>2. Optionally connect your AI provider</h2>
      <p>
        Open <strong>Settings → Summary</strong> and pick an AI
        provider for summaries:
      </p>
      <ul>
        <li>
          <strong>Apple Intelligence</strong> (macOS 26) — runs fully
          on-device, no API key, no cloud. Fastest privacy-first option.
        </li>
        <li>
          <strong>Anthropic Claude</strong> — paste your{" "}
          <code>sk-ant-...</code> key. Highest summary quality for long
          transcripts.
        </li>
        <li>
          <strong>OpenAI</strong> — paste your <code>sk-...</code> key.
        </li>
        <li>
          <strong>Local MCP</strong> — point at any MCP-compatible model
          you&rsquo;re already running locally (Ollama, LM Studio).
        </li>
      </ul>
      <p>
        Keys live in your macOS Keychain. Daisy never sees them — each
        summary request goes from your Mac straight to the provider.
      </p>
      <p>
        Skip this step if you only want transcripts, no summaries. You
        can configure it later.
      </p>

      <h2>3. Record</h2>
      <p>
        Daisy supports three recording modes:
      </p>
      <ul>
        <li>
          <strong>Meeting</strong> (orange centre) — captures
          microphone <em>and</em> system audio together. Use for Zoom,
          Meet, Telegram, anything that plays audio on your Mac. Tap
          the widget or hit <code>⌘⇧R</code>.
        </li>
        <li>
          <strong>Voice notes</strong> (coral centre) — quick one-off
          thoughts, mic only. Default hotkey configurable in{" "}
          <strong>Settings → Recording → Shortcuts</strong>.
        </li>
        <li>
          <strong>Dictation</strong> (lilac centre) — hold a hotkey to
          talk, release to paste transcribed text at your cursor.
          Wispr Flow-style.
        </li>
      </ul>
      <p>
        For your first recording, the meeting mode is the most-used path
        — flip on whatever you want to capture, click the widget,
        speak for a minute or three. The widget centre turns orange
        and the petals dance with your voice spectrum.
      </p>

      <h2>4. Stop &amp; review</h2>
      <p>
        Click the widget again, or right-click → <strong>Stop &amp; save</strong>.
        The widget centre fades to a pulsing amber while Daisy:
      </p>
      <ol>
        <li>
          Transcribes the audio with on-device WhisperKit on the Neural
          Engine (Standard model by default; switch to Most accurate in
          Settings for the larger, most-accurate model). Real-time-ish on Apple
          Silicon — a 30-minute meeting takes roughly 90 seconds.
        </li>
        <li>
          Runs speaker diarisation on-device with Pyannote so remote
          voices are labelled <code>Remote A</code>,{" "}
          <code>Remote B</code>, and so on (Daisy can auto-name people
          it recognises).
        </li>
        <li>
          If you connected an AI provider in step 2, sends the
          transcript for summarisation. Otherwise skips this step.
        </li>
        <li>
          Writes the finished Markdown to your Library folder and
          opens the recording in the main window.
        </li>
      </ol>

      <h2>5. What lands on disk</h2>
      <p>
        One Markdown file per recording, in your Library folder, with a
        filename like:
      </p>
      <pre>
        <code>2026-05-21 Acme · discovery call.md</code>
      </pre>
      <p>
        Inside: YAML frontmatter (date, duration, tag, attendees if
        from a calendar event), then the AI-generated summary and
        action items, then the full transcript with speaker labels.
        It&rsquo;s plain Markdown — open it in Obsidian, VS Code,
        TextEdit, anything.
      </p>

      <h2>Where to go next</h2>
      <ul>
        <li>
          Read <a href="/docs/recording/modes">Three recording modes</a>{" "}
          for the differences between meeting / voice note / dictation.
        </li>
        <li>
          Set up the <a href="/docs/mcp">local MCP server</a> if you
          want Claude Desktop or Cursor to read your transcripts.
        </li>
        <li>
          Browse other settings under <strong>Settings → General</strong>:
          audio retention (&ldquo;Delete audio after&rdquo;) in{" "}
          <strong>Privacy</strong>, your display name (replaces
          &ldquo;Me&rdquo; in transcripts) in <strong>Profile</strong>,
          and toggles in <strong>Notifications</strong>.
        </li>
      </ul>
    </Prose>
  );
}
