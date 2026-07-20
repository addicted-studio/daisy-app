import type { Metadata, Viewport } from "next";
import "./globals.css";
import { Analytics } from "@vercel/analytics/react";
import { LATEST_VERSION } from "@/lib/latestVersion";

// Pre-launch audit (2026-05-23, business/research/2026-05-23-mydaisy-io-audit-pre-ph)
// rewrote the head copy with category words first, since the old
// title ("local meeting capture for Mac") didn't pick up the two
// highest-intent queries — "granola alternative" + "open-source
// meeting recorder mac". New title is ~70 chars (under Google's
// ~600px SERP cap), new description ~150 chars (the truncation
// edge for desktop). Lead with the differentiators — open-source +
// local + on-device + dictation. No competitor brand in the homepage
// meta (the /alternatives/granola SEO page owns that query instead).
const PAGE_TITLE =
  "Daisy — Private meeting notes and dictation for Mac";
const PAGE_DESCRIPTION =
  "Record both sides of any call without a bot. Daisy transcribes on-device and turns conversations into searchable notes, summaries and next steps on your Mac.";

export const metadata: Metadata = {
  metadataBase: new URL("https://mydaisy.io"),
  title: {
    default: PAGE_TITLE,
    template: "%s · Daisy",
  },
  description: PAGE_DESCRIPTION,
  applicationName: "Daisy",
  authors: [{ name: "Addicted Studio", url: "https://addicted.sh" }],
  creator: "Addicted Studio",
  publisher: "Addicted Studio",
  keywords: [
    "granola alternative",
    "open source meeting recorder",
    "local meeting recorder mac",
    "mac meeting transcription",
    "meeting recorder no bot",
    "meeting notes mcp server",
    "claude desktop meeting transcripts",
    "private meeting recorder",
    "obsidian meeting notes",
    "whisper meeting transcription mac",
  ],
  openGraph: {
    type: "website",
    locale: "en_US",
    url: "https://mydaisy.io",
    siteName: "Daisy",
    title: PAGE_TITLE,
    description: PAGE_DESCRIPTION,
    images: [
      {
        url: "/og-v2.png",
        width: 1200,
        height: 630,
        alt: "Daisy — Private meeting notes, made on your Mac",
      },
    ],
  },
  twitter: {
    card: "summary_large_image",
    title: PAGE_TITLE,
    description: PAGE_DESCRIPTION,
    images: ["/og-v2.png"],
  },
  robots: {
    index: true,
    follow: true,
  },
  alternates: {
    canonical: "https://mydaisy.io",
  },
  icons: {
    icon: "/favicon.svg",
    apple: "/apple-touch-icon.png",
  },
};

// Dark-only site — paint the mobile browser chrome + UA controls dark so
// they match the page instead of flashing a light bar on scroll.
export const viewport: Viewport = {
  themeColor: "#111210",
  colorScheme: "dark",
};

// Schema.org SoftwareApplication payload — gives Google Rich Results
// + AI crawlers a structured handle on Daisy: name, OS, category,
// price (free during beta), and provider. The JSON object is small
// enough to inline directly into the head without bundling.
const SOFTWARE_APP_LD = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: "Daisy",
  operatingSystem: "macOS 14+",
  applicationCategory: "BusinessApplication",
  applicationSubCategory: "Meeting recording, transcription, and summarisation",
  description:
    "Local-first meeting recorder for macOS. Captures microphone + system audio, transcribes on-device with Whisper, summarises with the AI provider you choose, and exposes the result as a local MCP server for Claude Desktop and Cursor.",
  url: "https://mydaisy.io",
  downloadUrl: "https://github.com/addicted-studio/daisy-app/releases",
  softwareVersion: LATEST_VERSION,
  offers: {
    "@type": "Offer",
    price: "0",
    priceCurrency: "USD",
    availability: "https://schema.org/InStock",
  },
  author: {
    "@type": "Organization",
    name: "Addicted Studio",
    url: "https://addicted.sh",
  },
  publisher: {
    "@type": "Organization",
    name: "Addicted Studio",
    url: "https://addicted.sh",
  },
  featureList: [
    "On-device Whisper transcription",
    "System audio capture via ScreenCaptureKit",
    "On-device speaker diarization (Pyannote, CoreML)",
    "Bring-your-own AI summaries (Anthropic, OpenAI, Apple Intelligence, local MCP)",
    "Local MCP server for Claude Desktop and Cursor",
    "Notion / Linear / Attio / webhook destinations",
    "No telemetry, no account, no cloud",
  ],
};

// Separate Organization schema for Addicted Studio — gives the
// publisher its own knowledge-graph node so Google can connect
// Daisy → Addicted → other products / social profiles instead of
// only knowing Addicted Studio through the SoftwareApplication
// `author` nested field. Recommended by the 2026-05-23 pre-PH
// audit. Keep this in sync with the Addicted Studio site if/when
// it ships at addicted.sh.
const ORGANIZATION_LD = {
  "@context": "https://schema.org",
  "@type": "Organization",
  name: "Addicted Studio",
  url: "https://addicted.sh",
  logo: "https://mydaisy.io/apple-touch-icon.png",
  sameAs: [
    "https://github.com/addicted-studio",
  ],
  founder: {
    "@type": "Person",
    name: "Egor Sazanov",
  },
  description:
    "Independent product studio focused on local-first, privacy-respecting Mac and iOS software. Maker of Daisy, Anonymous, and other tools.",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body className="antialiased" suppressHydrationWarning>
        {children}
        <script
          type="application/ld+json"
          // JSON-LD must be a single script block in the body or
          // head; Next inlines it as-is via dangerouslySetInnerHTML.
          // The payload is static so no injection surface.
          dangerouslySetInnerHTML={{ __html: JSON.stringify(SOFTWARE_APP_LD) }}
        />
        <script
          type="application/ld+json"
          dangerouslySetInnerHTML={{ __html: JSON.stringify(ORGANIZATION_LD) }}
        />
        {/* Vercel Analytics — page views, top pages, referrers,
            geographic breakdown. No cookies, no PII, IP anonymised
            to /24 subnet. Included free in our Vercel Pro plan,
            generous quota (250k events/month). Enable in Vercel
            dashboard: Settings → Analytics → Enable. */}
        <Analytics />
      </body>
    </html>
  );
}
