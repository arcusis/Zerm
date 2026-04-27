(() => {
  const REPO = "arcusis/Zerm";

  function assetFor(platform, assets) {
    if (platform === "mac-arm") {
      return assets.find((asset) => /aarch64.*\.dmg$/i.test(asset.name));
    }
    if (platform === "mac-x86") {
      return assets.find((asset) => /(?:x64|x86_64).*\.dmg$/i.test(asset.name));
    }
    return null;
  }

  function detectOsKey() {
    const ua = navigator.userAgent || "";
    const platform = navigator.platform || "";
    if (/Mac/i.test(platform) || /Mac/i.test(ua)) return "mac";
    return "unknown";
  }

  const osLabels = {
    mac: "Choose macOS build",
    "mac-arm": "Download for macOS",
    "mac-x86": "Download for macOS Intel",
    unknown: "Download for macOS",
  };

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
    return releases.find((release) => !release.draft && !release.prerelease) || null;
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

    const osKey = detectOsKey();
    if (primaryLabel) primaryLabel.textContent = osLabels[osKey] || "Download latest";

    try {
      const release = await latestPublishedRelease();
      if (!release) throw new Error("No published release");

      const assets = Array.isArray(release.assets) ? release.assets : [];
      const tag = release.tag_name || "latest release";

      tagEls.forEach((el) => {
        el.textContent = tag;
      });

      cards.forEach((card) => {
        const platform = card.getAttribute("data-platform");
        const asset = assetFor(platform, assets);
        if (!asset?.browser_download_url) return;

        card.href = asset.browser_download_url;
        const hint = card.querySelector("small");
        const size = formatSize(asset.size);
        if (hint && size && !hint.dataset.originalText) {
          hint.dataset.originalText = hint.textContent || "";
          hint.textContent = `${hint.dataset.originalText} · ${size}`;
        }
      });

      const matching = osKey === "mac" || osKey === "unknown" ? null : assetFor(osKey, assets);
      if (primary && osKey === "mac" && release.html_url) {
        primary.href = release.html_url;
        if (primarySub) primarySub.textContent = `${tag} · GitHub Releases`;
      } else if (primary && matching?.browser_download_url) {
        primary.href = matching.browser_download_url;
        const size = formatSize(matching.size);
        if (primarySub) primarySub.textContent = size ? `${tag} · ${size}` : tag;
      } else if (primarySub) {
        primarySub.textContent = tag;
      }
    } catch (err) {
      console.warn("Could not hydrate GitHub release assets:", err);
      tagEls.forEach((el) => {
        el.textContent = "see GitHub Releases";
      });
    }
  }

  const year = document.getElementById("year");
  if (year) year.textContent = new Date().getFullYear();

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", hydrateDownloads);
  } else {
    hydrateDownloads();
  }
})();
