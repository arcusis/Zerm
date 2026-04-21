// Zerm marketing page — light sprinkles:
//   1. Fetch the latest GitHub release and swap download links to the
//      actual per-platform assets so "Latest" stays current without a
//      redeploy.
//   2. Detect the visitor's OS and highlight the matching primary CTA.
//   3. Footer year.

(() => {
  const REPO = "arcusis/Zerm";

  // Regexes describing which release asset belongs to which platform card.
  const ASSET_PATTERNS = {
    "mac-arm": /\.dmg$/i,
    "mac-x86": /_x64\.dmg$/i,
    win: /_x64-setup\.exe$|_x64_en-US\.msi$/i,
    "linux-appimage": /\.AppImage$/i,
    "linux-deb": /\.deb$/i,
  };

  // More specific patterns take precedence. If x64 matches first, arm64
  // should NOT also pick it up.
  function assetFor(platform, assets) {
    if (platform === "mac-arm") {
      return assets.find((a) => /aarch64\.dmg$/i.test(a.name));
    }
    if (platform === "mac-x86") {
      return assets.find((a) => /_x64\.dmg$/i.test(a.name));
    }
    if (platform === "win") {
      return (
        assets.find((a) => /_x64-setup\.exe$/i.test(a.name)) ||
        assets.find((a) => /_x64_en-US\.msi$/i.test(a.name))
      );
    }
    if (platform === "linux-appimage") {
      return assets.find((a) => /\.AppImage$/i.test(a.name));
    }
    if (platform === "linux-deb") {
      return assets.find((a) => /\.deb$/i.test(a.name));
    }
    return null;
  }

  function detectOsKey() {
    const ua = navigator.userAgent;
    const platform = navigator.platform || "";
    if (/Mac/i.test(platform) || /Mac/i.test(ua)) {
      // arm64 Macs report "MacIntel" in platform, so we can't be 100%
      // certain — default to Apple Silicon (correct since ~2020) but let
      // users flip to the Intel build from the grid.
      return "mac-arm";
    }
    if (/Win/i.test(platform) || /Windows/i.test(ua)) return "win";
    if (/Linux|X11/i.test(platform) || /Linux/i.test(ua)) return "linux-appimage";
    return "mac-arm";
  }

  const OS_LABELS = {
    "mac-arm": "Download for macOS",
    "mac-x86": "Download for macOS (Intel)",
    win: "Download for Windows",
    "linux-appimage": "Download for Linux",
    "linux-deb": "Download .deb for Linux",
  };

  async function hydrate() {
    const cards = document.querySelectorAll("a.dl[data-platform]");
    const primaryBtn = document.getElementById("primary-download");
    const primarySub = document.getElementById("primary-download-sub");
    const tagEls = [
      document.getElementById("release-tag"),
      document.getElementById("release-tag-2"),
    ].filter(Boolean);

    // Detected OS — update primary CTA label while we fetch.
    const osKey = detectOsKey();
    const primaryLabel = primaryBtn?.querySelector(".btn-label");
    if (primaryLabel) primaryLabel.textContent = OS_LABELS[osKey] || OS_LABELS["mac-arm"];

    try {
      const resp = await fetch(
        `https://api.github.com/repos/${REPO}/releases/latest`,
        { headers: { Accept: "application/vnd.github+json" } },
      );
      if (!resp.ok) throw new Error(`GH ${resp.status}`);
      const data = await resp.json();
      const assets = Array.isArray(data.assets) ? data.assets : [];
      const tag = data.tag_name || "";

      tagEls.forEach((el) => {
        if (el) el.textContent = tag;
      });

      cards.forEach((card) => {
        const platform = card.getAttribute("data-platform");
        const asset = assetFor(platform, assets);
        if (asset && asset.browser_download_url) {
          card.href = asset.browser_download_url;
          const hint = card.querySelector(".dl-hint");
          if (hint && asset.size) {
            const mb = (asset.size / 1024 / 1024).toFixed(1);
            hint.textContent = `${hint.textContent} · ${mb} MB`;
          }
        }
      });

      const matching = assetFor(osKey, assets);
      if (matching && primaryBtn) {
        primaryBtn.href = matching.browser_download_url;
        if (primarySub) primarySub.textContent = `${tag} · ${(matching.size / 1024 / 1024).toFixed(1)} MB`;
      }
    } catch (err) {
      // Network blocked / rate-limited / no release yet — leave the static
      // fallback hrefs pointing at /releases/latest and let the user pick.
      console.warn("release fetch failed, using fallback links:", err);
    }
  }

  const year = document.getElementById("year");
  if (year) year.textContent = new Date().getFullYear();

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", hydrate);
  } else {
    hydrate();
  }
})();
