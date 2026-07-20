import { Eyebrow } from "./Eyebrow";

// Dictation section.
//
// The homepage leads, correctly, with meetings + MCP — but the app
// also ships Wispr Flow-style push-to-talk dictation, and the only
// place that surfaced was the WidgetStates lilac dot and the FAQ.
// This section sells it without stealing the meetings narrative:
// placed right after WidgetStates so the lilac "Dictation" dot the
// visitor just saw gets one screen of explanation.
//
// Lilac (#B48BF2 = daisyDictation dark) is used only as a small
// accent dot in the eyebrow row, echoing the mode colour language
// established in WidgetStates — not as a full section recolour, so
// the dark theme stays intact.
//
// Every claim here is shipped behaviour: paste-at-cursor with
// clipboard restore (DictationPaste), Whisper default / Parakeet
// option, the vocabulary dictionary, and the rolling 24-hour history.

const DICTATION_POINTS = [
  {
    title: "Works anywhere you type",
    body:
      "Email, Slack, your editor, a form field — hold the hotkey, speak, release. The text is pasted at your cursor via the Accessibility API, and your previous clipboard is put back afterwards.",
  },
  {
    title: "On-device, your choice of engine",
    body:
      "Whisper on the Neural Engine by default, or switch to Parakeet (FluidAudio) for lower latency. No cloud round-trip and no API key needed — dictation never leaves the Mac.",
  },
  {
    title: "Teaches your words",
    body:
      "A vocabulary dictionary fixes names, brands, and jargon the model would otherwise mishear, applied right before the paste. A rolling 24-hour history lets you re-copy anything you dictated.",
  },
];

export function Dictation() {
  return (
    <section
      id="dictation"
      className="relative border-t border-[color:var(--color-divider)] px-6 py-24 md:py-32"
    >
      <div className="mx-auto max-w-5xl">
        <div className="flex items-center gap-2">
          {/* Lilac mode dot — same colour as the Dictation centre in
              WidgetStates, so the two sections read as one thought. */}
          <span
            aria-hidden
            className="inline-block h-2 w-2 rounded-full"
            style={{ backgroundColor: "#B48BF2", boxShadow: "0 0 8px rgba(180,139,242,0.55)" }}
          />
          <Eyebrow>Not only meetings</Eyebrow>
        </div>
        <h2 className="mb-6 max-w-3xl font-display text-3xl font-semibold leading-tight tracking-tight md:text-4xl">
          Hold a key, talk, and it lands as text &mdash; in any app.
        </h2>
        <p className="mb-16 max-w-3xl text-lg leading-relaxed text-[color:var(--color-ink-secondary)]">
          Daisy isn&rsquo;t only a meeting recorder. The same on-device
          pipeline powers push-to-talk dictation: hold your hotkey,
          speak, and the words appear at your cursor wherever you&rsquo;re
          typing &mdash; with nothing leaving your Mac.
        </p>

        <div className="grid gap-6 md:grid-cols-3">
          {DICTATION_POINTS.map((p) => (
            <div
              key={p.title}
              className="rounded-2xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] p-6"
            >
              <h3 className="mb-2 font-display text-base font-semibold tracking-tight">
                {p.title}
              </h3>
              <p className="text-sm leading-relaxed text-[color:var(--color-ink-secondary)]">
                {p.body}
              </p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
