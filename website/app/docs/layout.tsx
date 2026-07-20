import type { Metadata } from "next";
import Link from "next/link";

import { BrandLogo } from "@/components/BrandLogo";
import { DocsBreadcrumbs } from "@/components/docs/Breadcrumbs";
import { DocsSidebar } from "@/components/docs/Sidebar";

// Docs section layout — wraps every page under /docs with:
//   - top nav bar (consistent with the marketing site so visitors
//     don't feel they've left Daisy)
//   - sticky left sidebar with nested navigation
//   - content column on the right
//   - breadcrumbs above the page H1
//
// The Sidebar component is a client component (uses usePathname for
// active-link highlighting); everything else here can stay server-
// rendered for fast initial paint of the docs hierarchy.

export const metadata: Metadata = {
  title: {
    default: "Docs · Daisy",
    template: "%s · Daisy Docs",
  },
  description:
    "Docs for Daisy — local meeting recorder for Mac. Install, first recording, MCP server setup for Claude Desktop / Cursor, AI providers, integrations.",
};

// BreadcrumbList schema for the docs root — gives Google a
// machine-readable navigation hierarchy so the SERP breadcrumb
// row (Daisy > Docs > Page) renders instead of raw URL paths.
// Individual deep pages can extend this by adding their own
// BreadcrumbList inline if needed. Recommended by the 2026-05-23
// pre-PH SEO audit.
const DOCS_BREADCRUMB_LD = {
  "@context": "https://schema.org",
  "@type": "BreadcrumbList",
  itemListElement: [
    {
      "@type": "ListItem",
      position: 1,
      name: "Daisy",
      item: "https://mydaisy.io",
    },
    {
      "@type": "ListItem",
      position: 2,
      name: "Docs",
      item: "https://mydaisy.io/docs",
    },
  ],
};

export default function DocsLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <div className="relative z-0 min-h-screen">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(DOCS_BREADCRUMB_LD) }}
      />
      {/* Top nav — slimmed-down version of the marketing nav. Kept
          consistent with Hero.tsx so the brand mark sits at the same
          spot whether you're on / or /docs/anything.
          Not sticky on purpose: NotifyBar (in the root layout) is
          already sticky top-0. Two sticky-top-0 siblings overlap on
          mobile and the lower z-index one gets hidden. Better to let
          this header scroll off naturally — the sidebar stays sticky
          on desktop, which is the actual navigation surface. */}
      <header className="border-b border-[color:var(--color-divider)] bg-[color:var(--color-bg)]">
        <div className="mx-auto flex max-w-7xl items-center justify-between gap-3 px-6 py-3 text-sm">
          <Link
            href="/"
            className="flex shrink-0 items-center gap-2 text-base font-medium tracking-tight text-[color:var(--color-ink)]"
          >
            <BrandLogo size={20} />
            Daisy
          </Link>
          {/* Mobile (< md): only the "← Home" affordance. Sidebar
              hamburger handles section navigation. */}
          <nav className="flex flex-wrap items-center justify-end gap-x-5 gap-y-1 text-[color:var(--color-ink-secondary)]">
            <Link
              href="/#features"
              className="hidden transition-colors hover:text-[color:var(--color-ink)] sm:inline"
            >
              Features
            </Link>
            <Link
              href="/#mcp"
              className="hidden transition-colors hover:text-[color:var(--color-ink)] sm:inline"
            >
              MCP
            </Link>
            <Link
              href="/docs"
              className="font-medium text-[color:var(--color-ink-primary)]"
            >
              Docs
            </Link>
            <Link
              href="/privacy"
              className="hidden transition-colors hover:text-[color:var(--color-ink)] sm:inline"
            >
              Privacy
            </Link>
            <Link
              href="https://github.com/addicted-studio/daisy-app"
              target="_blank"
              rel="noreferrer"
              className="transition-colors hover:text-[color:var(--color-ink)]"
            >
              GitHub
            </Link>
          </nav>
        </div>
      </header>

      {/* Body grid:
            - lg+: two-column [sidebar 220px | content fluid]
            - below lg: single column, sidebar collapses behind a hamburger
          max-w-7xl + generous horizontal padding so even long lines breathe. */}
      <div className="mx-auto grid max-w-7xl gap-10 px-6 py-10 lg:grid-cols-[220px_minmax(0,1fr)] lg:gap-16 lg:py-16">
        <aside>
          <DocsSidebar />
        </aside>
        <main className="min-w-0">
          {/* Content column max-width — kept narrower than the column
              so prose stays readable (66-80 chars per line target). */}
          <div className="max-w-3xl">
            <DocsBreadcrumbs />
            {children}
          </div>
        </main>
      </div>
    </div>
  );
}
