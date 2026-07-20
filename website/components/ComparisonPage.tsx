import Link from "next/link";
import { BrandLogo } from "@/components/BrandLogo";
import { TrackedLink } from "@/components/TrackedLink";
import { LATEST_DMG_URL } from "@/lib/latestVersion";

// Shared chrome for every /alternatives/* comparison page.
//
// Extracted (2026-06-24) so new comparisons are ~40 lines of data
// instead of a ~250-line copy of the granola page. Keeps the set
// visually consistent — one place to restyle. Each page.tsx exports
// its own `metadata` (Next.js requires that at the page level) and
// renders <ComparisonPage {...data} />.
//
// Deliberately lean per the owner's brief: hero + a short table +
// ONE honest "where they're ahead" section + CTA + a sourced
// disclaimer. No multi-section prose. The granola page predates this
// component and keeps its longer form for now.

export type ComparisonRow = {
  feature: string;
  daisy: string;
  them: string;
};

export type ComparisonPageProps = {
  /** Display name of the rival, e.g. "Otter". */
  competitor: string;
  /** Slug used for analytics event source, e.g. "otter". */
  slug: string;
  /** Column header for the rival's column, e.g. "Otter" or "Apple (built-in)". */
  themColumn: string;
  h1: string;
  lede: string;
  rows: ComparisonRow[];
  tableTitle: string;
  aheadTitle: string;
  aheadBody: string;
  /** Footer source attribution. */
  sourceLabel: string;
  sourceUrl: string;
  asOf: string;
  /** The other comparison pages, for cross-linking. */
  crossLinks: { label: string; href: string }[];
};

export function ComparisonPage(props: ComparisonPageProps) {
  const {
    competitor,
    slug,
    themColumn,
    h1,
    lede,
    rows,
    tableTitle,
    aheadTitle,
    aheadBody,
    sourceLabel,
    sourceUrl,
    asOf,
    crossLinks,
  } = props;

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
            <Link href="/#features" className="hover:text-[color:var(--color-ink)]">
              How it works
            </Link>
            <Link href="/docs" className="hover:text-[color:var(--color-ink)]">
              Docs
            </Link>
            <TrackedLink
              href="https://github.com/addicted-studio/daisy-app"
              event="github_view"
              eventProperties={{ source: `${slug}_nav` }}
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
          {h1}
        </h1>
        <p className="mt-6 text-lg leading-relaxed text-[color:var(--color-ink-secondary)]">
          {lede}
        </p>

        <div className="mt-10 flex flex-wrap items-center gap-3">
          <TrackedLink
            href={LATEST_DMG_URL}
            event="download_dmg"
            eventProperties={{ source: `${slug}_hero` }}
            className="inline-flex items-center gap-2 rounded-xl bg-[color:var(--color-ink)] px-6 py-3.5 text-base font-medium text-[color:var(--color-bg)] transition-opacity hover:opacity-90"
          >
            Download Daisy for Mac
          </TrackedLink>
          <TrackedLink
            href="https://github.com/addicted-studio/daisy-app"
            event="github_view"
            eventProperties={{ source: `${slug}_hero` }}
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
          {tableTitle}
        </h2>
        <div className="mt-6 overflow-x-auto rounded-2xl border border-[color:var(--color-divider)]">
          <table className="w-full text-left text-sm">
            <thead className="bg-[color:var(--color-bg-elevated)] text-[color:var(--color-ink-secondary)]">
              <tr>
                <th className="px-4 py-3 font-medium">Feature</th>
                <th className="px-4 py-3 font-medium">Daisy</th>
                <th className="px-4 py-3 font-medium">{themColumn}</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr
                  key={row.feature}
                  className="border-t border-[color:var(--color-divider)] align-top"
                >
                  <td className="px-4 py-3 font-medium">{row.feature}</td>
                  <td className="px-4 py-3 text-[color:var(--color-ink-primary)]">
                    {row.daisy}
                  </td>
                  <td className="px-4 py-3 text-[color:var(--color-ink-secondary)]">
                    {row.them}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        <section className="mt-16">
          <h2 className="font-display text-2xl font-semibold tracking-tight">
            {aheadTitle}
          </h2>
          <p className="mt-4 text-base leading-relaxed text-[color:var(--color-ink-secondary)]">
            {aheadBody}
          </p>
        </section>

        <section className="mt-16 rounded-2xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] p-8">
          <h2 className="font-display text-2xl font-semibold tracking-tight">
            Try Daisy
          </h2>
          <p className="mt-3 text-base leading-relaxed text-[color:var(--color-ink-secondary)]">
            Free during beta. Download the signed DMG, drop it into
            Applications, grant the permissions on first launch, and start
            recording. No account, no email wall, nothing to sync.
          </p>
          <div className="mt-6 flex flex-wrap items-center gap-3">
            <TrackedLink
              href={LATEST_DMG_URL}
              event="download_dmg"
              eventProperties={{ source: `${slug}_bottom` }}
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

        {crossLinks.length > 0 ? (
          <p className="mt-16 text-sm text-[color:var(--color-ink-tertiary)]">
            More comparisons:{" "}
            {crossLinks.map((c, i) => (
              <span key={c.href}>
                <Link
                  href={c.href}
                  className="underline underline-offset-4 hover:text-[color:var(--color-ink)]"
                >
                  {c.label}
                </Link>
                {i < crossLinks.length - 1 ? " · " : ""}
              </span>
            ))}
          </p>
        ) : null}

        <p className="mt-6 border-t border-[color:var(--color-divider)] pt-8 text-sm text-[color:var(--color-ink-tertiary)]">
          Comparison written by the Daisy team. {competitor} positioning
          verified against{" "}
          <Link
            href={sourceUrl}
            target="_blank"
            rel="noreferrer"
            className="underline underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            {sourceLabel}
          </Link>{" "}
          as of {asOf}. If anything is out of date or wrong, open an issue at{" "}
          <Link
            href="https://github.com/addicted-studio/daisy-app/issues"
            target="_blank"
            rel="noreferrer"
            className="underline underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            github.com/addicted-studio/daisy-app/issues
          </Link>{" "}
          and we&rsquo;ll fix it.
        </p>
      </article>
    </main>
  );
}
