// Single source of truth for the /docs sidebar.
//
// The Sidebar component reads this config + the current pathname
// (via usePathname) to render the tree and highlight the active
// entry. Add new pages by appending to the correct section's
// `items` array; the sidebar picks them up automatically.
//
// Convention: every doc page also lives under `app/docs/<section>/<slug>/page.tsx`
// at the URL matching its `href` here. No separate frontmatter — the
// nav config IS the index. If you want a page to NOT appear in the
// sidebar (e.g. a hidden legal page), just omit it here while keeping
// the route file.

export type DocsNavItem = {
  title: string;
  href: string;
  // Short blurb shown on the /docs landing page beneath the title.
  // Optional — only landing uses it.
  description?: string;
};

export type DocsNavSection = {
  title: string;
  items: DocsNavItem[];
};

export const docsNavigation: DocsNavSection[] = [
  {
    title: "Getting started",
    items: [
      {
        title: "Overview",
        href: "/docs",
        description:
          "What Daisy is, how the docs are organised, and where to go next.",
      },
      {
        title: "Installation",
        href: "/docs/getting-started/installation",
        description:
          "Download the signed DMG, drag to Applications, grant the system permissions Daisy needs on first launch.",
      },
      {
        title: "First recording",
        href: "/docs/getting-started/first-recording",
        description:
          "From quitting the install dialog to a finished, summarised transcript in your folder.",
      },
    ],
  },
  {
    title: "Recording",
    items: [
      {
        title: "Three modes",
        href: "/docs/recording/modes",
        description:
          "Meeting capture, dictation, and voice notes — one widget, three centres, three hotkey patterns.",
      },
    ],
  },
  {
    title: "MCP server",
    items: [
      {
        title: "Overview & client setup",
        href: "/docs/mcp",
        description:
          "Expose your sessions to Claude Desktop, Cursor, Cline, Continue, and any other MCP-compatible client over a loopback connection.",
      },
    ],
  },
];

// Helper used by Breadcrumbs and the landing page to resolve the
// active entry from a pathname. Returns the matching nav item plus
// its parent section title for breadcrumb display.
export function findActiveNav(pathname: string): {
  section: DocsNavSection;
  item: DocsNavItem;
} | null {
  for (const section of docsNavigation) {
    for (const item of section.items) {
      if (item.href === pathname) {
        return { section, item };
      }
    }
  }
  return null;
}

// Flat list of all docs pages, useful for sitemap-style listings on
// the /docs landing page.
export function allDocsPages(): Array<{
  section: string;
  title: string;
  href: string;
  description?: string;
}> {
  return docsNavigation.flatMap((section) =>
    section.items.map((item) => ({
      section: section.title,
      title: item.title,
      href: item.href,
      description: item.description,
    }))
  );
}
