import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Support",
  description:
    "How to get help with Daisy — direct email contact, FAQ, and GitHub for bug reports and feature requests.",
};

export default function SupportPage() {
  return (
    <main className="relative z-0 mx-auto max-w-3xl px-6 py-24 md:py-32">
      <Link
        href="/"
        className="mb-12 inline-block text-sm text-[color:var(--color-ink-tertiary)] underline decoration-[color:var(--color-divider)] underline-offset-4 transition-colors hover:text-[color:var(--color-ink)]"
      >
        ← Daisy
      </Link>

      <p className="mb-3 text-sm font-medium uppercase tracking-widest text-[color:var(--color-ink-tertiary)]">
        Support
      </p>
      <h1 className="mb-6 font-display text-4xl font-semibold leading-tight tracking-tight md:text-5xl">
        Stuck? Want a feature?
      </h1>
      <p className="mb-16 text-lg leading-relaxed text-[color:var(--color-ink-secondary)]">
        Daisy is a small, open source app — no support ticketing
        system, no chatbot. Email me, or open an issue on GitHub.
        I&rsquo;ll see it.
      </p>

      <section className="mb-12 space-y-6">
        <h2 className="font-display text-2xl font-semibold tracking-tight">
          Email
        </h2>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Direct line:{" "}
          <Link
            href="mailto:essazanov@pm.me"
            className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            essazanov@pm.me
          </Link>
          . Best for anything personal, or anything where attaching a
          file or log makes sense. Replies are usually within a day.
        </p>
      </section>

      <section className="mb-12 space-y-6">
        <h2 className="font-display text-2xl font-semibold tracking-tight">
          GitHub
        </h2>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Source code, issue tracker and changelog live at{" "}
          <Link
            href="https://github.com/addicted-studio/daisy-app"
            target="_blank"
            rel="noreferrer"
            className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            github.com/addicted-studio/daisy-app
          </Link>
          . Open an issue for bug reports and feature requests — they
          stay public, so other users can chime in.
        </p>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Templates are wired up for both:{" "}
          <Link
            href="https://github.com/addicted-studio/daisy-app/issues/new?template=bug_report.yml"
            target="_blank"
            rel="noreferrer"
            className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            bug report
          </Link>
          {" · "}
          <Link
            href="https://github.com/addicted-studio/daisy-app/issues/new?template=feature_request.yml"
            target="_blank"
            rel="noreferrer"
            className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            feature request
          </Link>
          .
        </p>
      </section>

      <section className="mb-12 space-y-6">
        <h2 className="font-display text-2xl font-semibold tracking-tight">
          Guides
        </h2>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Step-by-step walkthroughs for specific integrations:
        </p>
        <ul className="space-y-2 text-[color:var(--color-ink-secondary)] leading-relaxed">
          <li>
            <Link
              href="/docs/mcp"
              className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
            >
              Connect Daisy to Claude, Cursor, or any MCP client
            </Link>{" "}
            — read your sessions from any AI client on the same Mac.
          </li>
        </ul>
      </section>

      <section className="mb-12 space-y-6">
        <h2 className="font-display text-2xl font-semibold tracking-tight">
          Frequently asked
        </h2>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Common questions about supported Macs, transcription
          languages, AI-key setup, billing, and licensing live on the{" "}
          <Link
            href="/#faq"
            className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            FAQ on the home page
          </Link>
          . If your question isn&rsquo;t answered there, email me — that&rsquo;s how
          the FAQ grows.
        </p>
      </section>

      <section className="space-y-6">
        <h2 className="font-display text-2xl font-semibold tracking-tight">
          Privacy
        </h2>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          What Daisy collects (close to nothing) and how the website
          handles your visit is documented on the{" "}
          <Link
            href="/privacy"
            className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            Privacy page
          </Link>
          .
        </p>
      </section>
    </main>
  );
}
