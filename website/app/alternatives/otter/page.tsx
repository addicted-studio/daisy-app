import type { Metadata } from "next";
import { ComparisonPage, type ComparisonRow } from "@/components/ComparisonPage";

// Otter is the most-Googled name in the category, so "Otter alternative"
// has real search volume. The contrast is clean and factual: Otter is a
// cloud, per-seat SaaS that auto-joins calls; Daisy is local-first, open
// source, one-time. Pricing/features verified vs otter.ai (June 2026).

export const metadata: Metadata = {
  title:
    "Otter alternative — Daisy keeps your meetings on your Mac, open-source",
  description:
    "Looking for an Otter.ai alternative? Daisy records meetings locally on macOS, transcribes on-device, brings your own AI key, runs a local MCP server, and never uploads your transcripts. Apache 2.0, no subscription.",
  openGraph: {
    type: "article",
    title: "Otter alternative — Daisy",
    description:
      "Open-source, local-first meeting recorder for Mac. No cloud upload, no per-seat subscription, MCP-ready.",
    url: "https://mydaisy.io/alternatives/otter",
    images: ["/og.png"],
  },
  alternates: { canonical: "https://mydaisy.io/alternatives/otter" },
};

const ROWS: ComparisonRow[] = [
  {
    feature: "Where transcripts & notes live",
    daisy: "Plain Markdown in your folder — never uploaded",
    them: "Otter's cloud",
  },
  {
    feature: "Transcription",
    daisy: "On-device (Whisper, Apple Neural Engine)",
    them: "Cloud",
  },
  {
    feature: "AI summary",
    daisy: "Bring your own key — Anthropic, OpenAI, Apple Intelligence, or local Ollama / LM Studio",
    them: "Otter's own AI (cloud)",
  },
  {
    feature: "In the meeting",
    daisy: "No bot — captures both sides locally",
    them: "Integrates with / auto-joins Zoom, Teams, Meet",
  },
  {
    feature: "Open source",
    daisy: "Yes — Apache 2.0",
    them: "No — closed SaaS",
  },
  {
    feature: "Pricing",
    daisy: "Free during beta · one-time after launch",
    them: "Free (300 min/mo) · Pro $8.33 · Business $19.99 / user-mo (annual)",
  },
  {
    feature: "Platforms",
    daisy: "macOS 14+ (Apple Silicon)",
    them: "Web, iOS, Android, Mac, Windows",
  },
];

export default function OtterAlternativePage() {
  return (
    <ComparisonPage
      competitor="Otter"
      slug="otter"
      themColumn="Otter"
      h1="Looking for an Otter alternative that doesn't send your calls to the cloud?"
      lede="Daisy is an open-source, local-first meeting recorder for macOS. It records both sides of a call on your Mac, transcribes on the Apple Neural Engine, summarises with your own AI key, and never uploads your transcripts."
      tableTitle="Daisy vs Otter at a glance"
      rows={ROWS}
      aheadTitle="Where Otter is ahead — and who shouldn't switch"
      aheadBody="Otter runs everywhere — web, iOS, Android, Windows — and plugs straight into Zoom, Teams, and Google Meet, with real-time transcription, a long track record, and team features Daisy doesn't have. If you take calls across devices, need a shared team workspace, or live inside those meeting platforms, Otter is the more complete fit. Daisy is the trade when you'd rather keep everything local and open-source on a Mac, with a one-time price instead of a per-seat subscription."
      sourceLabel="otter.ai"
      sourceUrl="https://otter.ai/pricing"
      asOf="June 2026"
      crossLinks={[
        { label: "Granola", href: "/alternatives/granola" },
        { label: "Apple's built-in apps", href: "/alternatives/apple" },
      ]}
    />
  );
}
