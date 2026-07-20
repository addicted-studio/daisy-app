// Single source of truth for the stable / new download fork.
//
// The raw version numbers live in two release.sh-generated files —
// lib/latestVersion.ts (stable) and lib/betaVersion.ts (beta). This
// module derives "is there a newer beta?" and the channel list ONCE,
// so every download surface (the Hero CTA and the closing Download
// section) renders the SAME fork from the SAME data. Before this, the
// channel labels/notes were inlined in Download.tsx alone — a second
// surface (the hero split button) would have drifted out of sync.

import { LATEST_DMG_URL, LATEST_VERSION, LATEST_BUILD } from "./latestVersion";
import { BETA_VERSION, BETA_BUILD, BETA_DMG_URL } from "./betaVersion";
import type { DownloadChannel } from "../components/DownloadPicker";

/** True while a beta build newer than the stable channel exists —
 *  release.sh writes lib/betaVersion.ts on beta ships and `promote`
 *  moves stable forward, which flips this back to false. Drives the
 *  stable / new split button on every surface: with no newer beta the
 *  CTAs fall back to the classic single Download button. */
export const HAS_NEWER_BETA = Boolean(BETA_DMG_URL) && BETA_BUILD > LATEST_BUILD;

/** Channels shown in the split-button listbox. Stable is always first
 *  (the default selection, so a visitor who never opens the menu gets
 *  the soaked build); beta is appended only when a newer one exists. */
export const DOWNLOAD_CHANNELS: DownloadChannel[] = [
  {
    id: "stable",
    label: "Stable",
    version: LATEST_VERSION,
    note: "The soaked build most people should run.",
    dmgUrl: LATEST_DMG_URL,
  },
  ...(HAS_NEWER_BETA
    ? [
        {
          id: "beta" as const,
          label: "New",
          version: BETA_VERSION!,
          note: "Newest features first — updates via the in-app beta channel (About → Get beta updates).",
          dmgUrl: BETA_DMG_URL!,
        },
      ]
    : []),
];
