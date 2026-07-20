import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Connect Daisy to Claude, Cursor, or any MCP client",
  description:
    "How to read your Daisy meeting transcripts and summaries from Claude Desktop, Cursor, Cline, Continue, or any other MCP-compatible AI client over a local 127.0.0.1 connection.",
};

// MCP integration guide.
//
// Note: this page predates the /docs wiki layout. It uses hand-rolled
// section/header markup rather than the shared `Prose` wrapper because
// the content shape (definition lists for tools, custom Example
// component for prompt examples, expandable manual-config details) is
// richer than what Prose can express via element selectors alone.
// Keeping it bespoke preserves the existing structure; the outer
// /docs layout still provides nav, breadcrumbs, and column constraints.

export default function MCPDocsPage() {
  return (
    <div className="relative z-0">
      <h1 className="mb-6 font-display text-4xl font-semibold leading-tight tracking-tight md:text-5xl">
        Read your Daisy recordings from Claude, Cursor, or any MCP client
      </h1>
      <p className="mb-16 text-lg leading-relaxed text-[color:var(--color-ink-secondary)]">
        Daisy ships a local MCP server (Model Context Protocol). Turn it
        on and any compatible AI client running on the same Mac can
        list, search, and read your finished recordings — transcripts,
        summaries, action items, the lot — and act on them: re-summarize,
        name speakers, route a session to Notion or Linear. Everything
        stays on
        <code className="mx-1 rounded bg-[color:var(--color-bg-elevated)] px-1.5 py-0.5 text-sm">127.0.0.1</code>;
        nothing leaves the machine.
      </p>

      <section className="mb-12 space-y-4">
        <h2 className="font-display text-2xl font-semibold tracking-tight">
          What you get
        </h2>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Nine tools — five read, four act. Read tools first:
        </p>
        <div className="rounded-xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] p-6">
          <dl className="space-y-4 text-sm text-[color:var(--color-ink-secondary)]">
            <div>
              <dt className="mb-1 font-mono font-semibold text-[color:var(--color-ink)]">
                list_sessions
              </dt>
              <dd>
                Metadata for every recording — title, date, duration,
                preview. Filterable by folder / date range / limit.
              </dd>
            </div>
            <div>
              <dt className="mb-1 font-mono font-semibold text-[color:var(--color-ink)]">
                get_session
              </dt>
              <dd>
                Full content of one recording: transcript, summary,
                action items, attendees.
              </dd>
            </div>
            <div>
              <dt className="mb-1 font-mono font-semibold text-[color:var(--color-ink)]">
                search_sessions
              </dt>
              <dd>
                Substring search across titles, transcripts, and
                summary fields. Returns snippets so the AI can decide
                which recordings to fetch in full.
              </dd>
            </div>
            <div>
              <dt className="mb-1 font-mono font-semibold text-[color:var(--color-ink)]">
                list_folders
              </dt>
              <dd>
                The folder slugs you&rsquo;ve set up. Use as the
                <code className="mx-1 rounded bg-[color:var(--color-bg-primary)] px-1 text-xs">folder</code>
                argument to <code className="font-mono text-xs">list_sessions</code>.
              </dd>
            </div>
            <div>
              <dt className="mb-1 font-mono font-semibold text-[color:var(--color-ink)]">
                list_destinations
              </dt>
              <dd>
                The export destinations you&rsquo;ve configured (Notion,
                Linear, Slack, a webhook, another MCP server) — feeds{" "}
                <code className="font-mono text-xs">route_session_to_destination</code>.
              </dd>
            </div>
          </dl>
        </div>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          And four action tools — deliberately scoped to things that are
          safe and reversible:
        </p>
        <div className="rounded-xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] p-6">
          <dl className="space-y-4 text-sm text-[color:var(--color-ink-secondary)]">
            <div>
              <dt className="mb-1 font-mono font-semibold text-[color:var(--color-ink)]">
                resummarize_session
              </dt>
              <dd>
                Regenerate a session&rsquo;s summary with your configured
                AI provider — e.g. after naming the speakers, or for a
                session that never got one. Optional output language.
              </dd>
            </div>
            <div>
              <dt className="mb-1 font-mono font-semibold text-[color:var(--color-ink)]">
                set_session_title
              </dt>
              <dd>
                Rename a recording. Reversible — call again with the old
                title.
              </dd>
            </div>
            <div>
              <dt className="mb-1 font-mono font-semibold text-[color:var(--color-ink)]">
                rename_speaker
              </dt>
              <dd>
                Label a diarized voice (&ldquo;speaker A is Maria&rdquo;).
                Updates the transcript and seeds Daisy&rsquo;s speaker
                profiles so the same voice is auto-labelled in future
                recordings.
              </dd>
            </div>
            <div>
              <dt className="mb-1 font-mono font-semibold text-[color:var(--color-ink)]">
                route_session_to_destination
              </dt>
              <dd>
                Push a finished session to one of your configured
                destinations — the same &ldquo;Send to&rdquo; action as
                in Daisy&rsquo;s UI.
              </dd>
            </div>
          </dl>
        </div>
        <p className="text-sm text-[color:var(--color-ink-tertiary)]">
          No destructive surface — the AI can&rsquo;t delete recordings,
          edit transcripts, or touch audio. Every action tool is either
          reversible or additive. That&rsquo;s by design.
        </p>
      </section>

      <section className="mb-12 space-y-4">
        <h2 className="font-display text-2xl font-semibold tracking-tight">
          Setup — Claude Desktop
        </h2>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          One-click flow from inside Daisy:
        </p>
        <ol className="list-decimal space-y-3 pl-6 text-[color:var(--color-ink-secondary)]">
          <li>
            Daisy → <strong>Connections → MCP server</strong> → flip
            the toggle ON. Status badge should turn green
            (<em>Running</em>) within a second.
          </li>
          <li>
            Click <strong>Add to Claude Desktop</strong>. Daisy writes
            the right snippet into{" "}
            <code className="rounded bg-[color:var(--color-bg-elevated)] px-1.5 py-0.5 text-sm">
              ~/Library/Application Support/Claude/claude_desktop_config.json
            </code>{" "}
            (merges with anything else you already have there).
          </li>
          <li>
            <strong>Fully quit Claude Desktop</strong> (⌘Q — not just
            close the window) and reopen. Claude only re-reads the MCP
            config on cold start.
          </li>
          <li>
            In a new chat, ask:{" "}
            <em>&ldquo;List my last 5 Daisy meetings.&rdquo;</em>
            {" "}First call takes a few seconds while
            <code className="mx-1 rounded bg-[color:var(--color-bg-elevated)] px-1 text-xs">npx</code>
            fetches the <code className="text-xs">mcp-remote</code> bridge. After that it&rsquo;s instant.
          </li>
        </ol>

        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          <strong>Node.js is only needed for this bridge path.</strong>{" "}
          Clients that speak SSE natively (Cursor, Claude Code, and
          others — next section) connect straight to the URL with no
          Node at all. Claude Desktop&rsquo;s MCP config expects a stdio
          transport, so for it Daisy&rsquo;s SSE server is wrapped
          through the{" "}
          <a
            href="https://www.npmjs.com/package/mcp-remote"
            target="_blank"
            rel="noreferrer"
            className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            mcp-remote
          </a>{" "}
          bridge that <code className="text-xs">npx</code> auto-fetches.
        </p>

        <details className="rounded-xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] p-5">
          <summary className="cursor-pointer text-sm font-medium text-[color:var(--color-ink)]">
            Manual config (if the in-app button doesn&rsquo;t work)
          </summary>
          <div className="mt-4 space-y-4 text-sm text-[color:var(--color-ink-secondary)]">
            <p>
              Open{" "}
              <code className="rounded bg-[color:var(--color-bg-primary)] px-1 text-xs">
                ~/Library/Application Support/Claude/claude_desktop_config.json
              </code>{" "}
              in any editor (Claude Desktop → Settings → Developer →
              Edit Config creates it if missing). Add Daisy under{" "}
              <code className="text-xs">mcpServers</code>:
            </p>
            <pre className="overflow-x-auto rounded-lg bg-[color:var(--color-bg-primary)] p-4 text-xs leading-relaxed">
{`{
  "mcpServers": {
    "daisy": {
      "command": "npx",
      "args": [
        "-y",
        "mcp-remote",
        "http://127.0.0.1:54321/sse",
        "--transport", "sse-only",
        "--allow-http"
      ]
    }
  }
}`}
            </pre>
            <p>
              The two extra flags after the URL aren&rsquo;t optional —
              <code className="mx-1 text-xs">--transport sse-only</code>
              pins <code className="text-xs">mcp-remote</code> to the
              transport Daisy speaks (no failover to newer Streamable
              HTTP that doesn&rsquo;t exist on the server), and
              <code className="mx-1 text-xs">--allow-http</code>
              permits plain HTTP on loopback (mcp-remote defaults to
              HTTPS-only).
            </p>
            <p>Then ⌘Q and reopen Claude Desktop.</p>
          </div>
        </details>
      </section>

      <section className="mb-12 space-y-4">
        <h2 className="font-display text-2xl font-semibold tracking-tight">
          Setup — Cursor / Cline / Continue
        </h2>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Cursor, Cline (VS Code extension), Continue, and most other
          MCP clients accept the same stdio config Claude Desktop does.
          Drop the same snippet into the MCP-servers section of their
          settings JSON. Daisy&rsquo;s{" "}
          <strong>Copy snippet</strong> button gives you the exact
          block, formatted right.
        </p>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Some clients support direct SSE without the bridge — in that
          case skip <code className="text-xs">mcp-remote</code> and
          point them at{" "}
          <code className="rounded bg-[color:var(--color-bg-elevated)] px-1.5 py-0.5 text-xs">
            http://127.0.0.1:54321/sse
          </code>{" "}
          directly.
        </p>
      </section>

      <section className="mb-12 space-y-6">
        <h2 className="font-display text-2xl font-semibold tracking-tight">
          What to actually ask the AI
        </h2>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Once Daisy shows up in your AI&rsquo;s tool list, the
          interesting prompts aren&rsquo;t &ldquo;use the list_sessions
          tool.&rdquo; They&rsquo;re natural-language asks that the
          model decomposes into multiple tool calls on its own:
        </p>

        <div className="space-y-4">
          <Example
            title="Quick lookup"
            prompts={[
              "Show me the transcript of my most recent meeting.",
              "What did I talk about on Tuesday?",
              "Pull the last 10 recordings tagged 'Mediacube'.",
            ]}
          />
          <Example
            title="Cross-session synthesis"
            prompts={[
              "Compile all the action items from my last 10 meetings into one list, grouped by owner.",
              "What did Maria say about pricing across our last three calls?",
              "Summarise everything happening with the Garna deal across every Daisy recording that mentions it.",
            ]}
          />
          <Example
            title="Drafting"
            prompts={[
              "Draft a follow-up email based on yesterday's Mediacube meeting.",
              "Write a Slack post for the team summarising this week's customer calls.",
              "Turn the action items from the last sprint planning recording into Linear-ready ticket titles + descriptions.",
            ]}
          />
          <Example
            title="Analytics"
            prompts={[
              "How many meetings did I have last week? How long, on average?",
              "Which client takes up the most meeting time in my calendar?",
              "List every meeting where I committed to sending something, but the email never went out.",
            ]}
          />
          <Example
            title="Acting on your library"
            prompts={[
              "In yesterday's call, speaker A is Maria and speaker B is Tim — rename them and re-summarize.",
              "Re-summarize Tuesday's standup in English.",
              "Send the last sprint-planning session to Linear.",
            ]}
          />
        </div>
      </section>

      <section className="mb-12 space-y-4">
        <h2 className="font-display text-2xl font-semibold tracking-tight">
          Troubleshooting
        </h2>
        <dl className="space-y-6 text-[color:var(--color-ink-secondary)]">
          <div>
            <dt className="mb-1 font-semibold text-[color:var(--color-ink)]">
              Claude says &ldquo;Some MCP servers could not be loaded&rdquo;
            </dt>
            <dd className="leading-relaxed">
              The config schema is wrong — likely an old{" "}
              <code className="text-xs">&#123;&quot;url&quot;: ...&#125;</code>{" "}
              entry from a previous Daisy build. Use the manual snippet
              above (command/args shape) and restart Claude.
            </dd>
          </div>
          <div>
            <dt className="mb-1 font-semibold text-[color:var(--color-ink)]">
              Claude doesn&rsquo;t show Daisy in the tool list
            </dt>
            <dd className="leading-relaxed">
              You didn&rsquo;t fully quit Claude — close the window
              isn&rsquo;t enough. ⌘Q or force-quit in Activity Monitor,
              then reopen.
            </dd>
          </div>
          <div>
            <dt className="mb-1 font-semibold text-[color:var(--color-ink)]">
              First tool call hangs for 10+ seconds
            </dt>
            <dd className="leading-relaxed">
              Expected on first run —{" "}
              <code className="text-xs">npx</code> is downloading the
              {" "}<code className="text-xs">mcp-remote</code> package
              (~2 MB). Subsequent calls are instant.
            </dd>
          </div>
          <div>
            <dt className="mb-1 font-semibold text-[color:var(--color-ink)]">
              &ldquo;Connection refused&rdquo; / no Daisy data comes back
            </dt>
            <dd className="leading-relaxed">
              Daisy app needs to be running AND the MCP toggle ON.
              Check Daisy → Connections → MCP server: the badge should
              read <em>Running</em>. If it says <em>Error</em>, hover
              for the specific message.
            </dd>
          </div>
          <div>
            <dt className="mb-1 font-semibold text-[color:var(--color-ink)]">
              Port 54321 already taken
            </dt>
            <dd className="leading-relaxed">
              Change the port in Daisy&rsquo;s settings, then click
              <strong> Add to Claude Desktop</strong> again — the
              config gets rewritten with the new port. Restart Claude.
            </dd>
          </div>
          <div>
            <dt className="mb-1 font-semibold text-[color:var(--color-ink)]">
              Sanity-check the bridge from Terminal
            </dt>
            <dd className="leading-relaxed">
              <code className="text-xs">curl -sN http://127.0.0.1:54321/sse</code>{" "}
              should open a streaming connection that hangs (correct —
              it&rsquo;s SSE). <code className="text-xs">Ctrl+C</code>{" "}
              to close. If you see <em>Connection refused</em>, the
              Daisy server isn&rsquo;t listening.
            </dd>
          </div>
        </dl>
      </section>

      <section className="space-y-4">
        <h2 className="font-display text-2xl font-semibold tracking-tight">
          Privacy reminder
        </h2>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          The Daisy MCP server only binds to{" "}
          <code className="text-xs">127.0.0.1</code> (loopback). Other
          machines on your network can&rsquo;t reach it. Cross-origin
          browser requests are blocked. Your transcripts never leave
          your Mac — Claude (or whichever client you use) pulls them
          locally through the bridge and processes them under its own
          rules. See the{" "}
          <Link
            href="/privacy"
            className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            Privacy page
          </Link>{" "}
          for the full posture.
        </p>
      </section>
    </div>
  );
}

function Example({
  title,
  prompts,
}: {
  title: string;
  prompts: string[];
}) {
  return (
    <div className="rounded-xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] p-5">
      <p className="mb-3 text-sm font-semibold uppercase tracking-wider text-[color:var(--color-ink-tertiary)]">
        {title}
      </p>
      <ul className="space-y-2 text-sm text-[color:var(--color-ink-secondary)]">
        {prompts.map((p) => (
          <li key={p} className="italic">
            &ldquo;{p}&rdquo;
          </li>
        ))}
      </ul>
    </div>
  );
}
