#!/usr/bin/env node
// Generates the static pages under docs/ that are derived from other sources:
//
//   changelog.html  <- GitHub releases
//   notice.html     <- NOTICE
//   license.html    <- LICENSE
//   building.html   <- BUILDING.md
//   docs/*.html     <- site-content/docs/*.md
//
// Markdown is rendered through GitHub's own GFM endpoint, so release notes look
// exactly as they do upstream without shipping a parser. Everything is baked at
// build time: the published pages make no API calls.
//
// Usage: node scripts/build-site.mjs

import { execFileSync } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const DOCS = join(ROOT, "docs");
const DOCS_PAGES = join(DOCS, "docs");
const CONTENT = join(ROOT, "site-content", "docs");
const REPO = "arcusis/Zerm";

const gh = (args, input) =>
  execFileSync("gh", args, {
    input,
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
  });

const esc = (s) =>
  String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/**
 * Render GitHub-flavoured markdown to HTML via the GitHub API.
 *
 * `context` makes GitHub resolve bare issue references, but it also rewrites
 * every relative link into a blob URL on the repository. Hand-written pages
 * link to their siblings and to local screenshots, so they render without it.
 */
function renderMarkdown(text, { context = REPO } = {}) {
  if (!text || !text.trim()) return "";
  const payload = context ? { text, mode: "gfm", context } : { text, mode: "gfm" };
  return gh(["api", "-X", "POST", "/markdown", "--input", "-"], JSON.stringify(payload));
}

/**
 * GitHub's renderer emits absolute anchors and bare issue links. Rewrite the
 * noisy bits so the changelog reads as site content rather than a mirror.
 */
function tidy(html) {
  return html
    // Drop the octicon anchor GitHub injects before every heading
    .replace(/<a[^>]*class="anchor"[^>]*>[\s\S]*?<\/a>/g, "")
    // Every image comes wrapped in a link to itself; screenshots are not links
    .replace(/<a\b[^>]*>\s*(<img\b[^>]*>)\s*<\/a>/g, "$1")
    // The stylesheet already makes tables scroll, so the wrapper element is noise
    .replace(/<\/?markdown-accessiblity-table>/g, "")
    // Open every outbound link in a new tab, without leaking the referrer
    .replace(/<a href="(https?:\/\/[^"]+)"/g, '<a href="$1" rel="noopener noreferrer" target="_blank"')
    .trim();
}

// Paths are relative to docs/; `base` puts them back together for pages that
// sit deeper in the tree.
const NAV = [
  ["#models", "Models"],
  ["#dictation", "Dictation"],
  ["#read-aloud", "Read aloud"],
  ["docs/", "Docs"],
  ["privacy.html", "Privacy"],
  ["changelog.html", "Changelog"],
];

function shell({ title, description, current, hero, body, wide = false, base = "./" }) {
  const nav = NAV.map(
    ([href, label]) =>
      `<a href="${base}${href}"${current === label ? ' aria-current="page"' : ""}>${label}</a>`
  ).join("\n          ");

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />
    <title>${esc(title)}</title>
    <meta name="description" content="${esc(description)}" />
    <meta name="theme-color" content="#0b0b0c" />
    <meta property="og:title" content="${esc(title)}" />
    <meta property="og:description" content="${esc(description)}" />
    <meta property="og:image" content="${base}icon.png" />
    <meta name="twitter:card" content="summary_large_image" />
    <link rel="icon" type="image/png" href="${base}icon.png" />
    <link rel="apple-touch-icon" href="${base}icon.png" />
    <link rel="stylesheet" href="${base}style.css" />
  </head>
  <body>
    <a class="skip" href="#main">Skip to content</a>

    <header class="topbar">
      <div class="topbar-inner">
        <a class="brand" href="${base}" aria-label="Zerm home">
          <img src="${base}icon.png" alt="" class="brand-logo" width="28" height="28" />
          <span>Zerm</span>
        </a>
        <nav class="topbar-nav" aria-label="Primary">
          ${nav}
        </nav>
        <div class="topbar-actions">
          <a class="ghost-link" href="https://github.com/${REPO}">GitHub</a>
          <a class="btn btn-light btn-sm" href="${base}#download">Download</a>
        </div>
      </div>
    </header>

    <main id="main" class="${wide ? "page page-wide" : "page"}">
${hero}
${body}
    </main>

    <footer class="site-foot">
      <div class="foot-inner">
        <div class="foot-brand">
          <img src="${base}icon.png" alt="" width="24" height="24" />
          <span>Zerm</span>
        </div>
        <nav class="foot-links" aria-label="Footer">
          <a href="${base}#download">Download</a>
          <a href="${base}docs/">Documentation</a>
          <a href="${base}changelog.html">Changelog</a>
          <a href="${base}privacy.html">Privacy</a>
          <a href="${base}building.html">Build from source</a>
          <a href="${base}notice.html">Attribution</a>
          <a href="${base}license.html">License</a>
        </nav>
        <p class="foot-legal">
          © <span id="year"></span> Arcusis · GPLv3 · Based on VoiceInk by Beingpax
        </p>
      </div>
    </footer>

    <script src="${base}site.js" defer></script>
  </body>
</html>
`;
}

function pageHero({ eyebrow, title, sub }) {
  return `      <section class="page-hero">
        <p class="eyebrow">${esc(eyebrow)}</p>
        <h1>${esc(title)}</h1>
        ${sub ? `<p class="lede">${sub}</p>` : ""}
      </section>`;
}

const DATE = new Intl.DateTimeFormat("en-GB", {
  day: "numeric",
  month: "long",
  year: "numeric",
  timeZone: "UTC",
});

/**
 * Sort key for a tag like v2.10.1 or v0.1.0-alpha.18. Release date is not
 * usable here: backfilled releases carry the date they were published, not the
 * date the work happened, which would float old versions to the top.
 */
function versionKey(tag) {
  const m = /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?/.exec(tag);
  if (!m) return [0, 0, 0, 0, tag];
  const [, maj, min, patch, pre] = m;
  // A pre-release sorts below the same version's final build
  const preNum = pre ? Number((/(\d+)\s*$/.exec(pre) || [])[1] ?? 0) : Infinity;
  return [Number(maj), Number(min), Number(patch), preNum, tag];
}

function compareVersions(a, b) {
  const ka = versionKey(a.tag);
  const kb = versionKey(b.tag);
  for (let i = 0; i < 4; i++) if (ka[i] !== kb[i]) return kb[i] - ka[i];
  return String(kb[4]).localeCompare(String(ka[4]));
}

function buildChangelog() {
  const releases = JSON.parse(
    gh([
      "api",
      `repos/${REPO}/releases`,
      "--paginate",
      "--jq",
      "[.[] | {tag: .tag_name, name: .name, body: .body, draft: .draft, prerelease: .prerelease, published: .published_at, created: .created_at, assets: [.assets[] | {name: .name, size: .size, url: .browser_download_url}]}]",
    ])
  );

  // Whichever release GitHub itself considers current
  let latestTag = "";
  try {
    latestTag = gh(["api", `repos/${REPO}/releases/latest`, "--jq", ".tag_name"]).trim();
  } catch {
    /* no latest designated — fall back to the highest version */
  }

  const published = releases.filter((r) => !r.draft).sort(compareVersions);

  if (!published.length) throw new Error("No published releases found");
  if (!latestTag) latestTag = published[0].tag;

  const entries = published
    .map((r) => {
      // created_at is when the release was cut; published_at is when the draft
      // was flipped public, which for backfilled releases is meaninglessly late.
      const stamp = r.created || r.published;
      const when = stamp ? DATE.format(new Date(stamp)) : "";
      const dmg = r.assets.find((a) => /\.dmg$/i.test(a.name));
      const heading = (r.name || r.tag).replace(/^Zerm\s*/i, "").trim() || r.tag;

      const badges = [
        r.prerelease ? '<span class="rel-badge pre">Pre-release</span>' : "",
        r.tag === latestTag ? '<span class="rel-badge now">Latest</span>' : "",
      ]
        .filter(Boolean)
        .join("");
      const badgesLine = badges ? `            ${badges}\n` : "";

      const download = dmg
        ? `<a class="rel-dl" href="${dmg.url}">Download .dmg <span>${(dmg.size / 1048576).toFixed(1)} MB</span></a>`
        : `<span class="rel-dl rel-dl-none">No build attached</span>`;

      return `        <article class="rel" id="${esc(r.tag)}">
          <div class="rel-meta">
            <a class="rel-tag" href="#${esc(r.tag)}">${esc(r.tag)}</a>
            <time>${esc(when)}</time>
${badgesLine}            ${download}
          </div>
          <div class="rel-body">
            <h2>${esc(heading)}</h2>
            <div class="prose">
${tidy(renderMarkdown(r.body))}
            </div>
          </div>
        </article>`;
    })
    .join("\n");

  const html = shell({
    title: "Changelog — Zerm",
    description:
      "Every published Zerm release, with the full notes: what changed, what was fixed, and how much faster it got.",
    current: "Changelog",
    hero: pageHero({
      eyebrow: `${published.length} releases`,
      title: "Changelog",
      sub: "Every published release, in full. Newest first.",
    }),
    body: `      <section class="rel-list">
${entries}
      </section>`,
  });

  writeFileSync(join(DOCS, "changelog.html"), html);
  console.log(`changelog.html — ${published.length} releases`);
}

function buildDoc({ file, out, title, pageTitle, eyebrow, sub, plain = false }) {
  const raw = readFileSync(join(ROOT, file), "utf8");
  const inner = plain
    ? `<pre class="plain">${esc(raw)}</pre>`
    : tidy(renderMarkdown(raw));

  const html = shell({
    title,
    description: sub.replace(/<[^>]+>/g, ""),
    current: null,
    hero: pageHero({ eyebrow, title: pageTitle, sub }),
    body: `      <section class="doc"><div class="prose">
${inner}
      </div></section>`,
  });

  writeFileSync(join(DOCS, out), html);
  console.log(`${out} — from ${file}`);
}

/**
 * The in-app announcements feed.
 *
 * `AnnouncementsService` fetches it from arcusis.github.io/Zerm/announcements.json
 * a few seconds after launch, so the published copy has to exist — without it every
 * launch is a silent 404. The repo root holds the source; mirroring it here on each
 * build is what stops the served feed drifting from the file people actually edit.
 */
function buildAnnouncements() {
  const raw = readFileSync(join(ROOT, "announcements.json"), "utf8");

  // Parse before publishing: a malformed feed is dropped on the floor by the app,
  // which looks exactly like no announcements at all.
  const feed = JSON.parse(raw);
  if (!Array.isArray(feed)) throw new Error("announcements.json must be a JSON array");

  writeFileSync(join(DOCS, "announcements.json"), raw);
  console.log(`announcements.json — ${feed.length} entries`);
}

/**
 * The documentation section. Order and grouping live here; the title and blurb
 * of each page come out of its own front matter, so there is one place to edit
 * a page and one place to decide where it sits.
 *
 * Every slug here must also exist as a `Links.Doc` case in the app — CI checks
 * the pairing in both directions, which is what keeps in-app links from rotting.
 */
const DOC_GROUPS = [
  {
    title: "Getting started",
    slugs: ["dictation", "permissions", "shortcuts", "audio-input"],
  },
  {
    title: "Dictation",
    slugs: ["output-modes", "enhancement", "enhancement-shortcuts", "dictionary", "power-mode"],
  },
  {
    title: "Models and speech",
    slugs: ["models", "custom-local-whisper-models", "read-aloud"],
  },
  {
    title: "Privacy",
    slugs: ["privacy-retention", "contextual-awareness"],
  },
  {
    title: "Support",
    slugs: ["common-issues", "announcements"],
  },
];

/** Splits `--- key: value --- body` into its two halves. */
function readDocSource(slug) {
  const raw = readFileSync(join(CONTENT, `${slug}.md`), "utf8");
  const match = /^---\n([\s\S]*?)\n---\n([\s\S]*)$/.exec(raw);
  if (!match) throw new Error(`${slug}.md has no front matter`);

  const meta = {};
  for (const line of match[1].split("\n")) {
    const pair = /^([a-z]+):\s*(.*)$/.exec(line.trim());
    if (pair) meta[pair[1]] = pair[2];
  }
  for (const key of ["title", "eyebrow", "summary"]) {
    if (!meta[key]) throw new Error(`${slug}.md is missing "${key}" in its front matter`);
  }

  return { ...meta, body: match[2] };
}

function buildDocsPages() {
  mkdirSync(join(DOCS_PAGES, "img"), { recursive: true });

  const pages = new Map();
  for (const group of DOC_GROUPS) {
    for (const slug of group.slugs) pages.set(slug, readDocSource(slug));
  }

  for (const [slug, page] of pages) {
    const html = shell({
      title: `${page.title} — Zerm`,
      description: page.summary,
      current: "Docs",
      base: "../",
      hero: pageHero({ eyebrow: page.eyebrow, title: page.title, sub: esc(page.summary) }),
      body: `      <section class="doc"><div class="prose">
${tidy(renderMarkdown(page.body, { context: null }))}
        </div>
        <p class="doc-more"><a class="text-link" href="./">All documentation</a></p>
      </section>`,
    });

    writeFileSync(join(DOCS_PAGES, `${slug}.html`), html);
  }

  const sections = DOC_GROUPS.map((group) => {
    const cards = group.slugs
      .map((slug) => {
        const page = pages.get(slug);
        return `          <a class="card doc-card reveal" href="./${slug}.html">
            <h3>${esc(page.title)}</h3>
            <p>${esc(page.summary)}</p>
          </a>`;
      })
      .join("\n");

    return `      <section class="doc-group">
        <h2>${esc(group.title)}</h2>
        <div class="feature-grid">
${cards}
        </div>
      </section>`;
  }).join("\n");

  const index = shell({
    title: "Documentation — Zerm",
    description:
      "How Zerm dictates, enhances, and reads text aloud on your Mac — every setting explained, including the ones the interface does not spell out.",
    current: "Docs",
    base: "../",
    hero: pageHero({
      eyebrow: `${pages.size} pages`,
      title: "Documentation",
      sub: "What each setting does, and what it costs you. Written against what the app actually does.",
    }),
    body: sections,
  });

  writeFileSync(join(DOCS_PAGES, "index.html"), index);
  console.log(`docs/index.html — ${pages.size} pages`);
  for (const slug of pages.keys()) console.log(`docs/${slug}.html — from site-content/docs/${slug}.md`);
}

buildAnnouncements();

buildChangelog();

buildDocsPages();

buildDoc({
  file: "NOTICE",
  out: "notice.html",
  title: "Attribution — Zerm",
  pageTitle: "Attribution",
  eyebrow: "Origin",
  sub: "Zerm is a modified GPLv3 derivative of VoiceInk by Beingpax. This is the NOTICE file, verbatim.",
  plain: true,
});

buildDoc({
  file: "BUILDING.md",
  out: "building.html",
  title: "Build from source — Zerm",
  pageTitle: "Build from source",
  eyebrow: "For developers",
  sub: "Requirements, build commands, and release tooling for the native macOS app.",
});

buildDoc({
  file: "Notebook/Zerm Native Writing Layer Verification.md",
  out: "verification.html",
  title: "Native writing layer verification — Zerm",
  pageTitle: "Native writing layer verification",
  eyebrow: "Engineering",
  sub: "How the macOS insertion, permission, and paste behaviours are verified.",
});

buildDoc({
  file: "LICENSE",
  out: "license.html",
  title: "License — Zerm",
  pageTitle: "GNU General Public License v3",
  eyebrow: "License",
  sub: "Zerm is free software. The full license text follows.",
  plain: true,
});
