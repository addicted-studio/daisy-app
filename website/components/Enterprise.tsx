import Link from "next/link";
import { Eyebrow } from "./Eyebrow";

// Enterprise positioning section.
//
// The wedge: every cloud meeting tool (Granola, Otter, Fathom,
// Cleft, Shadow) requires a vendor relationship — a DPA, a sub-
// processor list, and a SaaS plane that holds the customer's
// transcripts. Daisy doesn't have that plane. There's no server
// to subpoena, no DPA to negotiate, no SOC 2 attestation to wait
// on, because the data path is "your Mac talking to your Mac".
//
// That structural fact is the entire pitch here. The four bullets
// reframe what enterprises usually fear ("does this leak our IP?")
// into things Daisy makes literally impossible by construction.
//
// Tone: serious, no marketing exclamation. The buyers here are
// CISOs, legal, IT — they read terms-of-service for sport. Confident
// understatement reads as competent. The CTA is a quiet mailto;
// not a Stripe link, not a "Book a demo" widget. The kind of
// company that wants Daisy will email.

const ENTERPRISE_POINTS = [
  {
    title: "No DPA to sign",
    body:
      "There's no Daisy server holding your transcripts, so there's no data processor to designate. Your IT counsel doesn't need to negotiate terms with us — we're not in the data path.",
  },
  {
    title: "Your AI vendor, your contract",
    body:
      "Daisy is BYOK across Anthropic, OpenAI, Apple Intelligence, and any local model (Ollama, LM Studio, or an MCP server). If your company already has an Anthropic enterprise contract or a self-hosted LLM, summaries run on that. No second AI bill.",
  },
  {
    title: "Open source",
    body:
      "Daisy ships under Apache 2.0 with full public source on GitHub. Your security team can read every line, build it from source, and verify there's no telemetry — instead of taking our word for it.",
  },
  {
    title: "Mac-native, signed, notarised",
    body:
      "Hardened Runtime, Apple Developer ID signed, notarised by Apple, distributed as a DMG. MDM-friendly. No Electron, no third-party update channel, no Chromium runtime to patch.",
  },
];

export function Enterprise() {
  return (
    <section
      id="enterprise"
      className="relative border-t border-[color:var(--color-divider)] px-6 py-24 md:py-32"
    >
      <div className="mx-auto max-w-5xl">
        <Eyebrow>For teams &amp; enterprise</Eyebrow>
        <h2 className="mb-6 max-w-3xl font-display text-3xl font-semibold leading-tight tracking-tight md:text-4xl">
          The compliance review is short, because there&rsquo;s nothing
          to review.
        </h2>
        <p className="mb-16 max-w-3xl text-lg leading-relaxed text-[color:var(--color-ink-secondary)]">
          Daisy was designed for the meeting-tool category that
          can&rsquo;t exist in a sanctioned-data environment.
          Transcripts stay on the laptop they were recorded on. There
          is no Daisy cloud to audit, no third-party subprocessor list,
          no vendor pipeline carrying your customer conversations to a
          server you don&rsquo;t own.
        </p>

        <div className="grid gap-4 md:grid-cols-2">
          {ENTERPRISE_POINTS.map((p) => (
            <div
              key={p.title}
              className="rounded-2xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] p-6"
            >
              <h3 className="mb-2 font-display text-base font-semibold tracking-tight">
                {p.title}
              </h3>
              <p className="text-sm leading-relaxed text-[color:var(--color-ink-secondary)]">
                {p.body}
              </p>
            </div>
          ))}
        </div>

        {/* Teaser link to the full /enterprise page — this homepage
            section is the summary; the dedicated page carries the
            out-of-the-box capabilities, the custom-build offer, and
            licensing. */}
        <div className="mt-8">
          <Link
            href="/enterprise"
            className="inline-flex items-center gap-1.5 text-sm font-medium text-[color:var(--color-ink)] underline decoration-[color:var(--color-divider)] underline-offset-4 transition-colors hover:text-[color:var(--color-ink-secondary)]"
          >
            Daisy for teams &amp; enterprise — the full overview →
          </Link>
        </div>

        {/* Quiet CTA — a mailto and a link to the source. The kind
            of buyer who needs this section will reach out via email,
            not a "Book a demo" calendar. */}
        <div className="mt-12 flex flex-col items-start gap-4 rounded-2xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-sidebar)] p-6 md:flex-row md:items-center md:justify-between">
          <div className="max-w-2xl">
            <p className="font-display text-base font-semibold tracking-tight">
              Procurement, security questionnaire, or a tailored
              deployment?
            </p>
            <p className="mt-1 text-sm leading-relaxed text-[color:var(--color-ink-secondary)]">
              Email us and a human responds &mdash; usually same day,
              from Europe time. We&rsquo;re a small team and we like
              talking to other small teams.
            </p>
          </div>
          <div className="flex flex-wrap items-center gap-3">
            <Link
              href="mailto:essazanov@pm.me?subject=Daisy%20for%20teams"
              className="inline-flex items-center gap-2 rounded-xl bg-[color:var(--color-ink)] px-5 py-3 text-sm font-medium text-[color:var(--color-bg)] transition-opacity hover:opacity-90"
            >
              Email the team
            </Link>
            <Link
              href="https://github.com/addicted-studio/daisy-app"
              target="_blank"
              rel="noreferrer"
              className="inline-flex items-center gap-1.5 rounded-xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] px-5 py-3 text-sm font-medium text-[color:var(--color-ink)] transition-colors hover:bg-[color:var(--color-bg-sidebar)]"
            >
              Read the source →
            </Link>
          </div>
        </div>
      </div>
    </section>
  );
}
