import { Eyebrow } from "./Eyebrow";

// Each promise gets a single concrete artefact users can point at:
// a path, a chip name, an API surface. The body copy used to bury
// these in prose — now they live in a separate `code` field that
// renders inline-mono, so a Mac developer can see "yes, that's the
// actual path on my disk" in one glance.
const PROMISES: { title: string; body: string; code?: string }[] = [
  {
    title: "Transcripts live in your folder",
    body:
      "Daisy writes Markdown into the folder you pick — typically an Obsidian vault or your iCloud Drive. Inspect, copy, delete, version-control: they're plain files on your disk. No \"feature\" that uploads them \"for your convenience\".",
    code: "~/Obsidian/Daisy/Sessions/",
  },
  {
    title: "Transcription runs on the Neural Engine",
    body:
      "WhisperKit runs fully on-device. Your audio is decoded into text by your own Mac — the same chip that does Face ID and Live Text. We never see it.",
  },
  {
    title: "Summaries — your call, your key",
    body:
      "Apple Intelligence works fully offline. If you bring an Anthropic or OpenAI key, that traffic goes from your machine straight to their API. Daisy is not a proxy. We never see your meetings or your key.",
  },
  {
    title: "MCP server is bound to localhost",
    body:
      "When you flip on the MCP server so Claude Desktop or Cursor can read your transcripts, Daisy listens on 127.0.0.1 only. Other Macs on your Wi-Fi, your phone, your work VPN — none of them can reach it. The server stops when you flip the toggle off.",
    code: "http://127.0.0.1:54321/sse",
  },
  {
    title: "No telemetry. No tracking. No account",
    body:
      "Daisy doesn't phone home. There's no signup, no email, no \"pro plan\" that unlocks if we know who you are. You install. It works.",
  },
];

export function PrivacyPromise() {
  return (
    <section
      id="privacy"
      className="relative border-t border-[color:var(--color-divider)] px-6 py-24 md:py-32"
    >
      <div className="mx-auto max-w-4xl">
        <Eyebrow>The deal</Eyebrow>
        <h2 className="mb-6 font-display text-3xl font-semibold leading-tight tracking-tight md:text-4xl">
          Your meetings stay on your Mac.
        </h2>
        <p className="mb-16 max-w-2xl text-lg leading-relaxed text-[color:var(--color-ink-secondary)]">
          Every other meeting tool wants your transcripts on their
          server &mdash; for indexing, for AI training, for whatever they
          haven&rsquo;t told you yet. Daisy doesn&rsquo;t. Here&rsquo;s
          exactly what that means.
        </p>

        <ul className="space-y-8">
          {PROMISES.map((p) => (
            <li key={p.title} className="grid gap-2 md:grid-cols-[1fr_2fr] md:gap-12">
              <h3 className="font-display text-base font-semibold leading-snug">{p.title}</h3>
              <div className="flex flex-col gap-2 text-sm leading-relaxed text-[color:var(--color-ink-secondary)]">
                <p>{p.body}</p>
                {p.code && (
                  <code className="self-start rounded bg-[color:var(--color-bg-sidebar)] px-1.5 py-0.5 font-mono text-[0.85em] text-[color:var(--color-ink-primary)]">
                    {p.code}
                  </code>
                )}
              </div>
            </li>
          ))}
        </ul>
      </div>
    </section>
  );
}
