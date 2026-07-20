import Link from "next/link";
import { HeroAnimation } from "./HeroAnimation";
import { BrandLogo } from "./BrandLogo";
import { TrackedLink } from "./TrackedLink";
import { DownloadPicker } from "./DownloadPicker";
import { LATEST_DMG_URL } from "../lib/latestVersion";
import { HAS_NEWER_BETA, DOWNLOAD_CHANNELS } from "../lib/downloadChannels";

export function Hero() {
  return (
    // Generous top padding gives the nav breathing room — matches
    // Linear / Vercel / Apple product-page nav rhythm. The previous
    // pt-12/16 + mb-20 had nav crammed into chrome.
    <section className="relative overflow-hidden px-6 pt-6 pb-16 md:pt-10 md:pb-24">
      <div className="mx-auto max-w-5xl">
        {/* Tiny nav row.
            Mobile (< md): only the logo is visible. Secondary nav
            links would overflow the 375px viewport (logo + 5 links +
            4 gaps ≈ 550px wide), which triggered horizontal page
            scroll on iPhone Safari. Users on mobile come from social
            and scroll vertically anyway — the section anchors are
            still accessible via the docs and footer surface. */}
        <nav className="mb-12 flex items-center justify-between text-sm">
          <div className="flex items-center gap-2 text-base font-medium tracking-tight">
            <BrandLogo size={20} />
            Daisy
          </div>
          <div className="hidden items-center gap-6 text-[color:var(--color-ink-secondary)] md:flex">
            <Link href="#features" className="hover:text-[color:var(--color-ink)] transition-colors">
              How it works
            </Link>
            <Link href="#mcp" className="hover:text-[color:var(--color-ink)] transition-colors">
              MCP
            </Link>
            <Link href="#privacy" className="hover:text-[color:var(--color-ink)] transition-colors">
              Privacy
            </Link>
            <Link href="#faq" className="hover:text-[color:var(--color-ink)] transition-colors">
              FAQ
            </Link>
            <Link href="/docs" className="hover:text-[color:var(--color-ink)] transition-colors">
              Docs
            </Link>
          </div>
          {/* Mobile-only: single "Docs" link so visitors can still
              reach the wiki from the top of the page without the
              fuller desktop nav. */}
          <div className="md:hidden">
            <Link
              href="/docs"
              className="text-[color:var(--color-ink-secondary)] hover:text-[color:var(--color-ink)] transition-colors"
            >
              Docs →
            </Link>
          </div>
        </nav>

        <div className="grid items-center gap-8 md:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
          {/* Copy */}
          <div className="min-w-0">
            {/* Pill cluster — was a single "Made for Apple Silicon"
                badge. Switched to a 4-pill row of differentiators
                after the pre-PH SEO + conversion audit (2026-05-23,
                see business/research/2026-05-23-mydaisy-io-audit-pre-ph)
                — VoiceInk / Memcircle both put 3-4 trust pills in
                this exact slot directly under the H1, and ours
                carried one weak signal in prime real estate. The
                recording-orange dot stays only on the first pill
                (echoes the macOS mic indicator we already use across
                the brand) so the row reads as one cohesive badge
                rather than four equal-weight chips fighting. */}
            <div className="mb-6 flex flex-wrap items-center gap-2">
              <div className="inline-flex items-center gap-2 rounded-full border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] px-3 py-1 text-xs font-medium text-[color:var(--color-ink-secondary)]">
                Open source
              </div>
              <div className="inline-flex items-center gap-2 rounded-full border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] px-3 py-1 text-xs font-medium text-[color:var(--color-ink-secondary)]">
                Local-first
              </div>
              <div className="inline-flex items-center gap-2 rounded-full border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] px-3 py-1 text-xs font-medium text-[color:var(--color-ink-secondary)]">
                MCP-native
              </div>
              <div className="inline-flex items-center gap-2 rounded-full border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] px-3 py-1 text-xs font-medium text-[color:var(--color-ink-secondary)]">
                No subscription
              </div>
            </div>

            {/* Headline rewrite (2026-05-23, pre-PH audit):
                was "Your transcripts. Your AI. Your destinations." —
                three possessive nouns that read as poetry but never
                tell a first-time visitor what Daisy *is*. Memcircle
                and the rest of the meeting-recorder space lead H1
                with category + verb ("AI meeting recorder that works
                everywhere"); we were the only one without a verb,
                which made first-visit comprehension take ~5 seconds
                of subhead-reading instead of 1 second of headline
                scan. New version: verb + category + privacy spike,
                with the poetic triad demoted to the sub-headline
                where its rhythm still earns its keep without
                blocking comprehension.

                Mobile sizing follows the same logic as before:
                hard-coded line break below md keeps the two phrases
                on separate lines rather than wrapping mid-sentence
                on a 375px viewport, which reads as deliberate
                rhythm. From md up the headline reflows naturally. */}
            <h1 className="font-display text-2xl font-semibold leading-[1.1] tracking-tight [overflow-wrap:break-word] sm:text-3xl md:text-5xl lg:text-6xl">
              Record meetings on your Mac.{" "}
              <br className="md:hidden" />
              <span className="text-[color:var(--color-ink-secondary)]">
                Keep them on your Mac.
              </span>
            </h1>

            {/* Poetic triad demoted from H1 to a sub-headline so it
                still leads the description rhythm. Old positioning
                was "internally beautiful, externally vague" — here
                it carries weight as cadence ahead of the prose. */}
            <p className="mt-4 max-w-xl text-sm font-medium text-[color:var(--color-ink-tertiary)] sm:text-base">
              Your transcripts. Your AI. Your destinations.
            </p>

            <p className="mt-3 max-w-xl text-base leading-relaxed text-[color:var(--color-ink-secondary)] sm:text-lg">
              Daisy records meetings locally on your Mac, transcribes
              them on the Neural Engine, then exposes them as a local
              MCP server Claude Desktop and Cursor can query — or
              pushes them to Notion, Linear, Attio, or a webhook.
              Nothing leaves your machine unless you say so.
            </p>

            <div className="mt-10 flex flex-col items-stretch gap-3 sm:flex-row sm:flex-wrap">
              {/* Primary CTA — direct DMG link, not GitHub releases.
                  Most visitors aren't developers; sending them through
                  GitHub's release-page asset picker is friction. The
                  Apple mark earns its keep here as the universal "Mac
                  download" affordance. URL is sourced from
                  `lib/latestVersion.ts`, which release.sh auto-updates
                  on each ship — so we never serve a stale link. */}
              {HAS_NEWER_BETA ? (
                // A newer beta exists → mirror the closing section's
                // stable/new split here, sized for the hero row (md) and
                // left-aligned so the dropdown anchors under the button
                // and the segment stretches full-width beside GitHub on
                // mobile. Stable stays the default selection.
                <DownloadPicker
                  channels={DOWNLOAD_CHANNELS}
                  source="hero"
                  size="md"
                  align="start"
                  block
                />
              ) : (
                <TrackedLink
                  href={LATEST_DMG_URL}
                  event="download_dmg"
                  eventProperties={{ source: "hero" }}
                  className="inline-flex w-full items-center justify-center gap-2 rounded-xl bg-[color:var(--color-ink)] px-6 py-3.5 text-base font-medium text-[color:var(--color-bg)] transition-opacity hover:opacity-90 sm:w-auto"
                >
                  <svg
                    viewBox="0 0 384 512"
                    width="16"
                    height="16"
                    fill="currentColor"
                    aria-hidden="true"
                    className="-mt-0.5"
                  >
                    <path d="M318.7 268.7c-.2-36.7 16.4-64.4 50-84.8-18.8-26.9-47.2-41.7-84.7-44.6-35.5-2.8-74.3 20.7-88.5 20.7-15 0-49.4-19.7-76.4-19.7C63.3 141.2 4 184.8 4 273.5q0 39.3 14.4 81.2c12.8 36.7 59 126.7 107.2 125.2 25.2-.6 43-17.9 75.8-17.9 31.8 0 48.3 17.9 76.4 17.9 48.6-.7 90.4-82.5 102.6-119.3-65.2-30.7-61.7-90-61.7-91.9zm-56.6-164.2c27.3-32.4 24.8-61.9 24-72.5-24.1 1.4-52 16.4-67.9 34.9-17.5 19.8-27.8 44.3-25.6 71.9 26.1 2 49.9-11.4 69.5-34.3z" />
                  </svg>
                  Download for Mac
                </TrackedLink>
              )}
              {/* GitHub button + live star count via shields.io.
                  Static badge keeps the page a synchronous server
                  component (no GitHub API rate-limit risk, no auth
                  header dance). Recommended by 2026-05-23 pre-PH
                  audit — HN/Reddit/PH visitors scan for star count
                  as a fast credibility heuristic, and we had no
                  social-proof number anywhere above the fold. */}
              <TrackedLink
                href="https://github.com/addicted-studio/daisy-app"
                event="github_view"
                eventProperties={{ source: "hero" }}
                target="_blank"
                rel="noreferrer"
                className="inline-flex w-full items-center justify-center gap-2 rounded-xl border border-[color:var(--color-divider)] px-6 py-3.5 text-base font-medium text-[color:var(--color-ink)] transition-colors hover:bg-[color:var(--color-bg-sidebar)] sm:w-auto"
              >
                <svg
                  viewBox="0 0 16 16"
                  width="16"
                  height="16"
                  fill="currentColor"
                  aria-hidden="true"
                >
                  <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z" />
                </svg>
                View on GitHub
              </TrackedLink>
            </div>

            {/* Product Hunt follow badge (post-launch). Links to the
                product page so visitors can follow + upvote. Dark
                variant to match the single dark theme. Placed after the
                CTA row but before the small meta line so it reads as
                supplementary, not a competing primary action. */}
            <div className="mt-6">
              <a
                href="https://www.producthunt.com/products/daisy-4?utm_source=badge-follow&utm_medium=badge"
                target="_blank"
                rel="noreferrer noopener"
                className="inline-block"
                aria-label="Daisy on Product Hunt"
              >
                {/* eslint-disable-next-line @next/next/no-img-element */}
                <img
                  src="https://api.producthunt.com/widgets/embed-image/v1/follow.svg?product_id=1230297&theme=dark"
                  alt="Daisy — Record, transcribe, summarise — nothing leaves your Mac | Product Hunt"
                  width={250}
                  height={54}
                />
              </a>
            </div>

            {/* Two-line microcopy under the PH badge. Pricing line
                was added per the pre-PH audit — the #1 unspoken
                visitor objection on "AI tool free during beta" is
                "this is going to be a subscription later"; surfacing
                the lifetime commitment up front kills it cheaply
                (full reasoning in business/research/2026-05-23-mydaisy-io-audit-pre-ph).
                System-requirements line was the original microcopy,
                kept verbatim so Intel-Mac visitors don't burn a
                Download click. */}
            <p className="mt-4 text-xs text-[color:var(--color-ink-tertiary)]">
              Free during beta · Lifetime after launch — never a per-meeting subscription
            </p>
            <p className="mt-1 text-xs text-[color:var(--color-ink-tertiary)]">
              Apple Silicon (M1+) · macOS 14+
            </p>
          </div>

          {/* Animated mark + dialogue bubbles + transcript reveal */}
          <div className="flex min-w-0 justify-center md:justify-end">
            <HeroAnimation size={200} />
          </div>
        </div>
      </div>
    </section>
  );
}
