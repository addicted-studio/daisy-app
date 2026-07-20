import { Eyebrow } from "./Eyebrow";

// Integrations / destinations section.
//
// Daisy can push a finished recording into the tools the user
// actually works in — Notion (page or database), Linear (issue),
// Attio (note), Slack/Discord/anything via webhook, or any
// MCP-compatible service. Triggers either via the kebab menu
// in Library, or automatically when recording stops.
//
// The landing page previously hid all of this in a single Notion
// mention on the privacy page. That's a feature gap visitors
// can't possibly know about until they install. Surfacing it
// here closes the loop after the BringYourOwnAI / MCP sections:
// "your transcripts, your AI, AND your destinations".

const DESTINATIONS = [
  {
    name: "Notion",
    detail: "Page or database",
    icon: "notion",
  },
  {
    name: "Linear",
    detail: "create_issue",
    icon: "linear",
  },
  {
    name: "Attio",
    detail: "Notes on a record",
    icon: "attio",
  },
  {
    name: "Slack",
    detail: "Incoming webhook",
    icon: "slack",
  },
  {
    name: "Webhook",
    detail: "Anything that accepts JSON",
    icon: "webhook",
  },
  {
    name: "MCP",
    detail: "Any MCP-compatible service",
    icon: "mcp",
  },
];

export function Integrations() {
  return (
    <section
      id="integrations"
      className="relative border-t border-[color:var(--color-divider)] bg-[color:var(--color-bg-sidebar)] px-6 py-24 md:py-32"
    >
      <div className="mx-auto max-w-4xl">
        <Eyebrow>Destinations</Eyebrow>
        <h2 className="mb-6 font-display text-3xl font-semibold leading-tight tracking-tight md:text-4xl">
          Your transcripts, in the tools you actually work in.
        </h2>
        <p className="mb-16 max-w-2xl text-lg leading-relaxed text-[color:var(--color-ink-secondary)]">
          When a recording finishes, Daisy can push it to the
          destination you set up — automatically, or one click from the
          kebab menu. Each destination has folder rules so a Notes
          recording doesn&rsquo;t accidentally end up in your Work
          Linear.
        </p>

        <div className="grid gap-3 sm:grid-cols-2 md:grid-cols-3">
          {DESTINATIONS.map((d) => (
            <div
              key={d.name}
              className="flex items-center gap-3 rounded-xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] p-4 transition-all duration-200 hover:-translate-y-0.5 hover:shadow-sm"
            >
              {/* Icons hidden for now (1.0.7.16) — restore DestinationIcon from git if wanted back. */}
              <div className="flex flex-col">
                <span className="text-sm font-medium leading-tight text-[color:var(--color-ink-primary)]">
                  {d.name}
                </span>
                <span className="text-xs leading-tight text-[color:var(--color-ink-tertiary)]">
                  {d.detail}
                </span>
              </div>
            </div>
          ))}
        </div>

        <p className="mt-10 max-w-2xl text-sm leading-relaxed text-[color:var(--color-ink-tertiary)]">
          Each destination is configured in Connections, with folder
          routing in Connections → Auto-routing. API keys live in your
          macOS Keychain, never on a server. Wire Work recordings to
          Linear, Notes recordings to Notion, and personal recordings to
          nowhere &mdash; without touching anything else.
        </p>
      </div>
    </section>
  );
}
