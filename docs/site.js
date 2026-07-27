(() => {
  const REPO = "arcusis/Zerm";

  // Match any DMG that contains "aarch64" or "arm64"
  function assetForArm(assets) {
    return assets.find((a) => /aarch64|arm64/i.test(a.name) && /\.dmg$/i.test(a.name));
  }

  // Match any DMG that contains "x64", "x86_64", or "amd64"
  function assetForIntel(assets) {
    return assets.find((a) => /x64|x86_64|amd64/i.test(a.name) && /\.dmg$/i.test(a.name));
  }

  // The plain macOS archive, for people who would rather not mount a disk image
  function assetForZip(assets) {
    return assets.find((a) => /\.zip$/i.test(a.name) && /mac/i.test(a.name));
  }

  function assetFor(platform, assets) {
    if (platform === "mac-arm") return assetForArm(assets);
    if (platform === "mac-x86") return assetForIntel(assets);
    if (platform === "mac-zip") return assetForZip(assets);
    return null;
  }

  // Best guess at chip based on user-agent.
  // Returns "mac-arm", "mac-x86", or "mac" (unknown).
  function detectOsKey() {
    const ua = navigator.userAgent || "";
    const platform = (navigator.platform || "").toLowerCase();
    if (!/mac/i.test(platform) && !/mac/i.test(ua)) return "unknown";
    // Rough heuristics: modern Macs on macOS 11+ report arm in some UAs;
    // also check for known Apple Silicon indicators.
    if (/arm|aarch64/i.test(ua) || /M[0-9]/i.test(navigator.userAgent)) return "mac-arm";
    // UserAgent alone is unreliable for chip detection; default to arm
    // since the majority of active Macs sold since late 2020 are Apple Silicon.
    return "mac-arm";
  }

  function formatSize(bytes) {
    if (!bytes) return "";
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }

  async function latestPublishedRelease() {
    const resp = await fetch(`https://api.github.com/repos/${REPO}/releases?per_page=10`, {
      headers: { Accept: "application/vnd.github+json" },
    });
    if (!resp.ok) throw new Error(`GitHub ${resp.status}`);
    const releases = await resp.json();
    if (!Array.isArray(releases)) return null;
    return releases.find((r) => !r.draft && !r.prerelease) || null;
  }

  async function hydrateDownloads() {
    const cards = document.querySelectorAll("a.download-card[data-platform]");
    const primary = document.getElementById("primary-download");
    const primaryLabel = primary?.querySelector(".btn-label");
    const primarySub = document.getElementById("primary-download-sub");
    const tagEls = [
      document.getElementById("release-tag"),
      document.getElementById("release-tag-2"),
    ].filter(Boolean);

    try {
      const release = await latestPublishedRelease();
      if (!release) throw new Error("No published release");

      const assets = Array.isArray(release.assets) ? release.assets : [];
      const tag = release.tag_name || "";

      tagEls.forEach((el) => { el.textContent = tag || "latest"; });

      // Update each download card to point directly at the asset
      cards.forEach((card) => {
        const platform = card.getAttribute("data-platform");
        const asset = assetFor(platform, assets);

        // No build for this platform in the current release — say so rather
        // than leaving the card pointing at an anchor that goes nowhere.
        if (!asset?.browser_download_url) {
          card.classList.add("unavailable");
          card.href = `https://github.com/${REPO}/releases`;
          const hint = card.querySelector("small");
          if (hint) hint.textContent = "Not in this release · see all releases";
          return;
        }

        card.href = asset.browser_download_url;
        const hint = card.querySelector("small");
        const size = formatSize(asset.size);
        if (hint && size && !hint.dataset.originalText) {
          hint.dataset.originalText = hint.textContent || "";
          hint.textContent = `${hint.dataset.originalText} · ${size}`;
        }
      });

      // Primary CTA: detect chip, pick asset, download directly
      const osKey = detectOsKey();
      const primaryAsset = assetFor(osKey, assets) ?? assetForArm(assets) ?? assetForIntel(assets);

      if (primary && primaryAsset?.browser_download_url) {
        primary.href = primaryAsset.browser_download_url;
        if (primaryLabel) {
          primaryLabel.textContent = "Download for macOS";
        }
        if (primarySub) {
          const size = formatSize(primaryAsset.size);
          const arch = /aarch64|arm64/i.test(primaryAsset.name) ? "Apple Silicon" : "Intel";
          primarySub.textContent = [tag, arch, size]
            .filter(Boolean)
            .join(" · ");
        }
      } else if (primary) {
        // No asset found for this platform — keep the button but make it clear
        if (primaryLabel) primaryLabel.textContent = "Download for macOS";
        if (primarySub) primarySub.textContent = tag || "see GitHub";
        // Don't redirect to GitHub releases page; just show the source link instead
        primary.href = `https://github.com/${REPO}/releases/tag/${tag || "latest"}`;
      }

    } catch (err) {
      console.warn("Could not hydrate GitHub release assets:", err);
      tagEls.forEach((el) => { el.textContent = "latest"; });
    }
  }

  // Fade sections in as they enter the viewport. Degrades to "always visible".
  function initReveals() {
    const targets = document.querySelectorAll(".reveal");
    const reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

    if (reduced || !("IntersectionObserver" in window)) {
      document.body.classList.add("no-reveal");
      return;
    }

    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          entry.target.classList.add("in");
          observer.unobserve(entry.target);
        });
      },
      { rootMargin: "0px 0px -8% 0px", threshold: 0.08 }
    );

    targets.forEach((el) => observer.observe(el));
  }

  const year = document.getElementById("year");
  if (year) year.textContent = new Date().getFullYear();

  function init() {
    initReveals();
    hydrateDownloads();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
