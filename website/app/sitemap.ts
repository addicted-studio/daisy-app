import type { MetadataRoute } from "next";

import { allDocsPages } from "@/lib/docs/navigation";

// Sitemap for mydaisy.io.
//
// Next.js 13+ generates `sitemap.xml` automatically from this file —
// no build script, no third-party package. Returns an array of URL
// entries with optional `lastModified`, `changeFrequency`, `priority`
// hints. Search engines treat these as soft hints; the entries
// themselves are what matters most.
//
// All current routes are static (no dynamic params), so we enumerate
// them by hand for the home + utility pages, then programmatically
// pull every docs page out of the nav config — that means new docs
// pages added to navigation.ts are auto-listed without touching this
// file. Single source of truth for site routes.

const SITE = "https://mydaisy.io";

export default function sitemap(): MetadataRoute.Sitemap {
  // Today's date for `lastModified` on freshly-changed pages.
  // Hand-roll per-page lastModified later if you want per-page granularity;
  // for now "everything changed today" is honest enough for a launch site
  // shipping multiple times a day.
  const now = new Date();

  const topLevel: MetadataRoute.Sitemap = [
    {
      url: `${SITE}/`,
      lastModified: now,
      changeFrequency: "weekly",
      priority: 1.0,
    },
    {
      url: `${SITE}/alternatives/granola`,
      lastModified: now,
      changeFrequency: "monthly",
      // High priority — top SEO-ROI page per 2026-05-23 pre-PH audit,
      // captures "granola alternative" search family.
      priority: 0.9,
    },
    {
      url: `${SITE}/alternatives/apple`,
      lastModified: now,
      changeFrequency: "monthly",
      priority: 0.8,
    },
    {
      url: `${SITE}/alternatives/otter`,
      lastModified: now,
      changeFrequency: "monthly",
      priority: 0.8,
    },
    {
      url: `${SITE}/enterprise`,
      lastModified: now,
      changeFrequency: "monthly",
      priority: 0.8,
    },
    {
      url: `${SITE}/changelog`,
      lastModified: now,
      changeFrequency: "weekly",
      priority: 0.6,
    },
    {
      url: `${SITE}/privacy`,
      lastModified: now,
      changeFrequency: "monthly",
      priority: 0.6,
    },
    {
      url: `${SITE}/support`,
      lastModified: now,
      changeFrequency: "monthly",
      priority: 0.5,
    },
  ];

  // Pulled programmatically from the docs nav config — new pages
  // appear automatically. Priority slightly lower than the home page
  // because docs are reference rather than landing.
  const docs: MetadataRoute.Sitemap = allDocsPages().map((page) => ({
    url: `${SITE}${page.href}`,
    lastModified: now,
    changeFrequency: "weekly",
    priority: page.href === "/docs" ? 0.8 : 0.7,
  }));

  return [...topLevel, ...docs];
}
