// @ts-check
import { defineConfig } from "astro/config";
import tailwindcss from "@tailwindcss/vite";

// Fleet web-stack standard (AGENTS.md):
//   - Astro for marketing / landing surfaces
//   - Tailwind v4 via @tailwindcss/vite
//   - Lightning CSS as transformer + minifier
//   - Inline critical CSS on every prerendered page
//
// Cloudflare Pages deployment: `pages_build_output_dir: dist`.
export default defineConfig({
  site: "https://pace.app",
  output: "static",
  build: {
    // Flat-inlines per-page CSS so the LCP element doesn't wait on
    // a separate stylesheet round-trip.
    inlineStylesheets: "always",
  },
  vite: {
    plugins: [tailwindcss()],
    css: {
      transformer: "lightningcss",
    },
    build: {
      cssMinify: "lightningcss",
    },
  },
});
