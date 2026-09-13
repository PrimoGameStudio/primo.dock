// IconResolver.js — Advanced Icon Resolution for Omarchy Dock

.pragma library

var iconCache = {};

var customIconOverrides = {};

function setCustomIcon(appId, iconName) {
    if (!appId) return;
    var key = String(appId).toLowerCase().trim();
    if (iconName) {
        customIconOverrides[key] = String(iconName).trim();
    } else {
        delete customIconOverrides[key];
    }
    // Clear cache for this key
    for (var k in iconCache) {
        if (k.indexOf(key) !== -1 || key.indexOf(k) !== -1) {
            delete iconCache[k];
        }
    }
}

function getCustomIcon(appId) {
    if (!appId) return "";
    var key = String(appId).toLowerCase().trim();
    return customIconOverrides[key] || "";
}

function allCustomIcons() {
    var out = {};
    for (var k in customIconOverrides) {
        out[k] = customIconOverrides[k];
    }
    return out;
}

function loadCustomIcons(map) {
    customIconOverrides = {};
    if (map && typeof map === "object") {
        for (var k in map) {
            var value = String(map[k] || "").trim();
            if (value) customIconOverrides[String(k).toLowerCase().trim()] = value;
        }
    }
    iconCache = {};
}

var FALLBACK_MAP = {
    "kitty": "kitty",
    "alacritty": "Alacritty",
    "foot": "foot",
    "ghostty": "com.mitchellh.ghostty",
    "google-chrome": "google-chrome",
    "chrome": "google-chrome",
    "chromium": "chromium",
    "yandex-browser": "yandex-browser",
    "firefox": "firefox",
    "code": "com.visualstudio.code",
    "vscode": "com.visualstudio.code",
    "nautilus": "org.gnome.Nautilus",
    "files": "org.gnome.Nautilus",
    "dolphin": "org.kde.dolphin",
    "thunar": "org.xfce.thunar",
    "telegram": "telegram",
    "telegramdesktop": "telegram",
    "discord": "discord",
    "obsidian": "obsidian",
    "spotify": "spotify",
    "steam": "steam"
};

function sanitizeName(name) {
    if (!name) return "";
    return String(name).toLowerCase().trim()
        .replace(/^org\./, "")
        .replace(/^com\./, "")
        .replace(/^io\./, "")
        .replace(/^dev\./, "")
        .replace(/\.desktop$/, "");
}

// Strip URL query/fragment (e.g. image://...?path=...) before name checks.
function stripIconParams(src) {
    var s = String(src || "");
    var q = s.indexOf("?");
    if (q >= 0) s = s.slice(0, q);
    var h = s.indexOf("#");
    if (h >= 0) s = s.slice(0, h);
    return s;
}

function isSymbolicSource(src) {
    var s = stripIconParams(src).toLowerCase();
    // Match a trailing -symbolic on the basename (with or without extension)
    // so "foo-symbolic" and "foo-symbolic.svg" both count, but "mysymbolic"
    // does not.
    return /(^|\/)-?symbolic(\.[a-z0-9]+)?$/.test(s) || s.slice(-9) === "-symbolic";
}

// Filename heuristic for monochrome icon sets (HighContrast, -light/-dark
// variants, mono builds). Pixel-content analysis is not feasible cheaply in
// QML per-icon, so "auto" tint mode relies on these markers: brand-color
// icons without such markers are left full-color.
function isMonochromeSource(src) {
    if (!src) return false;
    var s = stripIconParams(src).toLowerCase();
    if (isSymbolicSource(s)) return true;
    if (s.indexOf("highcontrast") !== -1) return true;
    if (s.indexOf("monochrome") !== -1) return true;
    if (s.indexOf("symbolic") !== -1) return true;
    // -light/-dark/-black/-white/-mono suffix before the extension, e.g.
    // "ghostty-light.svg", "tmux-dark.svg", "lmstudio-dark.png"
    if (/[-_](light|dark|black|white|mono)\.[a-z0-9]+$/.test(s)) return true;
    // .../light/... or .../dark/... path segment
    if (/\/(light|dark|black|white|mono)\//.test(s)) return true;
    return false;
}

// Should the icon for an app be theme-tinted under the given mode?
// mode: "none" (never), "all" (always), "symbolic" (only *-symbolic),
// anything else ("auto"/undefined) = only monochrome-looking sources.
// Candidates cover the user override, the library icon name, the resolved
// icon and the raw app identifiers so file:// custom icons keep their
// filename markers even after iconSource() rewrites theme icons to
// image:// URLs (which lose the filename).
function shouldTintIconFor(appClass, appName, appId, mode) {
    var m = String(mode || "auto").toLowerCase();
    if (m === "none") return false;
    if (m === "all") return true;
    var candidates = [];
    var custom = getCustomIcon(appId || appClass || appName);
    if (custom) candidates.push(custom);
    if (appName) candidates.push(appName);
    var resolved = resolveIcon(appClass, appName, appId);
    if (resolved) candidates.push(resolved);
    if (appClass) candidates.push(appClass);
    if (appId) candidates.push(appId);
    for (var i = 0; i < candidates.length; i++) {
        var c = candidates[i];
        if (!c) continue;
        if (m === "symbolic") {
            if (isSymbolicSource(c)) return true;
        } else {
            if (isMonochromeSource(c)) return true;
        }
    }
    return false;
}

function resolveIcon(appClass, appName, appId) {
    var checkId = appId || appClass || appName || "";
    var custom = getCustomIcon(checkId);
    if (custom) return custom;

    var raw = String(appClass || appName || appId || "").trim();
    if (!raw) return "application-x-executable";

    var key = raw.toLowerCase();
    if (iconCache[key]) return iconCache[key];

    // Handle Chrome/Chromium/Edge web apps (e.g. chrome-hnpfjngllpiocgelkpfmhdggcdapoihn-Default or crx_...)
    // Shared JS libraries cannot reach the Quickshell singleton, so fall back to
    // the closest matching browser icon; the QML layer resolves the final source.
    if (key.indexOf("chrome-") === 0 || key.indexOf("chromium-") === 0 || key.indexOf("crx_") === 0 || key.indexOf("webapp-") === 0) {
        iconCache[key] = "google-chrome";
        return "google-chrome";
    }

    var clean = sanitizeName(raw);
    if (FALLBACK_MAP[clean]) {
        iconCache[key] = FALLBACK_MAP[clean];
        return iconCache[key];
    }

    if (FALLBACK_MAP[key]) {
        iconCache[key] = FALLBACK_MAP[key];
        return iconCache[key];
    }

    iconCache[key] = raw;
    return raw;
}
