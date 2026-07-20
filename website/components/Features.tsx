import { Eyebrow } from "./Eyebrow";

// Feature cards, ordered by the objections a Mac-developer / consultant
// will surface in this order when they first land:
//   1. "Does it actually capture the other person?" (the bot-in-the-
//      meeting alternative is what they're escaping from)
//   2. "Will it transcribe accurately, even when people mumble or
//      switch languages?" (Whisper + Silero VAD + diarisation)
//   3. "Where do my transcripts live?" (Library folder, no cloud)
//   4. "How do I plug this into the tools I already use?" (MCP
//      server is the unique-to-Daisy moat — no competitor offers
//      this, because they all live in the cloud)
//   5. "Will I be locked into a specific AI vendor?" (BYOAI; covered
//      in the next section so kept short here)
const FEATURES = [
  {
    icon: "mic",
    title: "Records what everyone said",
    body:
      "Captures your microphone and the other side of the call together — Zoom, Meet, Telegram, anything that plays audio on your Mac. No bot in the meeting, no link to install.",
  },
  {
    icon: "waveform",
    title: "Accurate even when people mumble",
    body:
      "On-device WhisperKit on the Neural Engine, paired with Silero VAD pre-pass so silences don't hallucinate into text. On-device Pyannote diarisation labels remote voices (`Remote A`, `Remote B`); flip on mic-side diarisation and your own display name is attributed too.",
  },
  {
    icon: "folder",
    title: "Transcripts live in your folder",
    body:
      "Markdown files in the folder you choose — Obsidian vault, iCloud Drive, anywhere. Daisy never holds your data on a server you don't own. Inspect, copy, delete: they're yours, on your disk.",
  },
  {
    icon: "mcp",
    title: "A live data source for Claude Desktop",
    body:
      "Daisy ships an MCP server bound to 127.0.0.1. One click writes the config and Claude Desktop, Cursor, or any MCP client can query your transcripts directly. No copy-paste, no API token, no upload.",
  },
];

export function Features() {
  return (
    <section
      id="features"
      className="relative border-t border-[color:var(--color-divider)] bg-[color:var(--color-bg-sidebar)] px-6 py-24 md:py-32"
    >
      <div className="mx-auto max-w-5xl">
        <Eyebrow>What it does</Eyebrow>
        <h2 className="mb-16 max-w-3xl font-display text-3xl font-semibold leading-tight tracking-tight md:text-4xl">
          The whole meeting workflow, sitting quietly in the corner of
          your screen.
        </h2>

        {/* 2x2 grid on md+, single-column on mobile. Four cards
            land more honestly than three forced-equal columns —
            and gives the MCP card visual room to breathe. */}
        <div className="grid gap-6 md:grid-cols-2">
          {FEATURES.map((f) => (
            <div
              key={f.title}
              className="rounded-2xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] p-6"
            >
              <Icon name={f.icon} />
              <h3 className="mt-5 mb-2 font-display text-lg font-semibold">{f.title}</h3>
              <p className="text-sm leading-relaxed text-[color:var(--color-ink-secondary)]">
                {f.body}
              </p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}

function Icon({ name }: { name: string }) {
  // SF-Symbols-inspired minimal glyphs. Bumped from 22px to 26px
  // and stroke from 1.6 to 1.8 — the original sizing felt anemic
  // next to the H3 weight. Same family, more presence.
  const stroke = "var(--color-ink)";
  const common = {
    width: 26,
    height: 26,
    viewBox: "0 0 24 24",
    fill: "none" as const,
    stroke,
    strokeWidth: 1.8,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
  };

  switch (name) {
    case "mic":
      return (
        <svg {...common} aria-hidden>
          <rect x="9" y="3" width="6" height="11" rx="3" />
          <path d="M5 11a7 7 0 0 0 14 0" />
          <path d="M12 18v3" />
        </svg>
      );
    case "waveform":
      return (
        <svg {...common} aria-hidden>
          <path d="M3 12h2" />
          <path d="M7 8v8" />
          <path d="M11 5v14" />
          <path d="M15 9v6" />
          <path d="M19 11v2" />
          <path d="M21 12h-2" />
        </svg>
      );
    case "folder":
      return (
        <svg {...common} aria-hidden>
          <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7Z" />
        </svg>
      );
    case "mcp":
      // Three-node hub glyph — center node connected to two
      // peripherals. Visually communicates "service that other
      // clients connect to" without literal "API" iconography.
      return (
        <svg {...common} aria-hidden>
          <circle cx="12" cy="12" r="3" />
          <circle cx="4" cy="6" r="1.5" />
          <circle cx="20" cy="6" r="1.5" />
          <circle cx="4" cy="18" r="1.5" />
          <circle cx="20" cy="18" r="1.5" />
          <path d="M5.2 7l3.7 3.5M18.8 7l-3.7 3.5M5.2 17l3.7-3.5M18.8 17l-3.7-3.5" />
        </svg>
      );
    default:
      return null;
  }
}
