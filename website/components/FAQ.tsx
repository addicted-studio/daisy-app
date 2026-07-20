import { Eyebrow } from "./Eyebrow";

const FAQS = [
  {
    q: "Which Macs does it run on?",
    a: "Apple Silicon Macs (M1 / M2 / M3 / M4) running macOS Sonoma 14 or newer. Intel Macs aren't supported — the on-device transcription needs the Neural Engine to be fast enough to be invisible. Apple Intelligence summaries additionally require macOS Tahoe 26; on older releases you can use Anthropic, OpenAI, or a local MCP server for summaries instead.",
  },
  {
    q: "How does it capture the other side of the call?",
    a: "ScreenCaptureKit — Apple's system audio API. The first time you record, macOS will prompt you for Screen Recording permission. Daisy never enters the meeting; it just listens to what your speakers were about to play. If permission is denied Daisy tells you immediately — no silent mic-only sessions.",
  },
  {
    q: "How does the MCP server work?",
    a: "Daisy ships a local MCP (Model Context Protocol) server on 127.0.0.1. Flip it on in Connections → MCP server → \"Let AI clients read your sessions\". One click writes the config into Claude Desktop's claude_desktop_config.json for you (asks permission once, then silent). Claude or Cursor then get nine tools: five to read (list, get, and search sessions, folders, destinations) and four to act — re-summarize a session, retitle it, name a diarized speaker, route it to Notion / Linear / Slack. Your transcripts become a live data source the AI can query and act on without anything leaving your Mac.",
  },
  {
    q: "Claude Desktop says the Daisy MCP server didn't start — why?",
    a: "Claude Desktop speaks stdio, but Daisy's server speaks HTTP+SSE on localhost. The config Daisy writes uses a tiny `mcp-remote` bridge (via `npx`) to translate between the two — that's why it includes `--transport sse-only` and `--allow-http`. If it fails: (1) make sure Node is installed (`node -v` in Terminal), (2) confirm the MCP server toggle is green in Connections → MCP server, (3) restart Claude Desktop fully. The /docs/mcp page has the full walkthrough.",
  },
  {
    q: "How does tagging work?",
    a: "Each recording gets a `daisy_tag` value in its Markdown frontmatter — \"Inbox\" by default, or any tag you've used before. Click the tag field in the recording's header for a Notion-style autocomplete; the Library sidebar lets you filter by tag too. Tags don't move files, they live in frontmatter, so Obsidian and any other Markdown tool can read them.",
  },
  {
    q: "Does Daisy keep the raw audio?",
    a: "Optional. The default is transcript-only — raw audio is discarded once the recording is transcribed, summarised, and saved. Change how long audio is kept under Settings → General → Privacy (\"Delete audio after\") if you want a playable archive; the audio sits in the same Library folder as the Markdown.",
  },
  {
    q: "Can I dictate quick notes too?",
    a: "Yes — Daisy ships three recording modes. Meeting capture (orange widget centre), voice notes (coral — quick one-off thoughts to your Library), and Wispr Flow-style dictation (lilac — audio-to-text pasted at your cursor in whatever app you're typing in). Each has its own hotkey in Settings → Recording → Shortcuts; voice notes is a toggle, dictation is hold-to-talk.",
  },
  {
    q: "Where do my transcripts go?",
    a: "Into the folder you choose — typically your Obsidian vault or iCloud Drive. Daisy writes plain Markdown with frontmatter, one file per recording, in a Daisy/Sessions subdirectory. You can also push finished recordings to Notion, Linear, Attio, or a webhook of your own — manually or automatically when recording stops.",
  },
  {
    q: "What languages does the transcription support?",
    a: "Russian, English, and roughly 90 others. Transcription runs on-device with WhisperKit — a fast Standard model by default, or a larger, most-accurate model if you want. Quality is comparable to cloud services, just running locally. Silero VAD pre-pass + thresholds prevent hallucinations on silences.",
  },
  {
    q: "Why bring my own AI key for summaries?",
    a: "So the cost is yours, not ours. Apple Intelligence works without any key and stays offline. If you want Claude or GPT-quality summaries, plug in your own API key in Settings — Daisy never sees the key or the prompt; the request goes from your Mac to the provider directly. Each summary runs roughly $0.01–0.05 against your account.",
  },
  {
    q: "Is it free?",
    a: "Free during beta. Final pricing will be a one-time lifetime purchase — no monthly subscription, no per-meeting metering, no per-summary fees, no bill that grows with how much you record. The cloud meeting-notes incumbents charge $8-25/month forever; we'd rather charge once and let you own the tool.",
  },
  {
    q: "Is it open source?",
    a: "Yes. Daisy is fully open source on GitHub under the Apache 2.0 licence — you can read every line, build it from source, fork it, ship your own variant. No \"open core\" gimmicks, no commercial-use restrictions. Repo: github.com/addicted-studio/daisy-app.",
  },
  {
    q: "Who makes Daisy?",
    a: "Built by Addicted — an independent product studio (design, engineering, security audit). We make tools we'd want to use ourselves. Daisy was first an internal tool for client interviews; we shipped it because we kept being asked.",
  },
];

// Schema.org FAQPage payload — gives Google a structured handle on
// every Q&A pair so it can render rich snippets directly in search
// results ("People also ask" blocks + accordion-style FAQ snippets).
// Built from the same FAQS array as the visual rendering — single
// source of truth, can't drift.
//
// Google penalises FAQ schema when the questions don't actually
// appear visibly on the page, so we keep the structured-data list
// strictly mirrored against what's rendered below. If you add a
// question to FAQS, the schema updates automatically.
const FAQ_PAGE_LD = {
  "@context": "https://schema.org",
  "@type": "FAQPage",
  mainEntity: FAQS.map(({ q, a }) => ({
    "@type": "Question",
    name: q,
    acceptedAnswer: {
      "@type": "Answer",
      text: a,
    },
  })),
};

export function FAQ() {
  return (
    <section
      id="faq"
      className="relative border-t border-[color:var(--color-divider)] bg-[color:var(--color-bg-sidebar)] px-6 py-24 md:py-32"
    >
      {/* JSON-LD lives inside the section so it ships only on pages
          that actually render the FAQ component — not the whole site.
          Google requires the structured data to match visible content,
          so the script + the rendered <details> below come from the
          same FAQS array. */}
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(FAQ_PAGE_LD) }}
      />
      <div className="mx-auto max-w-3xl">
        <Eyebrow>FAQ</Eyebrow>
        <h2 className="mb-12 font-display text-3xl font-semibold leading-tight tracking-tight md:text-4xl">
          Questions we get.
        </h2>

        <div className="space-y-3">
          {FAQS.map((f) => (
            <details
              key={f.q}
              className="group rounded-xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] p-5 open:pb-6 transition-all"
            >
              <summary className="flex cursor-pointer list-none items-center justify-between gap-4 font-medium">
                <span>{f.q}</span>
                {/* Thin chevron beats the generic `+` → rotate-45
                    Bootstrap-era affordance. 180° flip on open
                    keeps the same animation grammar (rotation
                    settles the eye on the now-open state). */}
                <svg
                  width="14"
                  height="14"
                  viewBox="0 0 14 14"
                  fill="none"
                  aria-hidden
                  className="shrink-0 text-[color:var(--color-ink-tertiary)] transition-transform duration-200 group-open:rotate-180"
                >
                  <path
                    d="M3.5 5l3.5 4 3.5-4"
                    stroke="currentColor"
                    strokeWidth="1.4"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                  />
                </svg>
              </summary>
              <p className="mt-3 text-sm leading-relaxed text-[color:var(--color-ink-secondary)]">
                {f.a}
              </p>
            </details>
          ))}
        </div>
      </div>
    </section>
  );
}
