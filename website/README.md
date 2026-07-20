# daisy-web

Landing for [Daisy](https://mydaisy.io) — local meeting capture for Mac.

Stack: Next.js 15 (App Router) · Tailwind v4 · TypeScript · Motion One. Deployed on Vercel.

## Run locally

```bash
npm install
npm run dev
```

→ http://localhost:3000

## Structure

```
app/
  layout.tsx         # metadata + global wrapping
  page.tsx           # one-page landing composition
  globals.css        # Tailwind v4 + @theme tokens (mirror DaisyColors.swift)
  favicon.svg
components/
  Hero.tsx           # nav + headline + animated mark
  DaisyMark.tsx      # 8-petal SVG widget, loops through app lifecycle
  Features.tsx       # 3 capability cards
  PrivacyPromise.tsx # 4-point "the deal" section
  Download.tsx       # primary CTA placeholder
  FAQ.tsx            # 6 collapsibles
  Footer.tsx         # addicted.sh attribution
public/
  Daisy.dmg          # ← drop here when ready to ship the binary
next.config.mjs      # security headers
vercel.json          # security headers (duplicate, for static Vercel routes)
```

## Brand tokens

All colors flow through CSS custom properties defined in `globals.css`
`@theme`. They mirror the Swift `DaisyColors.swift` palette one-to-one
so the app and the landing read as the same product.

The recording orange (`#FF9500` light / `#FF9F0A` dark) matches Apple's
HIG `systemOrange` — the same hue macOS and iOS show in the Control
Center microphone-in-use dot. On the landing it's used sparingly:
hero status dot, footer dot, the animated centre of the petal mark
during the "recording" phase of the loop. Everywhere else stays in
warm ink / cream / sage to leave the orange uncontested.

## Deploy

1. `npm install` once
2. Push to GitHub
3. Import in Vercel → it auto-detects Next.js
4. Add `mydaisy.io` custom domain in Vercel → Domains
5. CNAME `mydaisy.io` (or A record `76.76.21.21`) per Vercel instructions
6. Drop the signed `.dmg` into `public/Daisy.dmg` before launch

## Pending before public launch

- [ ] `public/Daisy.dmg` — replace placeholder with real signed build
- [x] `public/og.png` (1200×630) for OpenGraph + Twitter share preview
- [x] `app/privacy/page.tsx` — full privacy policy
- [ ] 5-10s product demo loop (`/demo.mp4` or animated GIF, optional)

Daisy ships with zero tracking — no analytics, no cookies, no
session replay. The landing has nothing to instrument against,
and that's deliberate (matches the app's privacy positioning).
If we ever add a privacy-respecting metric, it'll be a server-side
hit counter, not a third-party script.
