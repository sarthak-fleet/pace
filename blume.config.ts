// @ts-check
// Pace documentation site — Blume presentation layer.
//
// The committed Markdown under docs/ is the source of truth. Blume is ONLY the
// presentation + search layer (see AGENTS.md → Documentation navigation). Do
// not edit docs content to satisfy Blume; edit Blume config to fit the docs.
//
// Usage:
//   npm install            # install Blume (pinned to 1.0.4)
//   npm run docs:dev       # http://localhost:3000
//   npm run docs:build     # -> dist/
//   npm run docs:validate  # broken-link check (also run in CI)
//
import { defineConfig } from "blume";

export default defineConfig({
  // Site
  title: "Pace docs",
  description:
    "Pace — the on-device macOS menu-bar voice agent. Architecture, product, development, operations, and learnings.",
  logo: {
    // Reuse the product mascot mark from the repo.
    image: "/docs/product/brand/pace-mascot.svg",
    text: "Pace",
    href: "/",
  },

  // Content — the existing docs/ tree is the content root. No file moves needed.
  content: {
    root: "docs",
  },

  // GitHub link in the header (also powers "Edit on GitHub" page actions).
  github: {
    owner: "sarthakagrawal927",
    repo: "pace",
  },

  // Theme — quiet, technical.
  theme: {
    accent: "indigo",
    radius: "md",
    mode: "system",
  },

  // Search — local, no hosted service.
  search: {
    provider: "orama",
  },

  // Markdown
  markdown: {
    imageZoom: true,
    code: { icons: true, wrap: false },
    codeBlocks: {
      theme: { light: "github-light", dark: "github-dark" },
    },
  },

  // AI — emit llms.txt so agent crawlers can ingest the docs.
  ai: {
    llmsTxt: true,
    mcp: { enabled: false, route: "/mcp" },
  },

  // SEO
  seo: {
    og: { enabled: true },
    sitemap: true,
    robots: true,
    structuredData: true,
  },

  // Deployment — static output. The marketing site (website/) is a separate
  // Cloudflare Pages project (`pace`); this docs site is a separate deploy.
  deployment: {
    output: "static",
    site: "https://docs.heypace.app",
  },
});
