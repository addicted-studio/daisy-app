import Link from "next/link";
import { BrandLogo } from "./BrandLogo";
import { DownloadPicker } from "./DownloadPicker";
import { TrackedLink } from "./TrackedLink";
import { DOWNLOAD_CHANNELS, HAS_NEWER_BETA } from "../lib/downloadChannels";
import { LATEST_DMG_URL } from "../lib/latestVersion";

const MODES = [
  {
    eyebrow: "01 — Meetings",
    title: "Both sides. No bot.",
    body: "Capture a call without inviting a stranger into it. Daisy listens locally, then gives you the useful part.",
    tone: "meeting",
  },
  {
    eyebrow: "02 — Dictation",
    title: "Thoughts, where you are.",
    body: "Hold a key, speak naturally, and keep writing. Daisy returns your words to the app you were already using.",
    tone: "dictation",
  },
  {
    eyebrow: "03 — Voice notes",
    title: "Keep the spark.",
    body: "A passing thought becomes a titled, searchable note in your own library—before it disappears.",
    tone: "voice",
  },
] as const;

export function Homepage() {
  return (
    <main className="garden-page">
      <Hero />
      <Manifesto />
      <Modes />
      <Privacy />
      <Closing />
      <Footer />
    </main>
  );
}

function Hero() {
  return (
    <section className="garden-hero">
      <div className="garden-grid" aria-hidden />
      <nav className="garden-nav">
        <Link href="/" className="garden-wordmark" aria-label="Daisy home">
          <BrandLogo size={24} /> <span>Daisy</span>
        </Link>
        <div className="garden-nav-links">
          <Link href="#product">Product</Link>
          <Link href="#modes">Modes</Link>
          <Link href="#privacy">Privacy</Link>
          <Link href="/docs">Docs</Link>
        </div>
        <a className="garden-nav-action" href="#download">Download <span aria-hidden>↘</span></a>
      </nav>

      <div className="garden-hero-copy">
        <p className="garden-eyebrow"><span /> Local intelligence for conversations</p>
        <h1>Be present.<br /><em>Keep the rest.</em></h1>
        <p className="garden-intro">
          Daisy turns the conversations you already have into a private, useful archive—right on your Mac.
        </p>
        <div className="garden-actions">
          <DownloadAction source="garden_hero" />
          <a className="garden-text-action" href="#product">See Daisy in action <span aria-hidden>↓</span></a>
        </div>
        <p className="garden-meta">Apple Silicon · macOS 14+ · No account · Open source</p>
      </div>

      <ProductScene />
      <div className="garden-scroll-note" aria-hidden>Scroll to remember <span>↓</span></div>
    </section>
  );
}

function ProductScene() {
  return (
    <div id="product" className="garden-product" aria-label="Preview of Daisy on Mac">
      <div className="garden-product-topline"><span>DAISY / LIBRARY</span><span>JUL 20, 2026</span></div>
      <div className="garden-product-window">
        <aside className="garden-product-sidebar">
          <div className="garden-sidebar-brand"><BrandLogo size={18} /> Daisy</div>
          <span className="is-active">⌂ <b>Today</b></span>
          <span>▤ <b>Library</b></span>
          <span>◌ <b>Voice notes</b></span>
          <small>18 conversations<br />kept locally</small>
        </aside>
        <article className="garden-product-main">
          <div className="garden-product-header">
            <div><p>MONDAY, 11:04 — 42 MIN</p><h2>Q3 product review</h2></div>
            <span className="garden-ready"><i /> Ready</span>
          </div>
          <div className="garden-summary">
            <p className="garden-card-label">The useful part</p>
            <p>Ship a smaller beta, make onboarding effortless, and check in with early users before broadening the scope.</p>
          </div>
          <div className="garden-transcript">
            <p className="garden-card-label">Conversation</p>
            <p><b>You</b> Let&apos;s make the smaller scope feel finished.</p>
            <p><b>Lena</b> I&apos;ll update the launch brief today.</p>
          </div>
          <div className="garden-file">↳ ~/Daisy/Q3-product-review.md</div>
        </article>
      </div>
      <div className="garden-recording"><BrandLogo size={20} /><i /><span>Listening</span><small>12:48</small></div>
      <div className="garden-product-caption">A quiet utility,<br />not another dashboard.</div>
    </div>
  );
}

function Manifesto() {
  return (
    <section className="garden-manifesto">
      <p className="garden-section-label">A different kind of AI tool</p>
      <div>
        <h2>Technology should leave you <em>more room</em> to think.</h2>
        <p>Daisy stays in the corner while you talk, then leaves behind an honest record you can search, keep and use however you want.</p>
      </div>
      <div className="garden-principles">
        <Principle number="01" title="Local by default" body="Your audio and archive stay on your Mac." />
        <Principle number="02" title="Visible when it matters" body="The flower tells you when Daisy is listening." />
        <Principle number="03" title="Open at the edges" body="Plain Markdown works with the tools you choose." />
      </div>
    </section>
  );
}

function Principle({ number, title, body }: { number: string; title: string; body: string }) {
  return <article><span>{number}</span><h3>{title}</h3><p>{body}</p></article>;
}

function Modes() {
  return (
    <section id="modes" className="garden-modes">
      <div className="garden-modes-heading">
        <p className="garden-section-label">One flower, three ways to capture</p>
        <h2>Made for the things that don&apos;t wait.</h2>
      </div>
      <div className="garden-mode-list">
        {MODES.map((mode) => (
          <article className={`garden-mode garden-mode-${mode.tone}`} key={mode.tone}>
            <div className="garden-mode-signal"><BrandLogo size={52} /></div>
            <p>{mode.eyebrow}</p>
            <h3>{mode.title}</h3>
            <span>{mode.body}</span>
            <i aria-hidden>↗</i>
          </article>
        ))}
      </div>
    </section>
  );
}

function Privacy() {
  return (
    <section id="privacy" className="garden-privacy">
      <div className="garden-privacy-flower"><BrandLogo size={128} /></div>
      <div>
        <p className="garden-section-label">Privacy is not a feature</p>
        <h2>Your conversations don&apos;t become our product.</h2>
        <p className="garden-privacy-copy">No meeting bot. No Daisy account. No cloud archive owned by someone else. Just your Mac, your folder and the words you said.</p>
        <div className="garden-privacy-facts">
          <div><b>0</b><span>cloud accounts</span></div>
          <div><b>1</b><span>folder you choose</span></div>
          <div><b>∞</b><span>ways to use your notes</span></div>
        </div>
        <Link href="/privacy" className="garden-dark-link">Read the privacy promise <span>↗</span></Link>
      </div>
    </section>
  );
}

function Closing() {
  return (
    <section id="download" className="garden-closing">
      <p className="garden-section-label">Made for the Mac in front of you</p>
      <h2>A calmer place<br />for every <em>important word.</em></h2>
      <DownloadAction source="garden_closing" />
      <p>Free during beta · No subscription meter · Apple Silicon only</p>
    </section>
  );
}

function Footer() {
  return (
    <footer className="garden-footer">
      <div className="garden-wordmark"><BrandLogo size={22} /> Daisy</div>
      <p>Private conversation memory, made on your Mac.</p>
      <div><Link href="/docs">Docs</Link><Link href="/privacy">Privacy</Link><Link href="/support">Support</Link><TrackedLink href="https://github.com/addicted-studio/daisy-app" event="github_view" eventProperties={{ source: "garden_footer" }} target="_blank" rel="noreferrer">GitHub ↗</TrackedLink></div>
    </footer>
  );
}

function DownloadAction({ source }: { source: string }) {
  if (HAS_NEWER_BETA) return <DownloadPicker channels={DOWNLOAD_CHANNELS} source={source} size="md" align="start" block />;
  return <TrackedLink href={LATEST_DMG_URL} event="download_dmg" eventProperties={{ source }} className="garden-download">Download Daisy <span aria-hidden>↘</span></TrackedLink>;
}
