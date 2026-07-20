"use client";

// Section eyebrow — the small uppercase-tracked label that sits
// above each section title ("What it does", "The deal", etc).
// Wrapping it in a single motion component gives every section the
// same restrained letter-spacing-and-fade entrance animation, so
// the page reads as a coherent design system rather than a
// patchwork of server components.
//
// Motion design — letter-spacing animates from 0.4em → standard
// "tracking-widest" (0.1em) while opacity rises from 0 to 1. The
// effect is "the title is settling into place" rather than "the
// title is sliding in" — appropriate for a Mac-aesthetic site
// that should feel restrained, not animated-for-the-sake-of.
//
// Easing — Apple's standard ease curve `[0.22, 0.61, 0.36, 1]`,
// what their design system docs call "soft ease-out". Matches
// the in-app Liquid Glass transitions.
//
// Reduced motion — motion respects `prefers-reduced-motion` by
// default. No explicit handling needed.

import { motion } from "motion/react";

export function Eyebrow({ children }: { children: React.ReactNode }) {
  return (
    <motion.p
      initial={{ opacity: 0, letterSpacing: "0.4em" }}
      whileInView={{ opacity: 1, letterSpacing: "0.1em" }}
      viewport={{ once: true, margin: "-80px" }}
      transition={{ duration: 0.7, ease: [0.22, 0.61, 0.36, 1] }}
      className="mb-3 text-sm font-medium uppercase text-[color:var(--color-ink-tertiary)]"
    >
      {children}
    </motion.p>
  );
}
