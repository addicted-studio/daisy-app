import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Privacy",
  description:
    "What Daisy collects, what mydaisy.io collects, who we share it with. Short version: almost nothing.",
};

const LAST_UPDATED = "July 18, 2026";

export default function PrivacyPage() {
  return (
    <main className="relative z-0 mx-auto max-w-3xl px-6 py-24 md:py-32">
      <Link
        href="/"
        className="mb-12 inline-block text-sm text-[color:var(--color-ink-tertiary)] underline decoration-[color:var(--color-divider)] underline-offset-4 transition-colors hover:text-[color:var(--color-ink)]"
      >
        ← Daisy
      </Link>

      <p className="mb-3 text-sm font-medium uppercase tracking-widest text-[color:var(--color-ink-tertiary)]">
        Privacy policy
      </p>
      <h1 className="mb-6 font-display text-4xl font-semibold leading-tight tracking-tight md:text-5xl">
        Almost nothing leaves your Mac.
      </h1>
      <p className="mb-16 text-lg leading-relaxed text-[color:var(--color-ink-secondary)]">
        This page covers two things: what the Daisy desktop app does
        with your data, and what this website does with your visit.
        Both answers are deliberately short.
      </p>

      <section className="mb-16 space-y-6">
        <h2 className="font-display text-2xl font-semibold tracking-tight">
          The Daisy app
        </h2>

        <h3 className="font-display text-base font-semibold">
          What gets stored, and where
        </h3>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Recordings, transcripts and summaries are written
          to a folder inside your user Library, on your Mac. Daisy never
          uploads any of it. You can open the folder from the app menu,
          back it up, or delete it.
        </p>

        <h3 className="font-display text-base font-semibold">
          What runs on-device
        </h3>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Audio capture, transcription (Whisper, via Apple&rsquo;s
          Neural Engine), and the default summarizer (Apple Intelligence)
          all run locally. No network call is involved in producing a
          transcript or a default summary.
        </p>

        <h3 className="font-display text-base font-semibold">
          What happens if you bring your own LLM key
        </h3>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          You can optionally point the summarizer at Anthropic or OpenAI
          using your own API key. When that&rsquo;s on, the transcript
          for that one summary request goes from your Mac directly to
          the provider you chose. Daisy is not in the middle. We never
          see your transcripts and we never see your key — the key is
          stored in your Mac&rsquo;s Keychain, not on our servers.
        </p>

        <h3 className="font-display text-base font-semibold">
          What happens if you connect Notion
        </h3>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          If you paste a Notion integration token, Daisy sends finished
          notes from your Mac directly to your Notion workspace. Same
          shape: your machine to their API, nothing through us.
        </p>

        <h3 className="font-display text-base font-semibold">
          What happens if you connect a calendar
        </h3>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Daisy can link recordings to meetings on your calendar — useful
          for naming a recording after the event, prefilling attendees, and
          optionally starting / stopping the recording when the event
          starts / ends. Two independent paths, both opt-in: Apple
          Calendar through Apple&rsquo;s EventKit (no third-party
          involved), and Google Calendar through Google&rsquo;s OAuth
          API. The Google integration is also documented in detail in the
          dedicated section below so the disclosures Google&rsquo;s API
          policy requires are in one place.
        </p>

        <h3 className="font-display text-base font-semibold">
          What gets downloaded on first run
        </h3>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          The first time you pick a transcription or dictation model,
          Daisy downloads it from its publisher&rsquo;s CDN (Hugging Face
          for Whisper; the FluidAudio model host for the optional Faster
          dictation engine). That&rsquo;s a one-time HTTPS download of the
          model weights, not telemetry — no identifier about you is sent
          beyond the standard request that any HTTPS client makes. The
          CDN sees your IP and a User-Agent string, like any download.
        </p>

        <h3 className="font-display text-base font-semibold">
          What checks for updates
        </h3>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Once a day, Daisy fetches{" "}
          <code className="rounded bg-[color:var(--color-bg-elevated)] px-1 py-0.5 text-sm">
            mydaisy.io/appcast.xml
          </code>{" "}
          to see if a newer version is available. The request carries
          your current version number and a generic User-Agent — no
          account, no device ID, no usage data, no telemetry of any
          kind. You can disable automatic checks in{" "}
          <em>About → Updates</em>; the &ldquo;Check for Updates&hellip;&rdquo;
          menu item still works manually after that. Update downloads
          are signed with our EdDSA key and Daisy refuses to install
          anything whose signature doesn&rsquo;t verify, so an attacker
          who hijacks the feed can&rsquo;t push code at you.
        </p>

        <h3 className="font-display text-base font-semibold">
          No accounts, no telemetry
        </h3>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          There is no Daisy account, no sign-in, no usage analytics, no
          crash reporter calling home, no feature flagging service. The
          only background network call Daisy makes is the daily update
          check above, against our own domain — nothing else runs in a
          loop, nothing leaves your Mac unless you explicitly connect a
          provider (Anthropic, OpenAI, Notion, &hellip;) yourself.
        </p>
      </section>

      <section className="mb-16 space-y-6">
        <h2 className="font-display text-2xl font-semibold tracking-tight">
          This website (mydaisy.io)
        </h2>

        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          The landing page is a static Next.js site hosted on Vercel.
          It uses Vercel Web Analytics to count page views, referrers,
          countries and device categories so we can understand which pages
          are useful. It does not set analytics cookies, create a Daisy
          account profile or collect meeting content. Vercel also keeps
          short-lived request logs (IP, user agent, URL) for hosting,
          security and abuse protection.
        </p>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          If you email{" "}
          <Link
            href="mailto:essazanov@pm.me"
            className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            essazanov@pm.me
          </Link>
          , that message lands in a regular inbox and is treated like
          any other email — kept only as long as needed to reply.
        </p>
      </section>

      <section className="mb-16 space-y-6">
        <h2 className="font-display text-2xl font-semibold tracking-tight">
          Subprocessors
        </h2>
        <ul className="space-y-3 text-[color:var(--color-ink-secondary)] leading-relaxed">
          <li>
            <strong className="text-[color:var(--color-ink)]">Vercel</strong>
            {" "}— site hosting and privacy-preserving aggregate web analytics
            for mydaisy.io. This never includes content from the Daisy app.
          </li>
          <li>
            <strong className="text-[color:var(--color-ink)]">Hugging Face</strong>
            {" "}— hosts the Whisper model files the app downloads on first
            use. No account or identifier is sent.
          </li>
          <li>
            <strong className="text-[color:var(--color-ink)]">Anthropic and OpenAI</strong>
            {" "}— only if you opt in by adding your own API key. The traffic
            is between your Mac and them; we are not in the path.
          </li>
          <li>
            <strong className="text-[color:var(--color-ink)]">Notion</strong>
            {" "}— only if you opt in by adding an integration token, same
            shape.
          </li>
        </ul>
      </section>

      <section className="mb-16 space-y-6">
        <h2 className="font-display text-2xl font-semibold tracking-tight">
          Google Calendar integration (optional)
        </h2>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          This section exists to satisfy Google&rsquo;s{" "}
          <Link
            href="https://developers.google.com/terms/api-services-user-data-policy"
            target="_blank"
            rel="noreferrer"
            className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            API Services User Data Policy
          </Link>
          {" "}disclosure requirements. Daisy&rsquo;s use of information
          received from Google APIs adheres to the Google API Services
          User Data Policy, including the Limited Use requirements.
          Connecting Google Calendar is entirely optional — Daisy works
          fully without it, and Apple Calendar via EventKit covers the
          same use cases without involving Google.
        </p>

        <h3 className="font-display text-base font-semibold">
          Data accessed
        </h3>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          When you connect Google Calendar, Daisy requests a single
          OAuth scope:{" "}
          <code className="rounded bg-[color:var(--color-bg-elevated)] px-1 py-0.5 text-sm">
            https://www.googleapis.com/auth/calendar.readonly
          </code>
          . This is read-only — Daisy can <em>only</em> see events,
          never create, modify or delete them. From the events Daisy
          reads, the following fields are used: event title, start and
          end time, location, description, organiser, and the email
          addresses of attendees the calendar API returns to you. No
          other Google services or APIs are accessed.
        </p>

        <h3 className="font-display text-base font-semibold">
          Data usage
        </h3>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Calendar event data is used <strong>only</strong> on your Mac,
          and only to power user-visible meeting features:
        </p>
        <ul className="ml-6 list-disc space-y-2 text-[color:var(--color-ink-secondary)] leading-relaxed marker:text-[color:var(--color-ink-tertiary)]">
          <li>
            <strong className="text-[color:var(--color-ink)]">Naming</strong>
            {" "}— the upcoming meeting&rsquo;s title is used as the
            recording title in your transcript.
          </li>
          <li>
            <strong className="text-[color:var(--color-ink)]">Auto-start / auto-stop</strong>
            {" "}— if you enable these in Settings, Daisy starts and
            stops recording at the event&rsquo;s start and end times.
          </li>
          <li>
            <strong className="text-[color:var(--color-ink)]">Attendee prefill</strong>
            {" "}— attendee email addresses are written into the local
            transcript file as recording metadata, and the dominant
            external email domain is used to auto-suggest a free-form
            &ldquo;tag&rdquo; for filtering recordings in your local
            library (e.g.{" "}
            <code className="rounded bg-[color:var(--color-bg-elevated)] px-1 py-0.5 text-sm">
              acme.com
            </code>
            {" "}attendees → suggested tag &ldquo;Acme&rdquo;).
          </li>
          <li>
            <strong className="text-[color:var(--color-ink)]">Menu-bar &ldquo;next meeting&rdquo;</strong>
            {" "}— optional, off by default; shows the next event&rsquo;s
            title in the macOS menu bar.
          </li>
        </ul>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Calendar data is <strong>never</strong> used to train any AI
          or ML models — generalised or otherwise. Daisy does not run
          analytics, profiling, advertising, or any kind of automated
          decision-making on Google user data.
        </p>

        <h3 className="font-display text-base font-semibold">
          Data sharing
        </h3>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Daisy does <strong>not share</strong> Google user data with
          any third party. The OAuth flow runs entirely between your
          Mac and Google&rsquo;s servers; Daisy doesn&rsquo;t operate
          any backend that touches calendar data. We are not in the
          path. Calendar data does not leave your Mac except for the
          original request to Google&rsquo;s own API that fetched it.
        </p>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          If you later use a bring-your-own-key AI summariser (Anthropic
          or OpenAI), only the transcript you ask to be summarised is
          sent — and that&rsquo;s the transcript text you produced, not
          raw calendar fields. Even there, no calendar metadata is
          forwarded to those providers as a standalone payload.
        </p>

        <h3 className="font-display text-base font-semibold">
          Data storage and protection
        </h3>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          OAuth refresh and access tokens are stored in the macOS
          Keychain on your Mac — system-grade encryption at rest,
          hardware-backed on Apple Silicon, isolated to your user
          account. No tokens are stored on any server. Calendar event
          data is fetched on demand when the app needs it (when arming
          auto-start, when starting a recording, when refreshing the Home
          view); the only persisted copy of any event field ends up in
          the local transcript file&rsquo;s YAML frontmatter inside the
          sessions folder you picked — which means it&rsquo;s protected
          by your macOS user-account isolation and any FileVault
          encryption you have enabled, the same as the rest of your
          local files.
        </p>

        <h3 className="font-display text-base font-semibold">
          Data retention and deletion
        </h3>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Refresh tokens are kept in the Keychain until you disconnect
          the integration. To disconnect at any time: open Daisy →
          Connections → Calendar → Google → <em>Disconnect</em>. That
          revokes the token with Google&rsquo;s OAuth endpoint and
          removes the Keychain entry — no leftover credentials remain.
          You can additionally revoke Daisy&rsquo;s access from{" "}
          <Link
            href="https://myaccount.google.com/permissions"
            target="_blank"
            rel="noreferrer"
            className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            myaccount.google.com/permissions
          </Link>
          .
        </p>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Calendar event fields that ended up inside transcripts (titles,
          attendees, times) live as long as you keep the transcript
          file. To delete them, delete the recording in Daisy&rsquo;s
          Library tab, or remove the file from your sessions folder in
          Finder. Because Daisy stores nothing on our servers, there is
          no separate &ldquo;contact us to delete your data&rdquo;
          process for calendar data — you delete the files and the data
          is gone.
        </p>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Questions or deletion requests:{" "}
          <Link
            href="mailto:essazanov@pm.me"
            className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
          >
            essazanov@pm.me
          </Link>
          .
        </p>
      </section>

      <section className="mb-16 space-y-6">
        <h2 className="font-display text-2xl font-semibold tracking-tight">
          Your rights
        </h2>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          Because Daisy stores your recordings and transcripts on your
          own Mac and not on our servers, deleting them is a matter of
          deleting the folder from inside the app or in Finder. For the
          minimal personal data we do hold (your email if you wrote to
          us), reply to your own thread and ask us to delete it — we
          will.
        </p>
      </section>

      <section className="mb-16 space-y-6">
        <h2 className="font-display text-2xl font-semibold tracking-tight">
          Changes
        </h2>
        <p className="text-[color:var(--color-ink-secondary)] leading-relaxed">
          If this policy changes in a way that affects what we collect,
          we&rsquo;ll bump the &ldquo;Last updated&rdquo; date below and,
          for anything material, note it on the landing page.
        </p>
      </section>

      <p className="border-t border-[color:var(--color-divider)] pt-8 text-sm text-[color:var(--color-ink-tertiary)]">
        Last updated: {LAST_UPDATED}. Questions:{" "}
        <Link
          href="mailto:essazanov@pm.me"
          className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
        >
          essazanov@pm.me
        </Link>
        .
      </p>
    </main>
  );
}
