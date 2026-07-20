import type { Metadata } from "next";
import Link from "next/link";

import { Prose } from "@/components/docs/Prose";
import { docsNavigation } from "@/lib/docs/navigation";

export const metadata: Metadata = {
  title: "Daisy Docs",
  description:
    "Setup guides, configuration reference, MCP client walkthroughs, and recording-mode docs for Daisy on macOS.",
};

export default function DocsLanding() {
  return (
    <>
      <Prose>
        <h1>Daisy Docs</h1>
        <p>
          Setup walkthroughs, configuration reference, and integration guides
          for Daisy on macOS — the local-first meeting recorder.
        </p>
        <p>
          The sidebar groups pages by topic. Below is a flat overview if
          you&rsquo;d rather scan everything in one shot. Most pages are short
          and aim to answer the question they title in one sitting.
        </p>
      </Prose>

      {/* Sections as cards — each section gets a title + grid of its
          items so the landing reads as "here's the whole wiki at a glance"
          rather than "here are vague topic headings." */}
      <div className="mt-12 space-y-12">
        {docsNavigation.map((section) => (
          <section key={section.title}>
            <h2 className="mb-5 font-display text-xl font-semibold tracking-tight text-[color:var(--color-ink-primary)]">
              {section.title}
            </h2>
            <div className="grid gap-4 sm:grid-cols-2">
              {section.items.map((item) => {
                // Don't link the landing page to itself.
                if (item.href === "/docs") return null;
                return (
                  <Link
                    key={item.href}
                    href={item.href}
                    className="group rounded-xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] p-5 transition-all hover:-translate-y-0.5 hover:shadow-sm"
                  >
                    <p className="mb-1 font-display text-base font-semibold text-[color:var(--color-ink-primary)]">
                      {item.title}
                      <span
                        className="ml-1 inline-block transition-transform group-hover:translate-x-0.5"
                        aria-hidden
                      >
                        →
                      </span>
                    </p>
                    {item.description && (
                      <p className="text-sm leading-relaxed text-[color:var(--color-ink-secondary)]">
                        {item.description}
                      </p>
                    )}
                  </Link>
                );
              })}
            </div>
          </section>
        ))}
      </div>

      {/* Tail note — point visitors who didn't find what they need at
          the right channels. Discussions for "how do I…" / Issues for
          confirmed bugs. */}
      <div className="mt-16 rounded-xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-sidebar)] p-6 text-sm text-[color:var(--color-ink-secondary)]">
        <p className="mb-2 font-medium text-[color:var(--color-ink-primary)]">
          Can&rsquo;t find what you need?
        </p>
        <p className="leading-relaxed">
          For setup questions and how-do-I, head to{" "}
          <a
            href="https://github.com/addicted-studio/daisy-app/discussions/categories/q-a"
            target="_blank"
            rel="noreferrer"
            className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            GitHub Discussions → Q&amp;A
          </a>
          . For a confirmed reproducible bug, open an{" "}
          <a
            href="https://github.com/addicted-studio/daisy-app/issues/new/choose"
            target="_blank"
            rel="noreferrer"
            className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            Issue
          </a>
          . Security-sensitive reports go via the channel in{" "}
          <a
            href="https://github.com/addicted-studio/daisy-app/security/advisories/new"
            target="_blank"
            rel="noreferrer"
            className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            Security
          </a>
          .
        </p>
      </div>
    </>
  );
}
