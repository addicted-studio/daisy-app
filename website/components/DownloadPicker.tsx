"use client";

import { useEffect, useRef, useState } from "react";
import { track } from "@vercel/analytics";

// Split "select" download button — rendered while a beta newer than
// stable exists (the stable/new fork). Left segment downloads the
// currently-selected channel's DMG; the chevron opens a small listbox
// to switch channels. Default = stable, so a visitor who never opens
// the menu gets exactly the old behaviour.
//
// Used on two surfaces, parametrized so each keeps its own rhythm:
//   - the closing Download section — size="lg", centered (defaults);
//   - the Hero CTA — size="md", left-aligned, full-width on mobile so
//     it sits flush beside "View on GitHub".
// The defaults reproduce the original Download-section button exactly,
// so that surface is untouched by the parametrization.
//
// Client island on purpose (same rationale as TrackedLink): the
// landing page stays a server component, only this leaf ships JS.

export interface DownloadChannel {
  /** Analytics channel id — also the listbox row key. */
  id: "stable" | "beta";
  /** Row title in the menu ("Stable" / "New"). */
  label: string;
  /** Marketing version shown next to the label (e.g. "1.0.7.18"). */
  version: string;
  /** One-line caption under the row title. */
  note: string;
  /** DMG href (already cache-busted by release.sh). */
  dmgUrl: string;
}

function AppleMark() {
  return (
    <svg
      viewBox="0 0 384 512"
      width="18"
      height="18"
      fill="currentColor"
      aria-hidden="true"
      className="-mt-0.5"
    >
      <path d="M318.7 268.7c-.2-36.7 16.4-64.4 50-84.8-18.8-26.9-47.2-41.7-84.7-44.6-35.5-2.8-74.3 20.7-88.5 20.7-15 0-49.4-19.7-76.4-19.7C63.3 141.2 4 184.8 4 273.5q0 39.3 14.4 81.2c12.8 36.7 59 126.7 107.2 125.2 25.2-.6 43-17.9 75.8-17.9 31.8 0 48.3 17.9 76.4 17.9 48.6-.7 90.4-82.5 102.6-119.3-65.2-30.7-61.7-90-61.7-91.9zm-56.6-164.2c27.3-32.4 24.8-61.9 24-72.5-24.1 1.4-52 16.4-67.9 34.9-17.5 19.8-27.8 44.3-25.6 71.9 26.1 2 49.9-11.4 69.5-34.3z" />
    </svg>
  );
}

export function DownloadPicker({
  channels,
  /** Analytics `source` tag for the download + channel-select events. */
  source = "download_section",
  /** Button scale: "lg" matches the closing section, "md" the hero row. */
  size = "lg",
  /** Dropdown anchor: "center" under the button, or "start" (left-flush). */
  align = "center",
  /** Stretch to full width on mobile (hero), auto width from sm up. */
  block = false,
}: {
  channels: DownloadChannel[];
  source?: string;
  size?: "md" | "lg";
  align?: "center" | "start";
  block?: boolean;
}) {
  const [selectedId, setSelectedId] = useState<DownloadChannel["id"]>(
    channels[0]?.id ?? "stable",
  );
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const optionRefs = useRef<Array<HTMLButtonElement | null>>([]);

  const selected = channels.find((c) => c.id === selectedId) ?? channels[0];

  // Close the menu on outside click. Keyboard closing and focus return
  // live on the listbox below so focus never gets lost in the document.
  useEffect(() => {
    if (!open) return;
    const onPointerDown = (e: PointerEvent) => {
      if (!rootRef.current?.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("pointerdown", onPointerDown);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
    };
  }, [open]);

  const openMenu = (preferredIndex?: number) => {
    setOpen(true);
    window.requestAnimationFrame(() => {
      const selectedIndex = channels.findIndex((channel) => channel.id === selectedId);
      const index = preferredIndex ?? Math.max(0, selectedIndex);
      optionRefs.current[index]?.focus();
    });
  };

  if (!selected) return null;

  // Per-surface class fragments. Defaults (lg / center / inline) keep
  // the closing Download section pixel-identical to before.
  const mainPad = size === "lg" ? "py-4 pl-7 pr-5" : "py-3.5 pl-6 pr-4";
  const chevronPad = size === "lg" ? "px-3.5" : "px-3";
  const rootLayout = block
    ? "relative flex w-full flex-col sm:inline-flex sm:w-auto"
    : "relative inline-flex flex-col";
  const rootAlign = align === "start" ? "items-start" : "items-center";
  const rowLayout = block
    ? "flex w-full items-stretch sm:w-auto"
    : "inline-flex items-stretch";
  const mainGrow = block ? "flex-1 justify-center sm:flex-none sm:justify-start" : "";
  const menuAlign = align === "start" ? "left-0" : "";

  return (
    <div ref={rootRef} className={`${rootLayout} ${rootAlign}`}>
      <div className={rowLayout}>
        {/* Main segment — downloads the selected channel. */}
        <a
          href={selected.dmgUrl}
          onClick={() => track("download_dmg", { source, channel: selected.id })}
          className={`inline-flex items-center gap-3 rounded-l-xl bg-[color:var(--color-ink)] ${mainPad} text-base font-medium text-[color:var(--color-bg)] transition-opacity hover:opacity-90 ${mainGrow}`}
        >
          <AppleMark />
          <span>
            Download {selected.label.toLowerCase()}
            <span className="ml-2 opacity-60">{selected.version}</span>
          </span>
        </a>
        {/* Chevron segment — opens the channel listbox. */}
        <button
          ref={triggerRef}
          type="button"
          aria-haspopup="listbox"
          aria-expanded={open}
          aria-label="Choose version to download"
          onClick={() => (open ? setOpen(false) : openMenu())}
          onKeyDown={(event) => {
            if (event.key === "ArrowDown") {
              event.preventDefault();
              openMenu(0);
            } else if (event.key === "ArrowUp") {
              event.preventDefault();
              openMenu(channels.length - 1);
            }
          }}
          className={`inline-flex items-center rounded-r-xl border-l border-[color:var(--color-bg)]/25 bg-[color:var(--color-ink)] ${chevronPad} text-[color:var(--color-bg)] transition-opacity hover:opacity-90`}
        >
          <svg
            viewBox="0 0 16 16"
            width="14"
            height="14"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.8"
            strokeLinecap="round"
            strokeLinejoin="round"
            aria-hidden="true"
            className={open ? "rotate-180 transition-transform" : "transition-transform"}
          >
            <path d="M3.5 6l4.5 4.5L12.5 6" />
          </svg>
        </button>
      </div>

      {open && (
        <div
          role="listbox"
          aria-label="Daisy versions"
          onKeyDown={(event) => {
            const currentIndex = optionRefs.current.findIndex(
              (option) => option === document.activeElement,
            );
            if (event.key === "Escape") {
              event.preventDefault();
              setOpen(false);
              triggerRef.current?.focus();
            } else if (event.key === "ArrowDown") {
              event.preventDefault();
              optionRefs.current[(currentIndex + 1) % channels.length]?.focus();
            } else if (event.key === "ArrowUp") {
              event.preventDefault();
              optionRefs.current[(currentIndex - 1 + channels.length) % channels.length]?.focus();
            } else if (event.key === "Home") {
              event.preventDefault();
              optionRefs.current[0]?.focus();
            } else if (event.key === "End") {
              event.preventDefault();
              optionRefs.current[channels.length - 1]?.focus();
            }
          }}
          className={`absolute top-full z-20 mt-2 w-80 overflow-hidden rounded-xl border border-[color:var(--color-divider)] bg-[color:var(--color-bg)] text-left shadow-xl ${menuAlign}`}
        >
          {channels.map((channel, index) => {
            const isSelected = channel.id === selectedId;
            return (
              <button
                ref={(element) => {
                  optionRefs.current[index] = element;
                }}
                key={channel.id}
                type="button"
                role="option"
                aria-selected={isSelected}
                onClick={() => {
                  setSelectedId(channel.id);
                  setOpen(false);
                  track("download_channel_select", { source, channel: channel.id });
                }}
                className="flex w-full items-start gap-3 px-4 py-3 transition-colors hover:bg-[color:var(--color-bg-sidebar)]"
              >
                {/* Check column keeps rows aligned whether selected or not. */}
                <span className="mt-0.5 w-4 shrink-0 text-[color:var(--color-ink)]">
                  {isSelected ? (
                    <svg
                      viewBox="0 0 16 16"
                      width="14"
                      height="14"
                      fill="none"
                      stroke="currentColor"
                      strokeWidth="2"
                      strokeLinecap="round"
                      strokeLinejoin="round"
                      aria-hidden="true"
                    >
                      <path d="M2.5 8.5l3.5 3.5 7.5-8" />
                    </svg>
                  ) : null}
                </span>
                <span>
                  <span className="block text-sm font-medium text-[color:var(--color-ink)]">
                    {channel.label}
                    <span className="ml-2 font-normal text-[color:var(--color-ink-tertiary)]">
                      {channel.version}
                    </span>
                  </span>
                  <span className="mt-0.5 block text-xs leading-relaxed text-[color:var(--color-ink-secondary)]">
                    {channel.note}
                  </span>
                </span>
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}
