// Prose — typography wrapper for docs content.
//
// Centralises h1/h2/h3 sizing, paragraph rhythm, link styling, list
// indentation, inline-code background, and code block styling so
// every docs page renders with identical typographic tuning without
// each page re-declaring those Tailwind classes.
//
// Usage:
//   <Prose>
//     <h1>Page title</h1>
//     <p>Body text...</p>
//     <h2>Section</h2>
//     ...
//   </Prose>
//
// We deliberately don't use @tailwindcss/typography here because the
// plugin's defaults assume light-on-dark or generic dark-on-light;
// Daisy's cream-and-ink palette needs hand-tuned spacing and accent
// colours. Hand-rolled is ~60 lines and exactly matches the brand.

import type { ReactNode } from "react";

export function Prose({
  children,
  className = "",
}: {
  children: ReactNode;
  className?: string;
}) {
  return (
    <article
      className={[
        // Base text rhythm
        "max-w-none text-[color:var(--color-ink-primary)] leading-relaxed",

        // Headings
        "[&_h1]:font-display [&_h1]:text-4xl [&_h1]:font-semibold [&_h1]:leading-tight [&_h1]:tracking-tight [&_h1]:md:text-5xl [&_h1]:mb-6",
        "[&_h2]:mt-12 [&_h2]:mb-4 [&_h2]:font-display [&_h2]:text-2xl [&_h2]:font-semibold [&_h2]:tracking-tight",
        "[&_h3]:mt-8 [&_h3]:mb-3 [&_h3]:font-display [&_h3]:text-lg [&_h3]:font-semibold [&_h3]:tracking-tight",

        // Paragraphs
        "[&_p]:my-4 [&_p]:text-[color:var(--color-ink-secondary)] [&_p:first-of-type]:text-lg",

        // Lists
        "[&_ul]:my-4 [&_ul]:space-y-2 [&_ul]:pl-6 [&_ul]:list-disc [&_ul]:text-[color:var(--color-ink-secondary)]",
        "[&_ol]:my-4 [&_ol]:space-y-2 [&_ol]:pl-6 [&_ol]:list-decimal [&_ol]:text-[color:var(--color-ink-secondary)]",
        "[&_li]:leading-relaxed",
        // Nested lists tighter
        "[&_li_ul]:my-1 [&_li_ol]:my-1",

        // Inline code
        "[&_code]:rounded [&_code]:bg-[color:var(--color-bg-sidebar)] [&_code]:px-1.5 [&_code]:py-0.5 [&_code]:text-[0.875em] [&_code]:font-mono [&_code]:text-[color:var(--color-ink-primary)]",

        // Code blocks (pre containing code)
        "[&_pre]:my-6 [&_pre]:overflow-x-auto [&_pre]:rounded-xl [&_pre]:border [&_pre]:border-[color:var(--color-divider)] [&_pre]:bg-[color:var(--color-bg-elevated)] [&_pre]:p-5 [&_pre]:font-mono [&_pre]:text-[12.5px] [&_pre]:leading-relaxed",
        "[&_pre_code]:bg-transparent [&_pre_code]:p-0 [&_pre_code]:text-[color:var(--color-ink-primary)]",

        // Links
        "[&_a]:text-[color:var(--color-ink-primary)] [&_a]:underline [&_a]:decoration-[color:var(--color-ink-tertiary)] [&_a]:underline-offset-4 [&_a]:transition-colors [&_a:hover]:decoration-[color:var(--color-ink)]",

        // Bold + italic
        "[&_strong]:font-semibold [&_strong]:text-[color:var(--color-ink-primary)]",
        "[&_em]:italic",

        // Blockquote
        "[&_blockquote]:my-6 [&_blockquote]:border-l-2 [&_blockquote]:border-[color:var(--color-accent-soft)] [&_blockquote]:pl-5 [&_blockquote]:italic [&_blockquote]:text-[color:var(--color-ink-secondary)]",

        // Horizontal rule
        "[&_hr]:my-12 [&_hr]:border-t [&_hr]:border-[color:var(--color-divider)]",

        // Tables (rare but in case)
        "[&_table]:my-6 [&_table]:w-full [&_table]:border-collapse [&_table]:text-sm",
        "[&_th]:border [&_th]:border-[color:var(--color-divider)] [&_th]:bg-[color:var(--color-bg-sidebar)] [&_th]:px-3 [&_th]:py-2 [&_th]:text-left [&_th]:font-semibold",
        "[&_td]:border [&_td]:border-[color:var(--color-divider)] [&_td]:px-3 [&_td]:py-2 [&_td]:text-[color:var(--color-ink-secondary)]",

        className,
      ].join(" ")}
    >
      {children}
    </article>
  );
}
