import { Eyebrow } from "./Eyebrow";
import { TrackedLink } from "./TrackedLink";
import { DownloadPicker } from "./DownloadPicker";
import { LATEST_DMG_URL } from "../lib/latestVersion";
import { HAS_NEWER_BETA, DOWNLOAD_CHANNELS } from "../lib/downloadChannels";

/** Apple mark shared by both download buttons. */
function AppleMark() {
  return (
    <svg
      viewBox="0 0 384 512"
      width="18"
      height="18"
      fill="currentColor"
      aria-hidden="true"
      className="-mt-0.5"
    >
      <path d="M318.7 268.7c-.2-36.7 16.4-64.4 50-84.8-18.8-26.9-47.2-41.7-84.7-44.6-35.5-2.8-74.3 20.7-88.5 20.7-15 0-49.4-19.7-76.4-19.7C63.3 141.2 4 184.8 4 273.5q0 39.3 14.4 81.2c12.8 36.7 59 126.7 107.2 125.2 25.2-.6 43-17.9 75.8-17.9 31.8 0 48.3 17.9 76.4 17.9 48.6-.7 90.4-82.5 102.6-119.3-65.2-30.7-61.7-90-61.7-91.9zm-56.6-164.2c27.3-32.4 24.8-61.9 24-72.5-24.1 1.4-52 16.4-67.9 34.9-17.5 19.8-27.8 44.3-25.6 71.9 26.1 2 49.9-11.4 69.5-34.3z" />
    </svg>
  );
}

export function Download() {
  return (
    <section
      id="download"
      className="relative border-t border-[color:var(--color-divider)] px-6 py-24 md:py-32"
    >
      <div className="mx-auto max-w-3xl text-center">
        <Eyebrow>Get Daisy</Eyebrow>
        {/* Downsized from text-5xl on md+ — Hero owns the page's
            single biggest headline. Closing CTA reads as "the
            answer to the rest of the page", not a competing hero. */}
        <h2 className="mb-6 font-display text-3xl font-semibold leading-tight tracking-tight md:text-4xl">
          Open source, on your Mac.
        </h2>
        <p className="mx-auto mb-10 max-w-xl text-lg leading-relaxed text-[color:var(--color-ink-secondary)]">
          Daisy is published on GitHub under Apache 2.0 &mdash; the source
          is there, the signed builds land on the Releases page as they
          ship. No email collection, no &ldquo;we&rsquo;ll let you
          know&rdquo;.
        </p>

        {HAS_NEWER_BETA ? (
          /* ── Stable / New select button ─────────────────────────
             One split button while a newer beta exists: the main
             segment downloads the selected channel (stable by
             default, so a visitor who never opens the menu gets the
             soaked build), the chevron opens a listbox with both
             versions. Client island — see DownloadPicker.tsx. */
          <div className="flex justify-center">
            <DownloadPicker channels={DOWNLOAD_CHANNELS} />
          </div>
        ) : (
          /* ── Classic single button (no newer beta published) ──── */
          <div className="flex flex-col items-center gap-3 sm:flex-row sm:justify-center">
            {/* Primary: direct DMG link with Apple mark — same pattern
                as Hero CTA, repeated near footer for users who scrolled
                past the hero without clicking. Both CTAs import
                `LATEST_DMG_URL` from `lib/latestVersion.ts`, which
                release.sh auto-updates on each ship — they stay in sync
                automatically. */}
            <TrackedLink
              href={LATEST_DMG_URL}
              event="download_dmg"
              eventProperties={{ source: "download_section" }}
              className="inline-flex items-center gap-3 rounded-xl bg-[color:var(--color-ink)] px-7 py-4 text-base font-medium text-[color:var(--color-bg)] transition-opacity hover:opacity-90"
            >
              <AppleMark />
              Download for Mac
            </TrackedLink>
          </div>
        )}

        {/* GitHub link — below the fork (or beside the single button
            visually via margin), one place regardless of channel count. */}
        <div className="mt-4 flex justify-center">
          <TrackedLink
            href="https://github.com/addicted-studio/daisy-app"
            event="github_view"
            eventProperties={{ source: "download_section" }}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-2 rounded-xl border border-[color:var(--color-divider)] px-7 py-4 text-base font-medium text-[color:var(--color-ink)] transition-colors hover:bg-[color:var(--color-bg-sidebar)]"
          >
            <svg
              viewBox="0 0 16 16"
              width="18"
              height="18"
              fill="currentColor"
              aria-hidden="true"
            >
              <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z" />
            </svg>
            View on GitHub
          </TrackedLink>
        </div>

        <p className="mt-6 text-sm text-[color:var(--color-ink-tertiary)]">
          Apple Silicon · macOS 14+
        </p>

        <p className="mt-8 text-xs text-[color:var(--color-ink-tertiary)]">
          Built by{" "}
          <a
            href="https://addicted.sh"
            target="_blank"
            rel="noreferrer"
            className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            Addicted Studio
          </a>
          . Native Mac app. No cloud. No login. No subscription gate.
        </p>
      </div>
    </section>
  );
}
