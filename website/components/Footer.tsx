import Link from "next/link";
import { BrandLogo } from "./BrandLogo";

export function Footer() {
  return (
    <footer className="relative border-t border-[color:var(--color-divider)] bg-[color:var(--color-bg-sidebar)] px-6 py-12">
      <div className="mx-auto flex max-w-5xl flex-col items-start gap-8 md:flex-row md:items-center md:justify-between">
        <div>
          <div className="mb-2 flex items-center gap-2 font-medium">
            <BrandLogo size={18} />
            Daisy
          </div>
          <p className="text-sm text-[color:var(--color-ink-tertiary)]">
            Local meeting capture for Mac. Made by{" "}
            <Link
              href="https://addicted.sh"
              className="underline decoration-[color:var(--color-ink-tertiary)] underline-offset-4 hover:text-[color:var(--color-ink)]"
              target="_blank"
              rel="noreferrer"
            >
              Addicted Studio
            </Link>
            .
          </p>
        </div>

        <div className="flex flex-wrap items-center gap-x-6 gap-y-2 text-sm text-[color:var(--color-ink-secondary)]">
          <Link href="/support" className="hover:text-[color:var(--color-ink)] transition-colors">
            Support
          </Link>
          <Link href="/privacy" className="hover:text-[color:var(--color-ink)] transition-colors">
            Privacy
          </Link>
          <Link href="mailto:essazanov@pm.me" className="hover:text-[color:var(--color-ink)] transition-colors">
            essazanov@pm.me
          </Link>
          <Link
            href="https://github.com/addicted-studio/daisy-app"
            target="_blank"
            rel="noreferrer"
            className="hover:text-[color:var(--color-ink)] transition-colors"
          >
            GitHub →
          </Link>
          <Link
            href="https://addicted.sh"
            target="_blank"
            rel="noreferrer"
            className="hover:text-[color:var(--color-ink)] transition-colors"
          >
            addicted.sh →
          </Link>
        </div>
      </div>
    </footer>
  );
}
