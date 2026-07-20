import { Eyebrow } from "./Eyebrow";

// Small heritage / origin-story stripe. Sits between BringYourOwnAI
// and Download — a quiet beat between the "what it does" sections
// and the install CTA. The point isn't to dump trivia; it's to put
// a name on the table, hand the reader a piece of computing history,
// and close the loop with the privacy promise ("answers only to you").
//
// Visual treatment — "museum plaque": mono date-stamp eyebrow,
// italic display blockquote, accent hairline divider, then the
// body. The divider + date-stamp anchor what was previously a
// floating block of italic text in the middle of the page.
//
// Source notes:
//   • "Daisy Bell" — Harry Dacre, 1892. Public domain.
//   • IBM 7094, Bell Labs, 1961 — Max Mathews + John L. Kelly Jr.
//     used the machine to sing "Daisy Bell" via vocoder speech
//     synthesis. First time a computer ever sang.
//   • Arthur C. Clarke witnessed that demo and chose the song for
//     HAL 9000's deactivation scene in Kubrick's 2001 (1968).

export function Heritage() {
  return (
    <section
      id="heritage"
      className="relative border-t border-[color:var(--color-divider)] bg-[color:var(--color-bg-sidebar)] px-6 py-20 md:py-28"
    >
      <div className="mx-auto flex max-w-3xl flex-col items-center gap-8 text-center">
        <Eyebrow>The name</Eyebrow>

        {/* Mono date-stamp — gives the section a "museum plaque"
            anchor that the previous text-only treatment lacked.
            Tracking 0.3em, smaller than the eyebrow, in tertiary
            ink so it reads as a quiet caption, not a sub-header. */}
        <p className="font-mono text-xs uppercase tracking-[0.3em] text-[color:var(--color-ink-tertiary)]">
          IBM 7094 · Bell Labs · 1961
        </p>

        <blockquote className="font-display text-2xl font-medium italic leading-snug tracking-tight text-[color:var(--color-ink-primary)] md:text-3xl">
          &ldquo;Daisy, Daisy,
          <br />
          give me your answer, do&hellip;&rdquo;
        </blockquote>

        {/* Hairline accent divider — Apple-product-page idiom for
            "section break inside a quiet section". 64px wide, 1px
            tall, accent cinnamon. */}
        <div
          className="h-px w-16"
          style={{ background: "var(--color-accent)" }}
          aria-hidden
        />

        <div className="space-y-4 max-w-xl text-base leading-relaxed text-[color:var(--color-ink-secondary)]">
          <p>
            The first song any computer ever sang &mdash; an IBM 7094
            at Bell Labs in 1961. Seven years later Stanley Kubrick
            lifted it for HAL 9000&rsquo;s last words in&nbsp;
            <em>2001: A Space Odyssey</em>.
          </p>
          <p>
            It felt like a fitting name for a meeting assistant that
            lives on your Mac and answers only to you.
          </p>
        </div>
      </div>
    </section>
  );
}
