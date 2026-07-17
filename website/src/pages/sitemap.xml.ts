import type { APIRoute } from "astro";
import { comparisonPagePaths } from "../config/competitors";

// Hand-rolled sitemap so we add ZERO npm dependency (fleet rule: no new
// deps without approval). It enumerates every route the static build
// emits — the fixed pages plus one /compared/<slug> per competitor,
// derived from the same competitors array that generates those pages.
//
// The production origin is the same one BaseLayout's canonical tags use:
// `Astro.site` from astro.config.mjs. We fall back to the known Pages
// origin so the sitemap is never emitted with relative URLs.
const PRODUCTION_ORIGIN = "https://heypace.app";

// Static, hand-maintained routes. `changefreq`/`priority` are advisory
// hints only; kept modest and honest rather than all "1.0 / daily".
const staticRoutes: { path: string; priority: string }[] = [
  { path: "/", priority: "1.0" },
  { path: "/compared", priority: "0.8" },
  { path: "/download", priority: "0.9" },
  { path: "/pricing", priority: "0.9" },
  { path: "/faq", priority: "0.7" },
  { path: "/privacy", priority: "0.4" },
  { path: "/terms", priority: "0.4" },
];

export const GET: APIRoute = ({ site }) => {
  const origin = (site ?? new URL(PRODUCTION_ORIGIN)).origin;

  const comparisonRoutes = comparisonPagePaths().map((path) => ({
    path,
    priority: "0.6",
  }));

  const allRoutes = [...staticRoutes, ...comparisonRoutes];

  const urlEntries = allRoutes
    .map(
      ({ path, priority }) =>
        `  <url>\n    <loc>${origin}${path}</loc>\n    <priority>${priority}</priority>\n  </url>`,
    )
    .join("\n");

  const sitemap = `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urlEntries}\n</urlset>\n`;

  return new Response(sitemap, {
    headers: {
      "Content-Type": "application/xml; charset=utf-8",
    },
  });
};
