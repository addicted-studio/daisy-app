// Landing section after PrivacyPromise. The narrative through-line of
// the site is "your meetings stay on your Mac"; this block makes the
// AI-provider story concrete — Daisy doesn't bind you to one vendor,
// and the local route is treated as a first-class peer to the cloud
// route, not a sad-trombone fallback.
//
// Provider marks are loaded from /public via Next/Image — SVG sources
// rendered at 18×18 in the pill, so they stay crisp at any density.

import Image from "next/image";
import { Eyebrow } from "./Eyebrow";

type Provider = {
  name: string;
  href: string;
  icon: string;
};

const CLOUD_PROVIDERS: Provider[] = [
  { name: "Anthropic Claude", href: "https://console.anthropic.com", icon: "/claude.svg" },
  { name: "OpenAI", href: "https://platform.openai.com", icon: "/gpt.svg" },
];

const LOCAL_PROVIDERS: Provider[] = [
  { name: "Ollama", href: "https://ollama.com", icon: "/ollama.svg" },
  { name: "LM Studio", href: "https://lmstudio.ai", icon: "/lm.svg" },
  { name: "Apple Intelligence", href: "https://www.apple.com/apple-intelligence/", icon: "/apple.svg" },
];

export function BringYourOwnAI() {
  return (
    <section
      id="ai-providers"
      className="relative border-t border-[color:var(--color-divider)] px-6 py-24 md:py-32"
    >
      <div className="mx-auto max-w-4xl">
        <Eyebrow>Bring your own AI</Eyebrow>
        <h2 className="mb-6 font-display text-3xl font-semibold leading-tight tracking-tight md:text-4xl">
          Pick the brain. Daisy&rsquo;s just the wiring.
        </h2>
        <p className="mb-16 max-w-2xl text-lg leading-relaxed text-[color:var(--color-ink-secondary)]">
          We don&rsquo;t lock you into one provider. Use the model you
          already trust &mdash; pay them directly, or run it yourself on
          the same Mac that&rsquo;s recording.
        </p>

        <div className="grid gap-12 md:grid-cols-2 md:gap-16">
          <ProviderColumn
            eyebrow="Cloud"
            title="Bring your own key"
            description="Plug an Anthropic or OpenAI API key into Settings. Your transcript goes from your Mac straight to the provider — Daisy isn't a proxy, doesn't see the key, doesn't see the prompt."
            providers={CLOUD_PROVIDERS}
          />
          <ProviderColumn
            eyebrow="Local"
            title="Run it offline"
            description="Point Daisy at Ollama, LM Studio, or Apple Intelligence — or any local model behind an MCP server. Zero network calls. Apple Intelligence works without setup; Ollama and LM Studio are a one-line install and keep your meetings entirely on-device."
            providers={LOCAL_PROVIDERS}
          />
        </div>
      </div>
    </section>
  );
}

function ProviderColumn({
  eyebrow,
  title,
  description,
  providers,
}: {
  eyebrow: string;
  title: string;
  description: string;
  providers: Provider[];
}) {
  return (
    <div>
      <p className="mb-2 text-xs font-medium uppercase tracking-widest text-[color:var(--color-ink-tertiary)]">
        {eyebrow}
      </p>
      <h3 className="mb-3 font-display text-xl font-semibold leading-snug">
        {title}
      </h3>
      <p className="mb-6 text-sm leading-relaxed text-[color:var(--color-ink-secondary)]">
        {description}
      </p>
      <div className="flex flex-wrap gap-2">
        {providers.map((p) => (
          <a
            key={p.name}
            href={p.href}
            target="_blank"
            rel="noopener noreferrer"
            // `group` is here so the icon's `group-hover:` filter
            // de-saturation toggle actually fires (pre-fix the
            // hover effect was inert because the parent wasn't a
            // group).
            className="group inline-flex items-center gap-2 rounded-full border border-[color:var(--color-divider)] bg-[color:var(--color-bg-sidebar)] px-3 py-1.5 text-sm font-medium text-[color:var(--color-ink-primary)] transition-all duration-200 hover:-translate-y-0.5 hover:bg-[color:var(--color-divider)] hover:shadow-sm"
          >
            <Image
              src={p.icon}
              // Decorative icon — `{p.name}` text sits 4px to the
              // right and carries the semantic load. Empty alt +
              // aria-hidden=true is the correct WCAG pattern here
              // (vs. e.g. alt="Claude icon" which would make screen
              // readers say "Claude icon Claude Sonnet" — duplicate).
              // Pre-PH SEO audit (2026-05-23) flagged this as missing
              // alt; that's a false positive worth keeping a note on.
              alt=""
              width={18}
              height={18}
              aria-hidden="true"
              // Light mode: grayscale + 80% opacity unifies the
              // providers' visual weight — Claude / GPT / Apple raw
              // SVGs have wildly different silhouettes and
              // saturation. Filter unifies them as the same kind of
              // mark.
              //
              // Dark mode: same grayscale unification PLUS invert(1)
              // — Anthropic / OpenAI / Ollama / LM Studio brand
              // marks ship as black-on-transparent SVGs, which
              // turned into black-on-black on dark backgrounds (Egor
              // caught: "в темной теме иконки не красятся"). Invert
              // flips them to white-on-transparent for legibility.
              // Apple Intelligence's rainbow swirl looks slightly
              // off after invert but stays recognizable at 18px
              // pill size, and unifying everything wins over
              // preserving one mark's brand-correct palette.
              className="h-[18px] w-[18px] shrink-0 object-contain opacity-80 [filter:grayscale(0.6)] transition-[filter,opacity] duration-200 group-hover:opacity-100 group-hover:[filter:grayscale(0)] dark:[filter:grayscale(0.6)_invert(1)] dark:group-hover:[filter:grayscale(0)_invert(1)]"
            />
            {p.name}
            <ExternalLinkIcon />
          </a>
        ))}
      </div>
    </div>
  );
}

function ExternalLinkIcon() {
  return (
    <svg
      width="10"
      height="10"
      viewBox="0 0 12 12"
      fill="none"
      aria-hidden="true"
      className="text-[color:var(--color-ink-tertiary)]"
    >
      <path
        d="M4 4h4v4M4 8l4-4"
        stroke="currentColor"
        strokeWidth="1.4"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
