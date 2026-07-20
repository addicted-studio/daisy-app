import { Eyebrow } from "./Eyebrow";

// "How Daisy compares" — replaces the old wall-of-text accuracy block
// (rewritten 2026-06-27). Two parts, both deliberately honest:
//
//   1. A scannable feature table. Daisy is the rare tool that does BOTH
//      meeting recording AND dictation, so we line it up against both
//      camps: the meeting note-takers (Granola / Otter / Fireflies /
//      Meetily) and the dictation tool (Wispr Flow). The "What it does"
//      and "Dictation" rows make the spanning advantage obvious — Daisy
//      is the only column with values in both halves. Daisy column is
//      emphasised. Every cell is a short, verifiable phrase — no made-up
//      accuracy %, no competitor shown losing on a number we can't
//      measure. "Cloud" is the uniform token for "runs on / stored on
//      the vendor's servers"; "—" means the tool doesn't do that thing.
//
//   2. A compact strip of THIRD-PARTY engine-diarisation benchmarks.
//      We still refuse to publish a Daisy-measured DER (we haven't run
//      a labelled benchmark) — instead we cite the engine's published
//      offline numbers and explain why Daisy's Stop-time offline
//      re-pass lands on the better side of them. Sources below.
//
// Competitor facts verified June 2026 against each vendor's site /
// GitHub. If any drift, fix here (and on the matching /alternatives
// page, which shares the Granola/Otter facts).

const COMPETITORS = [
  { key: "granola", label: "Granola" },
  { key: "otter", label: "Otter" },
  { key: "fireflies", label: "Fireflies" },
  { key: "meetily", label: "Meetily" },
  { key: "wispr", label: "Wispr Flow" },
] as const;

type CompetitorKey = (typeof COMPETITORS)[number]["key"];

type Row = { feature: string; daisy: string } & Record<CompetitorKey, string>;

const ROWS: ReadonlyArray<Row> = [
  {
    feature: "What it does",
    daisy: "Meetings + dictation",
    granola: "Meetings",
    otter: "Meetings",
    fireflies: "Meetings",
    meetily: "Meetings",
    wispr: "Dictation",
  },
  {
    feature: "Transcripts stored",
    daisy: "Your Mac, never uploaded",
    granola: "Cloud",
    otter: "Cloud",
    fireflies: "Cloud",
    meetily: "Your device",
    wispr: "Cloud",
  },
  {
    feature: "Transcription",
    daisy: "On-device (Whisper, ANE)",
    granola: "Cloud",
    otter: "Cloud",
    fireflies: "Cloud",
    meetily: "On-device (Whisper / Parakeet)",
    wispr: "Cloud",
  },
  {
    feature: "Speaker diarization",
    daisy: "On-device, offline re-pass",
    granola: "Cloud",
    otter: "Cloud",
    fireflies: "Cloud",
    meetily: "On-device",
    wispr: "—",
  },
  {
    feature: "AI summary",
    daisy: "Your own key",
    granola: "OpenAI · Anthropic · Google",
    otter: "Own model",
    fireflies: "OpenAI (GPT)",
    meetily: "Local or your key",
    wispr: "—",
  },
  {
    feature: "In the call",
    daisy: "No bot — local capture",
    granola: "No bot — local capture",
    otter: "Bot auto-joins",
    fireflies: "Bot joins",
    meetily: "No bot — local capture",
    wispr: "—",
  },
  {
    feature: "Dictation / push-to-talk",
    daisy: "Yes (Whisper / Parakeet)",
    granola: "—",
    otter: "—",
    fireflies: "—",
    meetily: "—",
    wispr: "Yes (cloud)",
  },
  {
    feature: "Works offline",
    daisy: "Yes",
    granola: "No",
    otter: "No",
    fireflies: "No",
    meetily: "Yes",
    wispr: "No",
  },
  {
    feature: "Open source",
    daisy: "Apache 2.0",
    granola: "No",
    otter: "No",
    fireflies: "No",
    meetily: "MIT",
    wispr: "No",
  },
  {
    feature: "Local MCP server",
    daisy: "Yes — local, free",
    granola: "Cloud — paid plans",
    otter: "No",
    fireflies: "No",
    meetily: "No",
    wispr: "No",
  },
  {
    feature: "Pricing",
    daisy: "Free",
    granola: "$14–18 / user-mo",
    otter: "$8–20 / user-mo",
    fireflies: "$10–19 / user-mo",
    meetily: "Free (MIT) · Pro $10/mo",
    wispr: "$12–15 / mo",
  },
  {
    feature: "Platforms",
    daisy: "macOS (M1+)",
    granola: "Mac · Win · iOS",
    otter: "Web · iOS · Android · Mac · Win",
    fireflies: "Web + integrations",
    meetily: "Mac · Win · Linux",
    wispr: "Mac · Win · iOS · Android",
  },
  {
    // Approximate — vendors don't publish install sizes. Granola/Wispr
    // ship as Electron (~300 MB); Daisy & Meetily are native but pull
    // local STT models onto disk (the cost of on-device processing).
    feature: "Disk footprint",
    daisy: "~1–2 GB (app + local models)",
    granola: "~300 MB (Electron)",
    otter: "Web / light app",
    fireflies: "Web-based",
    meetily: "~1–2 GB (app + local models)",
    wispr: "~300 MB (Electron)",
  },
];

// Third-party diarisation-error (DER) numbers. Lower is better.
const BENCH: { stat: string; label: string }[] = [
  {
    stat: "26–27%",
    label: "Cloud diarization error on real meetings — the major engines, within a point of each other",
  },
  {
    stat: "26–50%",
    label: "Real-time (streaming) diarization error — splits one person into several",
  },
  {
    stat: "~10–15%",
    label: "FluidAudio offline error — the grade Daisy's Stop-time re-pass earns",
  },
];

const SOURCES: { label: string; href: string }[] = [
  {
    label: "Cloud DER on real meetings (Scribie)",
    href: "https://scribie.com/blog/speech-to-text-accuracy-benchmark-assemblyai-deepgram-whisperx",
  },
  {
    label: "FluidAudio offline + streaming DER",
    href: "https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md",
  },
  {
    label: "pyannote accuracy",
    href: "https://www.pyannote.ai/blog/precision-2",
  },
  {
    label: "Why cross-talk is the limiter (Circleback)",
    href: "https://circleback.ai/blog/how-ai-meeting-notes-work",
  },
];

export function Accuracy() {
  return (
    <section
      id="accuracy"
      className="relative border-t border-[color:var(--color-divider)] px-6 py-24 md:py-32"
    >
      <div className="mx-auto max-w-5xl">
        <Eyebrow>Straight talk</Eyebrow>
        <h2 className="mb-4 font-display text-3xl font-semibold leading-tight tracking-tight md:text-4xl">
          How Daisy compares.
        </h2>
        <p className="mb-12 max-w-2xl text-lg leading-relaxed text-[color:var(--color-ink-secondary)]">
          Most tools pick one job — record meetings, or dictate. Daisy does
          both, on your Mac. Here it is next to the meeting note-takers and
          the dictation app you might be using instead.
        </p>

        {/* Feature table. overflow-x-auto + min-width keeps it readable
            on mobile; the Feature column is sticky so you keep your
            bearings while scrolling the product columns sideways. */}
        <div className="overflow-x-auto rounded-2xl border border-[color:var(--color-divider)]">
          <table className="w-full min-w-[860px] border-collapse text-left text-[13px]">
            <thead>
              <tr className="bg-[color:var(--color-bg-elevated)]">
                <th className="sticky left-0 z-10 bg-[color:var(--color-bg-elevated)] px-4 py-3.5 font-medium text-[color:var(--color-ink-tertiary)]">
                  Feature
                </th>
                <th className="border-x border-[color:var(--color-accent)]/30 bg-[color:var(--color-accent)]/[0.08] px-4 py-3.5 font-semibold text-[color:var(--color-accent)]">
                  Daisy
                </th>
                {COMPETITORS.map((c) => (
                  <th
                    key={c.key}
                    className="px-4 py-3.5 font-medium text-[color:var(--color-ink-secondary)]"
                  >
                    {c.label}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {ROWS.map((row) => (
                <tr
                  key={row.feature}
                  className="border-t border-[color:var(--color-divider)] align-top"
                >
                  <th
                    scope="row"
                    className="sticky left-0 z-10 bg-[color:var(--color-bg)] px-4 py-3.5 text-left font-medium text-[color:var(--color-ink)]"
                  >
                    {row.feature}
                  </th>
                  <td className="border-x border-[color:var(--color-accent)]/30 bg-[color:var(--color-accent)]/[0.06] px-4 py-3.5 text-[color:var(--color-ink)]">
                    {row.daisy}
                  </td>
                  {COMPETITORS.map((c) => (
                    <td
                      key={c.key}
                      className="px-4 py-3.5 text-[color:var(--color-ink-secondary)]"
                    >
                      {row[c.key]}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {/* Engine-accuracy benchmarks. The one place we talk numbers —
            and they're all third-party. */}
        <div className="mt-16">
          <h3 className="font-display text-xl font-semibold tracking-tight">
            Why &ldquo;who said what&rdquo; is the hard part
          </h3>
          <p className="mt-3 max-w-2xl text-sm leading-relaxed text-[color:var(--color-ink-secondary)]">
            Modern speech-to-text gets the words right ~95% of the time.
            Knowing <em>who</em> said each line — diarization — is what
            trips up every tool. Daisy doesn&rsquo;t trust the live pass:
            when you hit Stop it re-diarizes offline, so your saved
            transcript gets the offline grade, not the streaming one.
          </p>

          <div className="mt-8 grid gap-4 sm:grid-cols-3">
            {BENCH.map((b) => (
              <div
                key={b.stat}
                className="rounded-2xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] p-5"
              >
                <div className="font-display text-3xl font-semibold tracking-tight text-[color:var(--color-ink)]">
                  {b.stat}
                </div>
                <p className="mt-2 text-xs leading-relaxed text-[color:var(--color-ink-secondary)]">
                  {b.label}
                </p>
              </div>
            ))}
          </div>

          <p className="mt-8 text-xs leading-relaxed text-[color:var(--color-ink-tertiary)]">
            These are published third-party benchmarks, not numbers we
            cooked up — we haven&rsquo;t run our own labeled benchmark yet,
            so we won&rsquo;t pretend to. Sources:{" "}
            {SOURCES.map((s, i) => (
              <span key={s.href}>
                <a
                  href={s.href}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="underline decoration-[color:var(--color-divider)] underline-offset-2 hover:text-[color:var(--color-ink-secondary)]"
                >
                  {s.label}
                </a>
                {i < SOURCES.length - 1 ? " · " : ""}
              </span>
            ))}
          </p>
        </div>
      </div>
    </section>
  );
}
