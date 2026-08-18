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

function resolveIcon(appClass, appName, appId) {
    var checkId = appId || appClass || appName || "";
    var custom = getCustomIcon(checkId);
    if (custom) return custom;

    var raw = String(appClass || appName || appId || "").trim();
    if (!raw) return "application-x-executable";

    var key = raw.toLowerCase();
    if (iconCache[key]) return iconCache[key];

    // Handle Chrome/Chromium/Edge web apps (e.g. chrome-hnpfjngllpiocgelkpfmhdggcdapoihn-Default or crx_...)
    if (key.indexOf("chrome-") === 0 || key.indexOf("chromium-") === 0 || key.indexOf("crx_") === 0 || key.indexOf("webapp-") === 0) {
        // If it's a chrome webapp, check if appLibrary or Quickshell can find an icon for it, or fallback to chrome/google-chrome if no specific icon found
        var qIcon = Quickshell.iconPath(raw, true);
        if (qIcon && qIcon.length > 0) {
            iconCache[key] = raw;
            return raw;
        }
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
