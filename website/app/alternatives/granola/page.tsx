import type { Metadata } from "next";
import Link from "next/link";

import { BrandLogo } from "@/components/BrandLogo";
import { TrackedLink } from "@/components/TrackedLink";
import { LATEST_DMG_URL } from "@/lib/latestVersion";

// Single highest-ROI page recommended by the 2026-05-23 pre-PH SEO
// audit. Captures the "granola alternative" query family — high
// commercial intent, easy-to-medium difficulty (Granola itself
// doesn't really compete for the comparison term, and most
// existing "alternative" pages are listicles, not opinionated
// comparisons). The page also gives PH / HN commenters a single
// link to drop when someone in the comments asks "how is this
// different from Granola?" — Daisy's own page will tend to rank
// faster than a third-party listicle.
//
// Structure follows the comparison-landing pattern that ranks
// well for "X alternative" queries: one-line answer up top, then
// a feature table, then a longer "why" section, then CTA. Keep
// concrete and verifiable — Granola's positioning is public and
// well-documented, so this isn't subjective or risky to claim.

export const metadata: Metadata = {
  title:
    "Granola alternative — Daisy is an open-source meeting recorder that keeps audio on your Mac",
  description:
    "Looking for a Granola alternative? Daisy records meetings locally on macOS, transcribes on-device with Whisper, brings your own AI key, and runs a local MCP server. Apache 2.0, no subscription, no cloud upload.",
  openGraph: {
    type: "article",
    title: "Granola alternative — Daisy",
    description:
      "Open-source, local-first meeting recorder for Mac. No cloud upload, no subscription, MCP-ready.",
    url: "https://mydaisy.io/alternatives/granola",
    images: ["/og.png"],
  },
  alternates: {
    canonical: "https://mydaisy.io/alternatives/granola",
  },
};

const COMPARISON: ReadonlyArray<{
  feature: string;
  daisy: string;
  granola: string;
}> = [
  {
    feature: "Where transcripts & notes live",
    daisy: "Your folder, on your disk — never uploaded",
    granola: "Granola's cloud (AWS, US)",
  },
  {
    feature: "Audio recording",
    daisy: "Captured on your Mac; kept on your schedule (or not at all)",
    granola: "Captured on your Mac; deleted after transcription",
  },
  {
    feature: "Transcription",
    daisy: "On-device (Whisper, Apple Neural Engine)",
    granola: "Cloud",
  },
  {
    feature: "AI summary",
    daisy: "Bring your own key — Anthropic, OpenAI, Apple Intelligence, or local Ollama / LM Studio",
    granola: "Granola's own AI (cloud)",
  },
  {
    feature: "Open source",
    daisy: "Yes — Apache 2.0",
    granola: "No — closed SaaS",
  },
  {
    feature: "Pricing",
    daisy: "Free during beta · one-time purchase after launch",
    granola: "$14/user-mo (Business) · $18 (Individual)",
  },
  {
    feature: "Bot in the call",
    daisy: "No — local capture",
    granola: "No — local capture",
  },
  {
    feature: "Works offline",
    daisy: "Yes — with Apple Intelligence or a local model (after first download)",
    granola: "Partial — local capture, cloud for notes",
  },
  {
    feature: "MCP server for AI clients",
    daisy: "Local (127.0.0.1), free, any MCP client",
    granola: "Cloud API / MCP, on paid plans",
  },
  {
    feature: "Destinations",
    daisy: "Notion, Linear, Attio, Slack, webhook, your folder (via MCP / webhooks)",
    granola: "Granola library + integrations",
  },
  {
    feature: "Speaker diarization",
    daisy: "On-device (FluidAudio / pyannote)",
    granola: "Cloud",
  },
  {
    feature: "Platforms",
    daisy: "macOS 14+ (Apple Silicon)",
    granola: "macOS, Windows, iOS",
  },
];

const PROSE = [
  {
    h: "Where the difference matters",
    body:
      "Granola is a strong, polished product. The real difference is where your meeting text ends up. With Granola, transcripts and AI notes are stored in their cloud (on AWS, in the US); with Daisy, they're plain Markdown files in a folder on your Mac that are never uploaded. Both keep your raw audio off any server — Granola deletes it automatically after transcription, Daisy on whatever schedule you choose (including \"don't keep audio at all\"). Daisy is for the case where even the transcript shouldn't leave your machine: regulated work (legal, medical, finance), customer or research interviews, anything under NDA.",
  },
  {
    h: "Where Granola is ahead",
    body:
      "Multi-platform — Granola runs on Windows and iOS too, not just Mac. If you take meetings on more than your MacBook, that's a real gap Daisy doesn't close today. Granola also has a longer track record, a polished onboarding, and a well-funded team. Daisy is the right choice when you'd trade those for local-first, open source, and a one-time purchase.",
  },
  {
    h: "Pricing model",
    body:
      "Granola's Business plan is $14/user/month (the Individual plan is $18; Enterprise starts at $35) — roughly $168–216 a year per seat, indefinitely. Daisy is free during beta and a one-time purchase after launch: no monthly subscription, no per-meeting fees, no cost that scales with how much you record. Over a few years of daily use, that difference compounds. (Granola pricing as of June 2026 — check their site for current numbers.)",
  },
  {
    h: "Open source",
    body:
      "Daisy is Apache 2.0 on GitHub — you can read every line, build from source, audit the network calls, run a fork. Granola is closed SaaS, which means the privacy claims have to be taken on trust. Both can be defensible positions; if open source matters to you, only one of the two is open source.",
  },
  {
    h: "Why MCP matters",
    body:
      "Daisy runs a local MCP server, so Claude Desktop, Cursor, Cline, and any other MCP client can query your transcripts straight off your Mac — no cloud round-trip, no API key shared with us. Granola added a cloud MCP server and API in 2026, but it reads notes that already live in Granola's cloud and is gated to paid plans. Daisy's reads transcripts that never left your machine, free, with no plan to unlock. If you spend your day in Claude Desktop and want it to know what you discussed in your 1-on-1s — without anything leaving your laptop — that's what Daisy is built for.",
  },
];

export default function GranolaAlternativePage() {
  return (
    <main className="relative z-0 min-h-screen bg-[color:var(--color-bg)] text-[color:var(--color-ink-primary)]">
      <header className="border-b border-[color:var(--color-divider)]">
        <div className="mx-auto flex max-w-5xl items-center justify-between px-6 py-4 text-sm">
          <Link
            href="/"
            className="flex items-center gap-2 text-base font-medium tracking-tight"
          >
            <BrandLogo size={20} />
            Daisy
          </Link>
          <nav className="flex items-center gap-5 text-[color:var(--color-ink-secondary)]">
            <Link
              href="/#features"
              className="hover:text-[color:var(--color-ink)]"
            >
              How it works
            </Link>
            <Link href="/docs" className="hover:text-[color:var(--color-ink)]">
              Docs
            </Link>
            <TrackedLink
              href="https://github.com/addicted-studio/daisy-app"
              event="github_view"
              eventProperties={{ source: "granola_nav" }}
              target="_blank"
              rel="noreferrer"
              className="hover:text-[color:var(--color-ink)]"
            >
              GitHub
            </TrackedLink>
          </nav>
        </div>
      </header>

      <article className="mx-auto max-w-3xl px-6 py-16">
        <p className="mb-3 text-xs font-medium uppercase tracking-widest text-[color:var(--color-ink-tertiary)]">
          Alternative · Comparison
        </p>
        <h1 className="font-display text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
          Looking for a Granola alternative that keeps audio on your Mac?
        </h1>
        <p className="mt-6 text-lg leading-relaxed text-[color:var(--color-ink-secondary)]">
          Daisy is an open-source, local-first meeting recorder for macOS.
          Audio never leaves your machine, transcription runs on the Apple
          Neural Engine, summaries use your own AI key, and a local MCP
          server lets Claude Desktop or Cursor query your transcripts
          without a round-trip through anyone&rsquo;s cloud.
        </p>

        <div className="mt-10 flex flex-wrap items-center gap-3">
          <TrackedLink
            href={LATEST_DMG_URL}
            event="download_dmg"
            eventProperties={{ source: "granola_hero" }}
            className="inline-flex items-center gap-2 rounded-xl bg-[color:var(--color-ink)] px-6 py-3.5 text-base font-medium text-[color:var(--color-bg)] transition-opacity hover:opacity-90"
          >
            Download Daisy for Mac
          </TrackedLink>
          <TrackedLink
            href="https://github.com/addicted-studio/daisy-app"
            event="github_view"
            eventProperties={{ source: "granola_hero" }}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-2 rounded-xl border border-[color:var(--color-divider)] px-6 py-3.5 text-base font-medium text-[color:var(--color-ink)] hover:bg-[color:var(--color-bg-sidebar)]"
          >
            View on GitHub
          </TrackedLink>
        </div>
        <p className="mt-3 text-xs text-[color:var(--color-ink-tertiary)]">
          Free during beta · Lifetime after launch · Apple Silicon (M1+) · macOS 14+
        </p>

        <h2 className="mt-16 font-display text-2xl font-semibold tracking-tight">
          Daisy vs Granola at a glance
        </h2>
        <div className="mt-6 overflow-x-auto rounded-2xl border border-[color:var(--color-divider)]">
          <table className="w-full text-left text-sm">
            <thead className="bg-[color:var(--color-bg-elevated)] text-[color:var(--color-ink-secondary)]">
              <tr>
                <th className="px-4 py-3 font-medium">Feature</th>
                <th className="px-4 py-3 font-medium">Daisy</th>
                <th className="px-4 py-3 font-medium">Granola</th>
              </tr>
            </thead>
            <tbody>
              {COMPARISON.map((row) => (
                <tr
                  key={row.feature}
                  className="border-t border-[color:var(--color-divider)] align-top"
                >
                  <td className="px-4 py-3 font-medium">{row.feature}</td>
                  <td className="px-4 py-3 text-[color:var(--color-ink-primary)]">
                    {row.daisy}
                  </td>
                  <td className="px-4 py-3 text-[color:var(--color-ink-secondary)]">
                    {row.granola}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <div className="mt-16 space-y-12">
          {PROSE.map((s) => (
            <section key={s.h}>
              <h2 className="font-display text-2xl font-semibold tracking-tight">
                {s.h}
              </h2>
              <p className="mt-4 text-base leading-relaxed text-[color:var(--color-ink-secondary)]">
                {s.body}
              </p>
            </section>
          ))}
        </div>

        <section className="mt-16 rounded-2xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] p-8">
          <h2 className="font-display text-2xl font-semibold tracking-tight">
            Try Daisy
          </h2>
          <p className="mt-3 text-base leading-relaxed text-[color:var(--color-ink-secondary)]">
            Free during beta. Download the signed DMG, drop it into
            Applications, grant microphone + screen-recording permissions
            on first launch, and start recording. No account, no email
            wall, nothing to sync.
          </p>
          <div className="mt-6 flex flex-wrap items-center gap-3">
            <TrackedLink
              href={LATEST_DMG_URL}
              event="download_dmg"
              eventProperties={{ source: "granola_bottom" }}
              className="inline-flex items-center gap-2 rounded-xl bg-[color:var(--color-ink)] px-5 py-3 text-sm font-medium text-[color:var(--color-bg)] hover:opacity-90"
            >
              Download for Mac
            </TrackedLink>
            <Link
              href="/docs/getting-started/installation"
              className="inline-flex items-center gap-2 rounded-xl border border-[color:var(--color-divider)] px-5 py-3 text-sm font-medium text-[color:var(--color-ink)] hover:bg-[color:var(--color-bg-sidebar)]"
            >
              Install guide →
            </Link>
          </div>
        </section>

        <p className="mt-16 text-sm text-[color:var(--color-ink-tertiary)]">
          More comparisons:{" "}
          <Link
            href="/alternatives/otter"
            className="underline underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            Otter
          </Link>
          {" · "}
          <Link
            href="/alternatives/apple"
            className="underline underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            Apple&rsquo;s built-in apps
          </Link>
        </p>

        <p className="mt-6 border-t border-[color:var(--color-divider)] pt-8 text-sm text-[color:var(--color-ink-tertiary)]">
          Comparison written by the Daisy team. Granola positioning verified
          against{" "}
          <Link
            href="https://www.granola.ai"
            target="_blank"
            rel="noreferrer"
            className="underline underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            granola.ai
          </Link>
          {" "}as of June 2026. If anything is out of date or wrong, open an
          issue at{" "}
          <Link
            href="https://github.com/addicted-studio/daisy-app/issues"
            target="_blank"
            rel="noreferrer"
            className="underline underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            github.com/addicted-studio/daisy-app/issues
          </Link>
          {" "}and we&rsquo;ll fix it.
        </p>
      </article>
    </main>
  );
}
