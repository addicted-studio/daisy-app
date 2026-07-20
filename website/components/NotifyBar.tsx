"use client";

import Link from "next/link";
import { useEffect, useState } from "react";

// Pre-launch sticky bar — pinned to the top of every page until the
// user dismisses it. Single-row, no shouting. The accent dot inherits
// recording orange (#FF9500) so the bar reads as "Daisy speaking",
// not "ad space".
//
// CTA points at the Product Hunt upcoming-product page where users
// can opt-in to a launch-day notification via PH itself — no email
// backend needed on our side. URL swaps to the real product URL once
// the launch goes live on Sun 7 Jun. (Thu 28 May → Tue 2 Jun → moved
// to Sun 7 Jun: the day before WWDC (Jun 8–12) so the Apple / Mac-dev
// audience catches it ramping into Apple week, and a quiet weekend
// gives a real shot at Product of the Day — kept the dismiss-key
// fresh below so anyone who closed the old bar sees the new date.)
//
// Dismissed state is keyed to a launch identifier so future
// announcements (next PH push, big release, etc.) get a fresh bar
// without users having to re-find the close affordance.

// Bumped from the pre-launch ("launching soon") key so anyone who
// dismissed the old bar sees the new LIVE launch-day bar.
const LAUNCH_KEY = "daisy-notify-bar-ph-live-jun7";

// Live Product Hunt launch page — the "support us" / upvote target.
const PH_URL = "https://www.producthunt.com/products/daisy-4";

export function NotifyBar() {
  // Start hidden to avoid SSR/CSR flash — flip to visible after the
  // localStorage check runs client-side. Without this guard the bar
  // would flicker on every navigation.
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    const dismissed =
      typeof window !== "undefined" &&
      window.localStorage.getItem(LAUNCH_KEY) === "1";
    if (!dismissed) setVisible(true);
  }, []);

  if (!visible) return null;

  return (
    <div
      role="region"
      aria-label="Product Hunt launch announcement"
      className="sticky top-0 z-50 w-full border-b border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] px-4 py-2.5 text-sm"
    >
      <div className="mx-auto flex max-w-5xl items-center justify-between gap-4">
        <div className="flex min-w-0 items-center gap-2.5">
          {/* macOS-orange dot — matches the recording widget centre.
              Pulses subtly so the bar reads as live, not stale copy. */}
          <span className="relative inline-flex shrink-0">
            <span
              className="inline-block h-2 w-2 rounded-full"
              style={{ background: "var(--color-recording)" }}
            />
            <span
              className="absolute inset-0 inline-flex h-2 w-2 animate-ping rounded-full"
              style={{ background: "var(--color-recording)", opacity: 0.6 }}
            />
          </span>
          <p className="truncate text-[color:var(--color-ink-primary)]">
            <span className="font-medium">Daisy is live on Product Hunt today</span>
            <span className="hidden text-[color:var(--color-ink-secondary)] sm:inline">
              {" · an upvote would mean a lot"}
            </span>
          </p>
        </div>

        <div className="flex shrink-0 items-center gap-3">
          <Link
            href={PH_URL}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-1.5 rounded-lg bg-[color:var(--color-ink)] px-3 py-1.5 text-xs font-medium text-[color:var(--color-bg)] transition-opacity hover:opacity-90"
          >
            Support us
            <span aria-hidden>→</span>
          </Link>
          <button
            type="button"
            onClick={() => {
              window.localStorage.setItem(LAUNCH_KEY, "1");
              setVisible(false);
            }}
            aria-label="Dismiss launch announcement"
            className="rounded p-1 text-[color:var(--color-ink-tertiary)] transition-colors hover:bg-[color:var(--color-bg-sidebar)] hover:text-[color:var(--color-ink)]"
          >
            <svg
              width="14"
              height="14"
              viewBox="0 0 14 14"
              fill="none"
              aria-hidden
            >
              <path
                d="M3 3l8 8M11 3l-8 8"
                stroke="currentColor"
                strokeWidth="1.5"
                strokeLinecap="round"
              />
            </svg>
          </button>
        </div>
      </div>
    </div>
  );
}
