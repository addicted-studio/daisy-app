import type { Metadata } from "next";
import { ComparisonPage, type ComparisonRow } from "@/components/ComparisonPage";

// "Why not just use Voice Memos / Notes?" is the default objection from
// every Mac user, and macOS 26 made native transcription genuinely good
// (on-device, Apple Intelligence summaries, even Phone/FaceTime call
// recording). So this page is a CAPABILITY comparison, not a privacy one
// — both are local. We credit Apple honestly; Daisy's edge is the
// meeting-specific layer (both call sides, speaker labels, swappable AI,
// destinations, MCP). Apple capabilities verified vs Apple Support (June 2026).

export const metadata: Metadata = {
  title:
    "Daisy vs Apple's built-in transcription — the meeting layer Notes and Voice Memos don't have",
  description:
    "macOS 26 already records and transcribes on-device with Apple Intelligence summaries. Daisy adds the meeting-specific layer: both sides of a call, speaker labels, your own AI, destinations, and a local MCP server — without leaving your Mac.",
  openGraph: {
    type: "article",
    title: "Daisy vs Apple's built-in transcription",
    description:
      "macOS already transcribes on-device. Daisy adds the meeting layer: both call sides, speaker labels, your own AI, destinations, MCP.",
    url: "https://mydaisy.io/alternatives/apple",
    images: ["/og.png"],
  },
  alternates: { canonical: "https://mydaisy.io/alternatives/apple" },
};

const ROWS: ComparisonRow[] = [
  {
    feature: "On-device & private",
    daisy: "Yes",
    them: "Yes — same as Daisy",
  },
  {
    feature: "Records & transcribes audio",
    daisy: "Yes — Whisper on the Neural Engine",
    them: "Yes — Notes & Voice Memos",
  },
  {
    feature: "Captures both sides of a video call",
    daisy: "Yes — system audio from Zoom, Meet, Telegram, any app",
    them: "No — microphone only (Phone & FaceTime calls excepted)",
  },
  {
    feature: "Speaker labels (who said what)",
    daisy: "Yes — on-device diarization",
    them: "No",
  },
  {
    feature: "AI summary",
    daisy: "Your choice — Claude, GPT, Apple Intelligence, or local",
    them: "Apple Intelligence",
  },
  {
    feature: "Where notes go",
    daisy: "Markdown in your folder + Notion, Linear, Slack, webhook",
    them: "Notes app",
  },
  {
    feature: "MCP for Claude / Cursor",
    daisy: "Yes — local server",
    them: "No",
  },
];

export default function AppleAlternativePage() {
  return (
    <ComparisonPage
      competitor="Apple"
      slug="apple"
      themColumn="Apple (built-in)"
      h1="Why not just use Voice Memos or Notes?"
      lede="Fair question. macOS 26 records audio, transcribes it on-device, and can even summarise with Apple Intelligence — all privately. Daisy isn't more private than Apple; it adds the meeting-specific layer Apple's built-in apps don't: capturing both sides of a video call, labelling who said what, your choice of AI, sending notes to your tools, and exposing transcripts to Claude or Cursor."
      tableTitle="Daisy vs Apple's built-in apps at a glance"
      rows={ROWS}
      aheadTitle="Where Apple's built-in apps win — and when to just use them"
      aheadBody="Apple's tools are free, already installed, beautifully integrated, and fast — and Apple can record and summarise Phone and FaceTime calls, which Daisy doesn't touch. If you mostly need a quick recording with a rough transcript and a summary, Voice Memos and Notes are excellent and you don't need Daisy. Daisy earns its place when a meeting needs the other side of the call captured, the speakers labelled, a smarter or swappable AI summary, or the notes pushed into your tools and AI clients — without giving up the on-device privacy Apple gives you too."
      sourceLabel="Apple Support"
      sourceUrl="https://support.apple.com/guide/notes/record-and-transcribe-audio-apdb5106e334/mac"
      asOf="June 2026"
      crossLinks={[
        { label: "Granola", href: "/alternatives/granola" },
        { label: "Otter", href: "/alternatives/otter" },
      ]}
    />
  );
}
