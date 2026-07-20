"use client";

import Link from "next/link";
import { track } from "@vercel/analytics";
import type { ComponentProps, MouseEvent } from "react";

// Thin wrapper around next/link that fires a custom Vercel Analytics
// event on click before navigation. Use for outbound CTAs we care
// about converting (Download DMG, View on GitHub, etc) so the
// Analytics → Custom Events tab can show which landing surface
// actually drives action.
//
// Why a wrapper component rather than inline onClick in each call site:
//   • <Hero>, <Footer>, alternatives pages stay server components —
//     only this tiny leaf is "use client", so the bundle cost is one
//     small island per CTA instead of opting whole landing pages in.
//   • The event name + properties live next to the link in the call
//     site, so adding a new CTA is one prop, not a refactor.
//   • Existing onClick callers still work — we chain through.
//
// Pre-PH (7 June 2026) context: Vercel Analytics OOTB tracks page
// views + referrers, no outbound clicks. After the launch we want
// to know — independent of GitHub Insights and DMG download logs —
// which page on mydaisy.io drove the click, so the source prop is
// required-by-convention even though the API accepts none.

interface TrackedLinkProps extends ComponentProps<typeof Link> {
    /** Event name in Vercel Analytics → Custom Events. Use snake_case. */
    event: string;
    /** Optional structured properties. Source page is the key one;
     *  also useful: cta_position ("hero"/"footer"), cta_variant. */
    eventProperties?: Record<string, string | number | boolean | null>;
}

export function TrackedLink({
    event,
    eventProperties,
    onClick,
    ...linkProps
}: TrackedLinkProps) {
    return (
        <Link
            {...linkProps}
            onClick={(e: MouseEvent<HTMLAnchorElement>) => {
                // Fire the analytics event before user navigation.
                // track() is non-blocking and queues even if the page
                // is about to unload — Vercel's beacon handles that.
                track(event, eventProperties);
                onClick?.(e);
            }}
        />
    );
}
