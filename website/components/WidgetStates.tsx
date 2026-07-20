import { Eyebrow } from "./Eyebrow";
import { DAISY_PETALS } from "../lib/daisyPetals";

// Widget States showcase.
//
// The Daisy widget IS a small flower: 8 teardrop petals around a 10pt
// coloured centre, sitting on a near-black puck (#121215). The petals
// dance with the audio spectrum during recording, settle when idle,
// uniform-shimmer-rotate during processing. The centre is what
// changes colour — and the centre is the entire state vocabulary.
//
// Colours and states are pulled directly from `DaisyColors.swift` and
// `DaisyWidget.swift.centerColor(_:)`. Nothing here is invented.

const LIFECYCLE_STATES = [
  {
    state: "idle",
    label: "Idle",
    caption: "I&rsquo;m here when you need me.",
    centerColor: "rgba(255, 255, 255, 0.55)",
    centerShadow: "rgba(255, 255, 255, 0.10)",
    note: "white centre · petals settled",
    pulse: false,
  },
  {
    state: "recording",
    label: "Recording",
    caption: "Capturing. Forget I&rsquo;m on.",
    // Hexes below mirror the app's DARK palette variants — Daisy is
    // dark-only, so these are the colours the widget actually renders
    // (DaisyColors.swift dark values), not the light-theme tokens.
    centerColor: "#FF9F0A", // daisyRecording (dark) — Apple systemOrange family
    centerShadow: "rgba(255, 159, 10, 0.55)",
    note: "macOS orange · petals dance with audio",
    pulse: true,
  },
  {
    state: "paused",
    label: "Paused",
    caption: "Held. Resume any time.",
    centerColor: "#7D828B", // daisyPaused (dark) — cool slate
    centerShadow: "rgba(125, 130, 139, 0.40)",
    note: "cool gray · petals quiet",
    pulse: false,
  },
  {
    state: "summarizing",
    label: "Summarizing",
    caption: "Working on it in the background.",
    centerColor: "#FFA826", // daisyCenterIdle (dark) — pulsing amber post-stop
    centerShadow: "rgba(255, 168, 38, 0.55)",
    note: "amber · slow pulse · shimmer sweep",
    pulse: true,
  },
];

const MODE_COLORS = [
  // Dark-palette variants from DaisyColors.swift — see note above.
  {
    label: "Meeting",
    color: "#FF9F0A", // daisyRecording (dark)
    shadow: "rgba(255, 159, 10, 0.55)",
    body: "macOS systemOrange — the same dot you trust at the top of the screen.",
    shipped: true,
  },
  {
    label: "Dictation",
    color: "#B48BF2", // daisyDictation (dark)
    shadow: "rgba(180, 139, 242, 0.55)",
    body: "Lilac — Wispr Flow-style audio-to-text, anywhere you type.",
    shipped: true,
  },
  {
    label: "Voice notes",
    color: "#F49DAA", // daisyVoiceNote (dark)
    shadow: "rgba(244, 157, 170, 0.55)",
    body: "Pink-coral — quick one-off thoughts, straight to your Library.",
    shipped: true,
  },
];

export function WidgetStates() {
  return (
    <section
      id="widget"
      className="relative border-t border-[color:var(--color-divider)] bg-[color:var(--color-bg-sidebar)] px-6 py-24 md:py-32"
    >
      <div className="mx-auto max-w-5xl">
        <Eyebrow>The widget</Eyebrow>
        <h2 className="mb-6 max-w-3xl font-display text-3xl font-semibold leading-tight tracking-tight md:text-4xl">
          A small flower at the edge of your screen, telling you what
          Daisy is doing.
        </h2>
        <p className="mb-16 max-w-3xl text-lg leading-relaxed text-[color:var(--color-ink-secondary)]">
          Eight petals around a coloured centre, on a near-black puck.
          The centre changes hue, the petals dance with your voice —
          and that&rsquo;s the whole UI. No window, no chrome, no copy
          to read. You glance at the corner of your screen and you
          know.
        </p>

        <div className="grid gap-6 sm:grid-cols-2 md:grid-cols-4">
          {LIFECYCLE_STATES.map((s) => (
            <div
              key={s.state}
              className="flex flex-col items-center rounded-2xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] p-6 text-center"
            >
              <DaisyPuck
                centerColor={s.centerColor}
                centerShadow={s.centerShadow}
                pulse={s.pulse}
              />
              <p className="mt-5 text-xs font-medium uppercase tracking-widest text-[color:var(--color-ink-tertiary)]">
                {s.label}
              </p>
              <p
                className="mt-1 font-display text-base font-medium leading-snug text-[color:var(--color-ink-primary)]"
                dangerouslySetInnerHTML={{ __html: `&ldquo;${s.caption}&rdquo;` }}
              />
              <p className="mt-2 text-xs leading-relaxed text-[color:var(--color-ink-tertiary)]">
                {s.note}
              </p>
            </div>
          ))}
        </div>

        <div className="mt-16">
          <p className="mb-5 text-xs font-medium uppercase tracking-widest text-[color:var(--color-ink-tertiary)]">
            Three modes, three centres
          </p>
          <div className="grid gap-4 md:grid-cols-3">
            {MODE_COLORS.map((m) => (
              <div
                key={m.label}
                className={`flex items-start gap-4 rounded-xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg-elevated)] p-5 ${
                  m.shipped ? "" : "opacity-70"
                }`}
              >
                <DaisyPuck
                  centerColor={m.color}
                  centerShadow={m.shadow}
                  pulse={false}
                  size={56}
                />
                <div className="flex flex-col">
                  <span className="flex items-center gap-2 font-display text-sm font-semibold text-[color:var(--color-ink-primary)]">
                    {m.label}
                    {!m.shipped && (
                      <span className="rounded-full border border-[color:var(--color-divider)] px-2 py-0.5 text-[10px] font-medium uppercase tracking-wider text-[color:var(--color-ink-tertiary)]">
                        Soon
                      </span>
                    )}
                  </span>
                  <span className="mt-1 text-xs leading-relaxed text-[color:var(--color-ink-secondary)]">
                    {m.body}
                  </span>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}

// DaisyPuck — static widget mark on a near-black puck. Reuses the
// canonical brand petal geometry (DAISY_PETALS, the same shape as the
// nav/footer logo and the in-app DaisyMark) so the website never drifts
// from the product. Only the centre disc changes colour to signal state.
function DaisyPuck({
  centerColor,
  centerShadow,
  pulse,
  size = 72,
}: {
  centerColor: string;
  centerShadow: string;
  pulse: boolean;
  size?: number;
}) {
  // Petals live in a 41×41 viewBox centred on (20.5, 20.5).
  const CENTER = 20.5;
  const centerR = 4.5;

  return (
    <div
      className="relative flex shrink-0 items-center justify-center rounded-full"
      style={{
        width: size,
        height: size,
        // Match the in-app dark puck: Color(red:0.07, green:0.07, blue:0.085)
        background: "#121215",
        boxShadow:
          "0 1px 2px rgba(0,0,0,0.06), 0 4px 12px rgba(0,0,0,0.10)",
      }}
      aria-hidden
    >
      <svg
        viewBox="0 0 41 41"
        width={size * 0.78}
        height={size * 0.78}
        style={{ overflow: "visible" }}
      >
        {/* Brand petals — white on the dark puck */}
        {DAISY_PETALS.map((d, i) => (
          <path key={i} d={d} fill="rgba(247, 247, 245, 0.92)" />
        ))}
        {/* Centre disc — the state colour */}
        <circle
          cx={CENTER}
          cy={CENTER}
          r={centerR}
          fill={centerColor}
          style={{
            filter: `drop-shadow(0 0 ${pulse ? 4 : 2}px ${centerShadow})`,
          }}
        />
        {/* Pulse halo — animated only when pulse=true */}
        {pulse && (
          <circle
            cx={CENTER}
            cy={CENTER}
            r={centerR}
            fill={centerColor}
            opacity={0.35}
          >
            <animate
              attributeName="r"
              from={centerR}
              to={centerR + 4}
              dur="1.6s"
              repeatCount="indefinite"
            />
            <animate
              attributeName="opacity"
              from="0.45"
              to="0"
              dur="1.6s"
              repeatCount="indefinite"
            />
          </circle>
        )}
      </svg>
    </div>
  );
}
