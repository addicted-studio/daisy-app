import Link from "next/link";
import { Eyebrow } from "./Eyebrow";
import { TrackedLink } from "./TrackedLink";

// MCP server section — Daisy's structural differentiator.
//
// Every cloud meeting-tool competitor (Granola, Otter, Fathom,
// Cleft) physically can't ship this: their transcripts live on a
// server you don't own, so they can't act as a local-only MCP
// data source. Daisy can, because the transcript IS local. That
// makes "live data source for Claude Desktop / Cursor" a moat,
// not a feature.
//
// The section walks the visitor through: (1) what it is, (2) how
// to turn it on, (3) what queries they can run, (4) what stays
// on the machine. Visual treatment is more code-leaning than the
// rest of the page because the audience here is developers — a
// dark code block of the literal JSON config feels honest in a
// way that a marketing illustration wouldn't.

export function MCPCallout() {
  return (
    <section
      id="mcp"
      className="relative border-t border-[color:var(--color-divider)] px-6 py-24 md:py-32"
    >
      <div className="mx-auto max-w-5xl">
        <Eyebrow>Live data source</Eyebrow>
        <h2 className="mb-6 max-w-3xl font-display text-3xl font-semibold leading-tight tracking-tight md:text-4xl">
          Your transcripts, available to Claude Desktop and Cursor
          &mdash; without ever leaving your Mac.
        </h2>
        <p className="mb-16 max-w-3xl text-lg leading-relaxed text-[color:var(--color-ink-secondary)]">
          Daisy ships a local MCP server bound to{" "}
          <code className="rounded bg-[color:var(--color-bg-sidebar)] px-1.5 py-0.5 font-mono text-[0.85em] text-[color:var(--color-ink-primary)]">
            127.0.0.1
          </code>
          . Flip it on, click <em>Add to Claude Desktop</em>, and your
          meeting history becomes a queryable &mdash; and actionable
          &mdash; data source for any AI client that speaks MCP: read
          any transcript, then re-summarize it, name the speakers, or
          route it to Notion or Linear. No copy-paste, no API token, no
          upload &mdash; the data path is your Mac talking to your Mac.
        </p>

        {/* Two-column: explanation list left, code block right.
            Maps to "how it works" / "what it looks like". */}
        <div className="grid gap-12 md:grid-cols-[1.05fr_1fr] md:gap-16">
          <div>
            <p className="mb-2 text-xs font-medium uppercase tracking-widest text-[color:var(--color-ink-tertiary)]">
              The tools your AI can call
            </p>
            <ul className="space-y-5 text-sm leading-relaxed text-[color:var(--color-ink-secondary)]">
              <ToolItem
                name="list_sessions"
                body="Discover what's been recorded — title, date, duration, folder. Metadata only, no transcript bodies leak through."
              />
              <ToolItem
                name="get_session"
                body="Pull the full content of one recording: transcript, summary, action items, attendees, timestamps."
              />
              <ToolItem
                name="search_sessions"
                body="Substring search across titles, transcripts, and summaries — your AI finds the meeting on its own."
              />
              <ToolItem
                name="rename_speaker"
                body="Tell it 'speaker A is Maria' — the transcript updates and Daisy remembers the voice for future recordings."
              />
              <ToolItem
                name="route_session_to_destination"
                body="Push a finished session to Notion, Linear, Slack, or a webhook — the same Send-to action as in Daisy's UI."
              />
            </ul>
            <p className="mt-5 text-xs leading-relaxed text-[color:var(--color-ink-tertiary)]">
              Nine tools total — five read, four act (re-summarize,
              retitle, rename speakers, route). Action tools are scoped
              to safe, reversible operations: no deleting, no editing
              transcripts.
            </p>
            <div className="mt-10 flex flex-wrap gap-3">
              <TrackedLink
                href="https://github.com/addicted-studio/daisy-app/releases"
                event="github_view"
                eventProperties={{ source: "mcp_callout", target: "releases" }}
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center gap-2 rounded-xl bg-[color:var(--color-ink)] px-5 py-3 text-sm font-medium text-[color:var(--color-bg)] transition-opacity hover:opacity-90"
              >
                Download Daisy
              </TrackedLink>
              <Link
                href="/docs/mcp"
                className="inline-flex items-center gap-1.5 rounded-xl border border-[color:var(--color-divider)] px-5 py-3 text-sm font-medium text-[color:var(--color-ink)] transition-colors hover:bg-[color:var(--color-bg-sidebar)]"
              >
                Read the docs →
              </Link>
            </div>
          </div>

          {/* Code preview — what Claude Desktop's config gets
              after pressing "Add to Claude Desktop". Honest about
              what the click does. */}
          <figure className="not-prose">
            <figcaption className="mb-2 text-xs font-medium uppercase tracking-widest text-[color:var(--color-ink-tertiary)]">
              claude_desktop_config.json
            </figcaption>
            <pre className="overflow-x-auto rounded-xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] p-5 font-mono text-[12.5px] leading-relaxed text-[color:var(--color-ink-primary)]">
{`{
  "mcpServers": {
    "daisy": {
      "command": "npx",
      "args": [
        "-y", "mcp-remote",
        "http://127.0.0.1:54321/sse",
        "--transport", "sse-only",
        "--allow-http"
      ]
    }
  }
}`}
            </pre>
            <p className="mt-3 text-xs leading-relaxed text-[color:var(--color-ink-tertiary)]">
              One click writes this into{" "}
              <code className="font-mono">
                ~/Library/Application Support/Claude/claude_desktop_config.json
              </code>{" "}
              — preserving any other MCP servers you already have.
              Claude Desktop speaks stdio, so a tiny{" "}
              <code className="font-mono">mcp-remote</code> bridge proxies
              to Daisy&apos;s local SSE server. Restart Claude Desktop, and
              your transcripts are live.
            </p>
          </figure>
        </div>
      </div>
    </section>
  );
}

function ToolItem({ name, body }: { name: string; body: string }) {
  return (
    <li className="flex flex-col gap-1.5">
      <code className="self-start rounded bg-[color:var(--color-bg-sidebar)] px-1.5 py-0.5 font-mono text-[0.85em] text-[color:var(--color-ink-primary)]">
        {name}
      </code>
      <span>{body}</span>
    </li>
  );
}
