"use client";

import { useEffect, useRef, useState } from "react";

/*
 * Hero widget — animated landing-page version of Daisy's mark.
 *
 * Geometry matches the static logomark used everywhere else in the
 * brand (app icon, in-app DaisyMark, favicon): 8 petals — 4 axis-
 * aligned and 4 diagonal — around a small centre disc.
 *
 * Cycles through the same lifecycle as the app:
 *
 *   idle (0.66 scale) → start (pop, ~600 ms) → recording (orange
 *   centre + warm halo, ~3.6 s) → stopping → finished (centre flashes
 *   cream, pop, ~1 s) → idle
 *
 * Asymmetric petal shapes (cardinal vs diagonal differ) mean we can't
 * per-petal scale-Y the way the old teardrop variant did — that
 * worked because all 8 were identical and rotation-invariant. The new
 * geometry breathes via whole-mark scale + centre colour shifts + a
 * recording halo. Subtler, but reads correctly.
 *
 * Loop ~7 s. Respects `prefers-reduced-motion`.
 */

type Phase = "idle" | "start" | "recording" | "stopping" | "finished";

const PHASE_DURATIONS: Record<Phase, number> = {
  idle: 1200,
  start: 600,
  recording: 3600,
  stopping: 600,
  finished: 1000,
};

// SVG geometry from `daisy_logo.svg` — 8 petals (4 cardinal, 4
// diagonal), each path drawn in a 41×41 viewBox centred on (20.5,
// 20.5). Lifted verbatim so the hero matches the rest of the brand
// exactly. Listed cardinal-first then diagonal-first for clarity.
const PETALS = [
  // Top
  "M18 7.38827C18 5.69685 18.6726 4.82008 19.32 4.36792C20.0225 3.87736 20.9775 3.87736 21.68 4.36792C22.3274 4.82008 23 5.69685 23 7.38827C23 9.7848 22.0998 12.5378 21.2918 14.4453C20.9785 15.1849 20.0215 15.1849 19.7082 14.4453C18.9002 12.5378 18 9.7848 18 7.38827Z",
  // Bottom
  "M18 33.6117C18 35.3031 18.6726 36.1799 19.32 36.6321C20.0225 37.1226 20.9775 37.1226 21.68 36.6321C22.3274 36.1799 23 35.3031 23 33.6117C23 31.2152 22.0998 28.4622 21.2918 26.5547C20.9785 25.8151 20.0215 25.8151 19.7082 26.5547C18.9002 28.4622 18 31.2152 18 33.6117Z",
  // Left
  "M7.38827 23C5.69685 23 4.82008 22.3274 4.36792 21.68C3.87736 20.9775 3.87736 20.0225 4.36792 19.32C4.82008 18.6726 5.69685 18 7.38827 18C9.7848 18 12.5378 18.9002 14.4453 19.7082C15.1849 20.0215 15.1849 20.9785 14.4453 21.2918C12.5378 22.0998 9.7848 23 7.38827 23Z",
  // Right
  "M33.6117 23C35.3031 23 36.1799 22.3274 36.6321 21.68C37.1226 20.9775 37.1226 20.0225 36.6321 19.32C36.1799 18.6726 35.3031 18 33.6117 18C31.2152 18 28.4622 18.9002 26.5547 19.7082C25.8151 20.0215 25.8151 20.9785 26.5547 21.2918C28.4622 22.0998 31.2152 23 33.6117 23Z",
  // Bottom-left
  "M12.9965 31.5392C11.8004 32.7352 10.7049 32.8796 9.92733 32.7415C9.08376 32.5917 8.40844 31.9164 8.25862 31.0728C8.12053 30.2952 8.26491 29.1997 9.46092 28.0037C11.1555 26.3091 13.7387 24.9989 15.6588 24.2215C16.4034 23.92 17.0801 24.5967 16.7787 25.3413C16.0012 27.2614 14.6911 29.8446 12.9965 31.5392Z",
  // Top-right
  "M31.5392 12.9963C32.7352 11.8003 32.8796 10.7048 32.7415 9.92721C32.5917 9.08364 31.9164 8.40832 31.0728 8.2585C30.2952 8.12041 29.1997 8.26478 28.0037 9.4608C26.3091 11.1554 24.9989 13.7386 24.2215 15.6587C23.92 16.4033 24.5967 17.08 25.3413 16.7785C27.2614 16.0011 29.8446 14.6909 31.5392 12.9963Z",
  // Bottom-right
  "M31.5392 28.0035C32.7352 29.1996 32.8796 30.2951 32.7415 31.0727C32.5917 31.9162 31.9164 32.5916 31.0728 32.7414C30.2952 32.8795 29.1997 32.7351 28.0037 31.5391C26.3091 29.8445 24.9989 27.2613 24.2215 25.3412C23.92 24.5966 24.5967 23.9199 25.3413 24.2213C27.2614 24.9988 29.8446 26.3089 31.5392 28.0035Z",
  // Top-left
  "M12.9965 9.46081C11.8004 8.2648 10.7049 8.12042 9.92733 8.25851C9.08376 8.40833 8.40844 9.08365 8.25862 9.92722C8.12053 10.7048 8.26491 11.8003 9.46092 12.9963C11.1555 14.6909 13.7387 16.0011 15.6588 16.7785C16.4034 17.08 17.0801 16.4033 16.7787 15.6587C16.0012 13.7386 14.6911 11.1554 12.9965 9.46081Z",
];

function easeInOut(t: number): number {
  return t < 0.5 ? 2 * t * t : 1 - Math.pow(-2 * t + 2, 2) / 2;
}

export function DaisyMark({ size = 280 }: { size?: number }) {
  const [phase, setPhase] = useState<Phase>("idle");
  const [phaseProgress, setPhaseProgress] = useState(0);
  const [recordingClock, setRecordingClock] = useState(0);
  const rafRef = useRef<number | null>(null);
  const phaseStartRef = useRef<number>(performance.now());
  const reducedMotion = useReducedMotion();

  useEffect(() => {
    if (reducedMotion) return;

    const loop = (now: number) => {
      const elapsed = now - phaseStartRef.current;
      const duration = PHASE_DURATIONS[phase];

      if (elapsed >= duration) {
        const order: Phase[] = ["idle", "start", "recording", "stopping", "finished"];
        const next = order[(order.indexOf(phase) + 1) % order.length];
        phaseStartRef.current = now;
        setPhase(next);
        setPhaseProgress(0);
      } else {
        setPhaseProgress(elapsed / duration);
        if (phase === "recording") {
          setRecordingClock(elapsed);
        }
      }

      rafRef.current = requestAnimationFrame(loop);
    };

    rafRef.current = requestAnimationFrame(loop);
    return () => {
      if (rafRef.current) cancelAnimationFrame(rafRef.current);
    };
  }, [phase, reducedMotion]);

  // ── Visual parameters per phase ──────────────────────────────────

  const passiveScale =
    phase === "idle"
      ? 0.78
      : phase === "start"
        ? 0.78 + 0.22 * easeInOut(phaseProgress)
        : phase === "finished"
          ? 1 - 0.22 * easeInOut(phaseProgress)
          : 1.0;

  const popScale =
    phase === "start" || phase === "finished"
      ? 1 + 0.06 * Math.sin(phaseProgress * Math.PI)
      : 1;

  // Subtle in-phase breathing while recording so the mark feels alive
  // without per-petal animation. ±2% over a 2.4-second cycle.
  const recordingBreath =
    phase === "recording" ? 1 + 0.02 * Math.sin(recordingClock / 380) : 1;

  const centerColor =
    phase === "recording"
      ? "var(--color-recording)"
      : phase === "finished"
        ? "var(--color-accent-soft)"
        : phase === "idle"
          ? "var(--color-petal-center)"
          : "var(--color-accent-soft)";

  // ── Render ───────────────────────────────────────────────────────

  return (
    <div
      aria-hidden
      className="select-none"
      style={{
        width: size,
        height: size,
        transform: `scale(${(passiveScale * popScale * recordingBreath).toFixed(4)})`,
        transition: "transform 80ms linear",
      }}
    >
      <svg
        viewBox="0 0 41 41"
        width={size}
        height={size}
        xmlns="http://www.w3.org/2000/svg"
        // White petals on a cream background need a stronger
        // drop-shadow than the cinnamon version did, otherwise the
        // mark dissolves into the page. The shadow uses cinnamon
        // tones (not generic black) so the soft halo still reads
        // as warm brand colour, just behind the petals.
        style={{
          filter:
            phase === "recording"
              ? "drop-shadow(0 6px 28px rgba(255, 149, 0, 0.35)) drop-shadow(0 1px 3px rgba(166, 110, 42, 0.25))"
              : "drop-shadow(0 4px 20px rgba(166, 110, 42, 0.22)) drop-shadow(0 1px 2px rgba(166, 110, 42, 0.20))",
          transition: "filter 280ms ease-out",
        }}
      >
        {/* Petals — ink, matching BrandLogo + the in-app DaisyMark.
            Keeping a single petal treatment across nav, footer,
            hero animation, and the macOS app removes the "different
            product on the website than in the DMG" drift. */}
        {PETALS.map((d, i) => (
          <path
            key={i}
            d={d}
            fill="var(--color-ink)"
            style={{
              transition: "opacity 280ms ease-out",
            }}
          />
        ))}

        {/* Centre disc */}
        <circle
          cx="20.5"
          cy="20.5"
          r="4.5"
          fill={centerColor}
          style={{ transition: "fill 220ms ease-out" }}
        />

        {/* Recording halo — soft pulsing ring around the centre. No
            dark backplate needed; the halo reads on cream as warmth */}
        {phase === "recording" && (
          <circle
            cx="20.5"
            cy="20.5"
            r={4.5 + 1.6 * (0.5 + 0.5 * Math.sin(recordingClock / 200))}
            fill="none"
            stroke="var(--color-recording-pulse)"
            strokeOpacity={0.45}
            strokeWidth={0.9}
          />
        )}
      </svg>
    </div>
  );
}

function useReducedMotion() {
  const [reduced, setReduced] = useState(false);
  useEffect(() => {
    const mql = window.matchMedia("(prefers-reduced-motion: reduce)");
    setReduced(mql.matches);
    const onChange = (e: MediaQueryListEvent) => setReduced(e.matches);
    mql.addEventListener("change", onChange);
    return () => mql.removeEventListener("change", onChange);
  }, []);
  return reduced;
}
