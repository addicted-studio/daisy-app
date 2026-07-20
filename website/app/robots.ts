import type { MetadataRoute } from "next";

// robots.txt for mydaisy.io.
//
// Next.js generates the actual /robots.txt file from this config.
// Allow every well-behaved crawler everywhere — Daisy's site is a
// pure marketing + docs surface, nothing private, nothing per-user.
//
// The Sitemap pointer is the most useful directive here: it tells
// Googlebot / Bingbot / Yandexbot / DuckDuckBot / Perplexitybot
// exactly where the structured route list lives, so they can
// discover new docs pages within hours instead of waiting for the
// long-tail link-following pass.

export default function robots(): MetadataRoute.Robots {
  return {
    rules: [
      {
        userAgent: "*",
        allow: "/",
      },
    ],
    sitemap: "https://mydaisy.io/sitemap.xml",
    host: "https://mydaisy.io",
  };
}
