import type { Metadata } from "next";
import Link from "next/link";
import { readFile } from "node:fs/promises";
import path from "node:path";

import { BrandLogo } from "@/components/BrandLogo";

// /changelog — rendered from the same `public/appcast.xml` that
// Sparkle uses to serve auto-updates. Single source of truth: when
// release.sh injects a new <item> for users on Sparkle, this page
// picks it up on the next build / ISR refresh.
//
// Recommended by the 2026-05-23 pre-PH audit. The objection it
// closes: "open source repos without a visible changelog feel
// abandoned." Daisy has shipped 11 releases in 48 hours but a
// drive-by visitor sees nothing — that's the problem this page
// fixes.
//
// Failure mode: if the file can't be read (e.g. dev mode + path
// mismatch), the page renders an empty state pointing at GitHub
// releases. Better than a 500.

export const metadata: Metadata = {
  title: "Changelog — Daisy",
  description:
    "Every Daisy release with notes. Same source of truth Sparkle uses to push auto-updates — when a new version ships, this page updates with it.",
  alternates: {
    canonical: "https://mydaisy.io/changelog",
  },
};

interface Release {
  version: string;
  build: string;
  pubDate: string;
  descriptionHtml: string;
}

// Parse the small handful of <item> blocks we care about out of
// appcast.xml. The file is short enough (~300 lines) that a hand-
// rolled regex pass is simpler than pulling in an XML library
// just for this. Each <item> has predictable structure produced
// by release.sh, so we can assume well-formed input.
function parseAppcast(xml: string): Release[] {
  const items: Release[] = [];
  const itemRegex = /<item>([\s\S]*?)<\/item>/g;
  let match: RegExpExecArray | null;
  while ((match = itemRegex.exec(xml)) !== null) {
    const block = match[1];
    const version =
      block.match(
        /<sparkle:shortVersionString>(.*?)<\/sparkle:shortVersionString>/,
      )?.[1] ?? "";
    const build =
      block.match(/<sparkle:version>(.*?)<\/sparkle:version>/)?.[1] ?? "";
    const pubDate = block.match(/<pubDate>(.*?)<\/pubDate>/)?.[1] ?? "";
    const descriptionHtml =
      block
        .match(/<description><!\[CDATA\[([\s\S]*?)\]\]><\/description>/)?.[1]
        .trim() ?? "";
    if (version && build) {
      items.push({ version, build, pubDate, descriptionHtml });
    }
  }
  // Newest first.
  return items.sort((a, b) => Number(b.build) - Number(a.build));
}

function formatPubDate(raw: string): string {
  // Pub dates look like `Fri, 22 May 2026 09:19:50 +0000`.
  try {
    const d = new Date(raw);
    if (Number.isNaN(d.getTime())) return raw;
    return d.toLocaleDateString("en-GB", {
      day: "numeric",
      month: "short",
      year: "numeric",
    });
  } catch {
    return raw;
  }
}

async function loadReleases(): Promise<Release[]> {
  try {
    const filePath = path.join(process.cwd(), "public", "appcast.xml");
    const xml = await readFile(filePath, "utf-8");
    return parseAppcast(xml);
  } catch {
    return [];
  }
}

export default async function ChangelogPage() {
  const releases = await loadReleases();

  return (
    <main className="relative z-0 min-h-screen bg-[color:var(--color-bg)] text-[color:var(--color-ink-primary)]">
      <header className="border-b border-[color:var(--color-divider)]">
        <div className="mx-auto flex max-w-4xl items-center justify-between px-6 py-4 text-sm">
          <Link
            href="/"
            className="flex items-center gap-2 text-base font-medium tracking-tight"
          >
            <BrandLogo size={20} />
            Daisy
          </Link>
          <nav className="flex items-center gap-5 text-[color:var(--color-ink-secondary)]">
            <Link href="/docs" className="hover:text-[color:var(--color-ink)]">
              Docs
            </Link>
            <Link
              href="https://github.com/addicted-studio/daisy-app"
              target="_blank"
              rel="noreferrer"
              className="hover:text-[color:var(--color-ink)]"
            >
              GitHub
            </Link>
          </nav>
        </div>
      </header>

      <article className="mx-auto max-w-3xl px-6 py-16">
        <p className="mb-3 text-xs font-medium uppercase tracking-widest text-[color:var(--color-ink-tertiary)]">
          Releases
        </p>
        <h1 className="font-display text-3xl font-semibold leading-tight tracking-tight md:text-4xl">
          Changelog
        </h1>
        <p className="mt-4 max-w-2xl text-base leading-relaxed text-[color:var(--color-ink-secondary)]">
          Every Daisy release with notes. Sourced from the same{" "}
          <code className="rounded bg-[color:var(--color-bg-elevated)] px-1 py-0.5 text-sm">
            appcast.xml
          </code>{" "}
          Sparkle uses to serve auto-updates — when a new version
          ships, this page reflects it.
        </p>

        {releases.length === 0 ? (
          <div className="mt-12 rounded-2xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] p-6 text-sm text-[color:var(--color-ink-secondary)]">
            Changelog feed isn&rsquo;t available right now. Check the{" "}
            <Link
              href="https://github.com/addicted-studio/daisy-app/releases"
              target="_blank"
              rel="noreferrer"
              className="underline underline-offset-4 hover:text-[color:var(--color-ink)]"
            >
              GitHub Releases page
            </Link>
            {" "}for the latest version.
          </div>
        ) : (
          <div className="mt-12 space-y-12">
            {releases.map((r) => (
              <section
                key={`${r.version}-${r.build}`}
                className="border-b border-[color:var(--color-divider)] pb-12 last:border-b-0"
              >
                <div className="flex flex-wrap items-baseline justify-between gap-3">
                  <h2 className="font-display text-2xl font-semibold tracking-tight">
                    Daisy {r.version}
                  </h2>
                  <p className="text-xs text-[color:var(--color-ink-tertiary)]">
                    build {r.build} · {formatPubDate(r.pubDate)}
                  </p>
                </div>
                <div
                  className="prose prose-sm mt-4 max-w-none text-[color:var(--color-ink-secondary)] prose-headings:font-display prose-headings:text-[color:var(--color-ink-primary)] prose-strong:text-[color:var(--color-ink-primary)] prose-li:my-1.5"
                  // Release notes come from our own CDATA-wrapped HTML
                  // in appcast.xml, produced by release.sh from the
                  // `scripts/release-notes/<version>.md` files in the
                  // Daisy repo. We control both sides; no untrusted
                  // input. dangerouslySetInnerHTML is appropriate.
                  dangerouslySetInnerHTML={{ __html: r.descriptionHtml }}
                />
              </section>
            ))}
          </div>
        )}

        <p className="mt-16 border-t border-[color:var(--color-divider)] pt-8 text-sm text-[color:var(--color-ink-tertiary)]">
          Auto-updates handled by Sparkle. If you already have Daisy
          installed, open About → Check for Updates… or wait for the
          daily background check.
        </p>
      </article>
    </main>
  );
}
