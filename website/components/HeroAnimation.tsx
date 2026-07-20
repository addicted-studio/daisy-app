"use client";

import { useEffect, useRef } from "react";
import { DAISY_PETALS } from "../lib/daisyPetals";

/*
 * HeroAnimation — coordinated landing piece for the top of the page.
 *
 * ONE master clock drives the whole composition (rebuilt 2026-06-01).
 * The old version ran the daisy lifecycle and the chat/transcript on two
 * independent loops (7 s vs 10 s) that drifted apart immediately, so the
 * "record → transcript" story it claimed to tell only lined up by
 * accident. Now a single timeline makes the handoff causal:
 *
 *   idle → start → recording  (bubbles appear one-by-one, live audio)
 *        → stopping            (bubbles collapse toward the card)
 *        → finished            (daisy pops as the transcript resolves)
 *        → idle (loop)
 *
 * The daisy phase, the bubbles, and the transcript reveal are all derived
 * from the same `t`, so the flower is *always* recording while the
 * conversation is live and *always* finishes as the transcript forms.
 *
 * Ref-driven: a single requestAnimationFrame mutates transforms/opacity
 * directly — no per-frame React state, no reconciliation churn. The stage
 * is authored at a fixed design size and scaled to fit its column, so it
 * can never clip on a narrow (mobile) viewport. Respects
 * `prefers-reduced-motion` — paints a single representative frame.
 */

type Who = "you" | "remote";

interface Line {
  who: Who;
  text: string;
  /// Seconds into the loop when this bubble appears (during recording).
  appearAt: number;
  /// Resting offset from the mark centre, in design px.
  ox: number;
  oy: number;
}

// ── Master timeline (seconds) ────────────────────────────────────────
const LOOP = 11.5;
const T_START = 0.9; // idle → pop-in
const T_REC = 1.5; // recording begins (bubbles populate from here)
const T_STOP = 7.2; // stopping begins (bubbles collapse)
const T_FIN = 7.8; // finished pop — transcript resolves with it
const T_HOLD = 9.0; // transcript fully revealed, holds
const T_FADE = 10.2; // card fades, daisy settles back to idle
const T_STATIC = 6.6; // reduced-motion frame: late recording, all bubbles up

export function HeroAnimation({ size = 200 }: { size?: number }) {
  const wrapRef = useRef<HTMLDivElement>(null);
  const stageRef = useRef<HTMLDivElement>(null);
  const markRef = useRef<HTMLDivElement>(null);
  const centerRef = useRef<SVGCircleElement>(null);
  const haloRef = useRef<SVGCircleElement>(null);
  const bubbleRefs = useRef<(HTMLDivElement | null)[]>([]);
  const lineRefs = useRef<(HTMLDivElement | null)[]>([]);
  const cardRef = useRef<HTMLDivElement>(null);

  // Geometry — everything authored in this fixed design box, then the
  // whole box is scaled to fit the column (never clips on mobile).
  const S = size;
  const DESIGN_W = S * 2.05;
  const DESIGN_H = S * 2.35;
  const CX = DESIGN_W / 2;
  const CY = S * 0.95; // mark centre sits a little above the box middle
  const COLLAPSE_Y = S * 0.7; // where bubbles dock into the transcript card

  const LINES: Line[] = [
    { who: "remote", text: "So how's Q3 looking?", appearAt: 2.0, ox: -S * 0.6, oy: -S * 0.5 },
    { who: "you", text: "Margins are tight.", appearAt: 3.1, ox: S * 0.58, oy: -S * 0.3 },
    { who: "remote", text: "Can we hit the deadline?", appearAt: 4.2, ox: -S * 0.62, oy: -S * 0.04 },
    { who: "you", text: "If marketing pulls weight.", appearAt: 5.3, ox: S * 0.58, oy: S * 0.22 },
    { who: "remote", text: "I'll talk to Lena tomorrow.", appearAt: 6.4, ox: -S * 0.5, oy: S * 0.46 },
  ];

  useEffect(() => {
    const wrap = wrapRef.current;
    const stage = stageRef.current;
    if (!wrap || !stage) return;

    // Scale-to-fit: the design box shrinks to the column width and the
    // wrapper reserves the matching height. Pure layout, not motion —
    // runs even under reduced motion.
    const fit = () => {
      const scale = Math.min(1, wrap.clientWidth / DESIGN_W);
      stage.style.transform = `translateX(-50%) scale(${scale})`;
      wrap.style.height = `${DESIGN_H * scale}px`;
    };
    fit();
    const ro = new ResizeObserver(fit);
    ro.observe(wrap);

    const paint = (t: number) => {
      // ── Daisy lifecycle (derived from the same clock) ──────────────
      let phase: "idle" | "start" | "recording" | "stopping" | "finished";
      let prog: number;
      let recClock = 0;
      if (t < T_START) {
        phase = "idle";
        prog = t / T_START;
      } else if (t < T_REC) {
        phase = "start";
        prog = (t - T_START) / (T_REC - T_START);
      } else if (t < T_STOP) {
        phase = "recording";
        prog = (t - T_REC) / (T_STOP - T_REC);
        recClock = (t - T_REC) * 1000;
      } else if (t < T_FIN) {
        phase = "stopping";
        prog = (t - T_STOP) / (T_FIN - T_STOP);
      } else if (t < T_HOLD) {
        phase = "finished";
        prog = (t - T_FIN) / (T_HOLD - T_FIN);
      } else {
        phase = "idle";
        prog = 1;
      }

      const passive =
        phase === "idle"
          ? 0.78
          : phase === "start"
            ? 0.78 + 0.22 * easeInOut(prog)
            : phase === "finished"
              ? 1 - 0.22 * easeInOut(prog)
              : 1.0;
      const pop = phase === "start" || phase === "finished" ? 1 + 0.06 * Math.sin(prog * Math.PI) : 1;
      const breath = phase === "recording" ? 1 + 0.02 * Math.sin(recClock / 380) : 1;
      if (markRef.current) {
        markRef.current.style.transform = `scale(${(passive * pop * breath).toFixed(4)})`;
      }
      if (centerRef.current) {
        centerRef.current.setAttribute(
          "fill",
          phase === "recording"
            ? "var(--color-recording)"
            : phase === "finished"
              ? "var(--color-accent-soft)"
              : phase === "idle"
                ? "var(--color-petal-center)"
                : "var(--color-accent-soft)",
        );
      }
      if (haloRef.current) {
        if (phase === "recording") {
          haloRef.current.setAttribute("stroke-opacity", "0.45");
          haloRef.current.setAttribute("r", (4.5 + 1.6 * (0.5 + 0.5 * Math.sin(recClock / 200))).toFixed(3));
        } else {
          haloRef.current.setAttribute("stroke-opacity", "0");
        }
      }

      // ── Bubbles → collapse into the card ───────────────────────────
      const collapse = easeOutCubic(clamp01((t - T_STOP) / (T_FIN - T_STOP)));
      const inCollapse = t >= T_STOP;
      for (let i = 0; i < LINES.length; i++) {
        const el = bubbleRefs.current[i];
        if (!el) continue;
        const L = LINES[i];
        const appear = t < L.appearAt ? 0 : Math.min(1, (t - L.appearAt) / 0.28);
        const x = lerp(L.ox, 0, collapse);
        const y = lerp(L.oy, COLLAPSE_Y, collapse);
        const sc = appear * (1 - collapse * 0.6);
        el.style.transform = `translate(-50%, -50%) translate(${x.toFixed(1)}px, ${y.toFixed(1)}px) scale(${sc.toFixed(3)})`;
        el.style.opacity = (inCollapse ? 1 - collapse : appear).toFixed(3);
      }

      // ── Transcript card (resolves as the daisy finishes) ───────────
      const tp = clamp01((t - T_STOP) / (T_HOLD - T_STOP));
      const appearC = easeOutCubic(clamp01((t - T_STOP) / (T_FIN - T_STOP)));
      const fade = clamp01((t - T_FADE) / (LOOP - T_FADE));
      const revealed = Math.min(LINES.length, Math.ceil(tp * LINES.length * 1.25));
      if (cardRef.current) {
        cardRef.current.style.opacity = (appearC * (1 - fade)).toFixed(3);
        cardRef.current.style.transform = `translateX(-50%) translateY(${((1 - appearC) * 18).toFixed(1)}px)`;
      }
      for (let i = 0; i < lineRefs.current.length; i++) {
        const row = lineRefs.current[i];
        if (!row) continue;
        const on = i < revealed;
        row.style.opacity = on ? "1" : "0";
        row.style.transform = on ? "translateY(0)" : "translateY(6px)";
      }
    };

    const mql = window.matchMedia("(prefers-reduced-motion: reduce)");
    if (mql.matches) {
      paint(T_STATIC);
      return () => ro.disconnect();
    }

    const start = performance.now();
    let raf = 0;
    const loop = (now: number) => {
      paint(((now - start) / 1000) % LOOP);
      raf = requestAnimationFrame(loop);
    };
    raf = requestAnimationFrame(loop);
    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [size]);

  return (
    <div ref={wrapRef} className="relative mx-auto w-full" style={{ maxWidth: DESIGN_W }} aria-hidden>
      <div
        ref={stageRef}
        className="absolute left-1/2 top-0"
        style={{ width: DESIGN_W, height: DESIGN_H, transformOrigin: "top center" }}
      >
        {/* Daisy mark — centred */}
        <div className="absolute" style={{ left: CX, top: CY, transform: "translate(-50%, -50%)" }}>
          <div
            ref={markRef}
            className="select-none"
            style={{ width: S, height: S, willChange: "transform" }}
          >
            <svg
              viewBox="0 0 41 41"
              width={S}
              height={S}
              xmlns="http://www.w3.org/2000/svg"
              style={{
                filter:
                  "drop-shadow(0 4px 20px rgba(166, 110, 42, 0.22)) drop-shadow(0 1px 2px rgba(166, 110, 42, 0.20))",
              }}
            >
              {DAISY_PETALS.map((d, i) => (
                <path key={i} d={d} fill="var(--color-ink)" />
              ))}
              {/* Recording halo (behind the centre disc) */}
              <circle
                ref={haloRef}
                cx="20.5"
                cy="20.5"
                r="4.5"
                fill="none"
                stroke="var(--color-recording-pulse)"
                strokeOpacity={0}
                strokeWidth={0.9}
              />
              {/* Centre disc */}
              <circle ref={centerRef} cx="20.5" cy="20.5" r="4.5" fill="var(--color-petal-center)" />
            </svg>
          </div>
        </div>

        {/* Chat bubbles around the daisy */}
        {LINES.map((line, i) => {
          const isYou = line.who === "you";
          return (
            <div
              key={i}
              ref={(el) => {
                bubbleRefs.current[i] = el;
              }}
              className="absolute select-none"
              style={{
                left: CX,
                top: CY,
                opacity: 0,
                transform: "translate(-50%, -50%) scale(0)",
                pointerEvents: "none",
                willChange: "transform, opacity",
              }}
            >
              <div
                className="rounded-2xl px-3 py-2 text-sm leading-snug shadow-sm"
                style={{
                  maxWidth: S * 0.82,
                  background: isYou ? "var(--color-ink)" : "var(--color-bg-elevated)",
                  color: isYou ? "var(--color-bg)" : "var(--color-ink)",
                  border: isYou ? "none" : "1px solid var(--color-divider)",
                  borderBottomRightRadius: isYou ? 4 : 16,
                  borderBottomLeftRadius: isYou ? 16 : 4,
                }}
              >
                <div className="mb-0.5 text-[10px] font-medium uppercase tracking-widest" style={{ opacity: 0.5 }}>
                  {isYou ? "You" : "Remote A"}
                </div>
                {line.text}
              </div>
            </div>
          );
        })}

        {/* Transcript card — resolves as the bubbles dock */}
        <div
          ref={cardRef}
          className="absolute"
          style={{
            left: CX,
            top: CY + S * 0.55,
            width: Math.min(DESIGN_W - 24, 320),
            opacity: 0,
            transform: "translateX(-50%)",
            pointerEvents: "none",
            willChange: "transform, opacity",
          }}
        >
          <div
            className="rounded-2xl border p-4 shadow-lg"
            style={{ background: "var(--color-bg-elevated)", borderColor: "var(--color-divider)" }}
          >
            <div className="mb-2 flex items-center gap-2">
              <span
                className="inline-block h-1.5 w-1.5 rounded-full"
                style={{ background: "var(--color-success)" }}
              />
              <span className="text-[10px] font-medium uppercase tracking-widest text-[color:var(--color-ink-tertiary)]">
                Transcript · 0:42
              </span>
            </div>
            <div className="space-y-1.5">
              {LINES.map((line, i) => (
                <div
                  key={i}
                  ref={(el) => {
                    lineRefs.current[i] = el;
                  }}
                  className="flex gap-2 text-xs leading-relaxed"
                  style={{ opacity: 0, transform: "translateY(6px)", transition: "opacity 240ms ease, transform 240ms ease" }}
                >
                  <span
                    className="flex-shrink-0 font-medium"
                    style={{ width: 56, color: line.who === "you" ? "var(--color-ink)" : "var(--color-accent)" }}
                  >
                    {line.who === "you" ? "You" : "Remote A"}
                  </span>
                  <span className="text-[color:var(--color-ink-secondary)]">{line.text}</span>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

// ── Helpers ──────────────────────────────────────────────────────────

function clamp01(x: number): number {
  return Math.max(0, Math.min(1, x));
}

function lerp(a: number, b: number, t: number): number {
  return a + (b - a) * t;
}

function easeInOut(t: number): number {
  return t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
}

function easeOutCubic(t: number): number {
  return 1 - Math.pow(1 - t, 3);
}
