"use client";

// Docs sidebar — fixed at lg+ breakpoint on the left edge of the
// content area, collapsible on small screens via a top hamburger
// button. Reads navigation from `lib/docs/navigation.ts` and
// highlights the entry matching the current pathname.
//
// Active-link rule: exact match between `pathname` and `item.href`.
// We deliberately do NOT use prefix-match (e.g. /docs/mcp/anything
// shouldn't all highlight /docs/mcp) because every page has its own
// nav entry — prefix matching would create false positives.

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState } from "react";

import { docsNavigation } from "@/lib/docs/navigation";

export function DocsSidebar() {
  const pathname = usePathname();
  const [mobileOpen, setMobileOpen] = useState(false);

  return (
    <>
      {/* Mobile toggle — only visible below lg breakpoint. */}
      <button
        type="button"
        onClick={() => setMobileOpen((v) => !v)}
        aria-label={mobileOpen ? "Close docs navigation" : "Open docs navigation"}
        aria-expanded={mobileOpen}
        className="sticky top-[3.5rem] z-30 mb-4 inline-flex items-center gap-2 self-start rounded-lg border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] px-3 py-2 text-sm font-medium text-[color:var(--color-ink)] shadow-sm lg:hidden"
      >
        <svg
          width="14"
          height="14"
          viewBox="0 0 14 14"
          fill="none"
          aria-hidden
        >
          <path
            d="M2 3.5h10M2 7h10M2 10.5h10"
            stroke="currentColor"
            strokeWidth="1.5"
            strokeLinecap="round"
          />
        </svg>
        {mobileOpen ? "Hide navigation" : "Show navigation"}
      </button>

      {/* The nav element itself.
          - lg+: always visible, sticky in its column
          - below lg: hidden by default, slides open via mobileOpen state */}
      <nav
        aria-label="Docs navigation"
        className={`${mobileOpen ? "block" : "hidden"} lg:sticky lg:top-24 lg:block lg:max-h-[calc(100vh-6rem)] lg:overflow-y-auto lg:self-start lg:pr-4`}
      >
        <ul className="space-y-8 text-sm">
          {docsNavigation.map((section) => (
            <li key={section.title}>
              <p className="mb-3 text-xs font-semibold uppercase tracking-widest text-[color:var(--color-ink-tertiary)]">
                {section.title}
              </p>
              <ul className="space-y-1">
                {section.items.map((item) => {
                  const isActive = item.href === pathname;
                  return (
                    <li key={item.href}>
                      <Link
                        href={item.href}
                        onClick={() => setMobileOpen(false)}
                        className={
                          isActive
                            ? "block rounded-md bg-[color:var(--color-bg-sidebar)] px-3 py-1.5 font-medium text-[color:var(--color-ink-primary)]"
                            : "block rounded-md px-3 py-1.5 text-[color:var(--color-ink-secondary)] transition-colors hover:bg-[color:var(--color-bg-sidebar)] hover:text-[color:var(--color-ink-primary)]"
                        }
                      >
                        {item.title}
                      </Link>
                    </li>
                  );
                })}
              </ul>
            </li>
          ))}

          {/* Footer link back to the marketing site — small, calm,
              underlined so visitors who arrived via deep-link know
              where the front door is. */}
          <li className="border-t border-[color:var(--color-divider)] pt-6">
            <Link
              href="/"
              className="inline-flex items-center gap-1.5 text-xs text-[color:var(--color-ink-tertiary)] transition-colors hover:text-[color:var(--color-ink)]"
            >
              <span aria-hidden>←</span>
              Daisy home
            </Link>
          </li>
        </ul>
      </nav>
    </>
  );
}
