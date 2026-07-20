import type { Metadata } from "next";
import Link from "next/link";
import { Eyebrow } from "@/components/Eyebrow";
import { Footer } from "@/components/Footer";

// /enterprise — deliberately minimal.
//
// Reviewed through legal / critic / essentialist lenses (2026-06-24) and
// cut hard per the owner's brief: minimum information, capability focus,
// no specifics and no commitments. Three capability ideas carry it —
// no data plane, your own AI, open source — plus one soft line that
// custom work is possible, and a quiet CTA. No named tools, no licensing
// instruments (warranty/indemnity/SLA/brand), no absolute "no X" claims,
// no telling the buyer their review is optional. Specifics, if ever
// wanted, belong on a linked docs/security page — not here.

export const metadata: Metadata = {
  title: "Daisy for teams & enterprise",
  description:
    "Local-first meeting recording designed around having no vendor data plane. Bring your own AI, open source and auditable. Custom team, server, and managed deployments possible on request.",
};

const PILLARS = [
  {
    title: "No data plane to review",
    body:
      "There's no Daisy server holding your conversations. Recording, transcription and summaries happen on the device — so the questions that usually slow a security review tend not to apply.",
  },
  {
    title: "Your AI, your infrastructure",
    body:
      "Point Daisy at your own model or AI provider. Transcripts go to the endpoint you choose, rather than to a service we operate.",
  },
  {
    title: "Open and auditable",
    body:
      "The full source is public and open-licensed. Your team can read it and build it themselves — and confirm what it does, instead of taking our word for it.",
  },
];

export default function EnterprisePage() {
  return (
    <main className="relative z-0">
      <div className="mx-auto max-w-5xl px-6 pt-10 pb-24 md:pt-16 md:pb-32">
        <Link
          href="/"
          className="mb-12 inline-block text-sm text-[color:var(--color-ink-tertiary)] underline decoration-[color:var(--color-divider)] underline-offset-4 transition-colors hover:text-[color:var(--color-ink)]"
        >
          ← Daisy
        </Link>

        <Eyebrow>For teams &amp; enterprise</Eyebrow>
        <h1 className="mb-6 max-w-3xl font-display text-3xl font-semibold leading-tight tracking-tight md:text-5xl">
          Local-first meeting capture, with no vendor in the middle.
        </h1>
        <p className="mb-20 max-w-3xl text-lg leading-relaxed text-[color:var(--color-ink-secondary)]">
          Daisy records, transcribes and summarises on the Mac it runs on.
          When you connect AI, transcripts go to the endpoint you choose —
          not through a Daisy service. That tends to shorten the security
          review considerably.
        </p>

        <div className="grid gap-4 md:grid-cols-3">
          {PILLARS.map((p) => (
            <div
              key={p.title}
              className="rounded-2xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] p-6"
            >
              <h2 className="mb-2 font-display text-base font-semibold tracking-tight">
                {p.title}
              </h2>
              <p className="text-sm leading-relaxed text-[color:var(--color-ink-secondary)]">
                {p.body}
              </p>
            </div>
          ))}
        </div>

        <p className="mt-16 max-w-3xl text-base leading-relaxed text-[color:var(--color-ink-secondary)]">
          Need shared team notes, a server-backed deployment, or a managed
          rollout across a fleet? That goes beyond the local app — it&rsquo;s
          possible as custom work. Tell us the shape and we&rsquo;ll talk
          through what&rsquo;s feasible.
        </p>

        <div className="mt-12 flex flex-col items-start gap-4 rounded-2xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-sidebar)] p-6 md:flex-row md:items-center md:justify-between">
          <div className="max-w-2xl">
            <p className="font-display text-base font-semibold tracking-tight">
              Procurement, a security questionnaire, or a tailored
              deployment?
            </p>
            <p className="mt-1 text-sm leading-relaxed text-[color:var(--color-ink-secondary)]">
              Email us and a human responds.
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

      <Footer />
    </main>
  );
}
