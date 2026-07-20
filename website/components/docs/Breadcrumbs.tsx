"use client";

// Breadcrumbs — shown at the top of every docs page above the H1.
// Resolves the current pathname against the nav config to produce
// "Docs / <section> / <page>" trail. If the current page isn't in
// the nav config (e.g. a hidden page), falls back to just "Docs".

import Link from "next/link";
import { usePathname } from "next/navigation";

import { findActiveNav } from "@/lib/docs/navigation";

export function DocsBreadcrumbs() {
  const pathname = usePathname();
  const active = findActiveNav(pathname);

  return (
    <nav
      aria-label="Breadcrumb"
      className="mb-6 flex flex-wrap items-center gap-1.5 text-xs text-[color:var(--color-ink-tertiary)]"
    >
      <Link
        href="/docs"
        className="transition-colors hover:text-[color:var(--color-ink)]"
      >
        Docs
      </Link>
      {active && active.item.href !== "/docs" && (
        <>
          <span aria-hidden>/</span>
          <span>{active.section.title}</span>
          <span aria-hidden>/</span>
          <span className="text-[color:var(--color-ink-primary)]">
            {active.item.title}
          </span>
        </>
      )}
    </nav>
  );
}
