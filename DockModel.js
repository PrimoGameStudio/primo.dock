// DockModel.js — Model & state management for Omarchy Dock

.pragma library

var DEFAULT_PINNED = [
    "org.kde.dolphin",
    "com.mitchellh.ghostty",
    "steam",
    "code",
    "google-chrome",
    "org.kde.krita"
];

var DEFAULT_BLACKLIST = [];

var DEFAULT_SETTINGS = {
    iconSize: 28,
    itemSize: 46,
    padding: 6,
    hoverScale: 1.12,
    dragScale: 1.22,
    backgroundOpacity: 0.94,
    showRunningDots: true
};

var SETTINGS_CLAMPS = {
    iconSize: { min: 12, max: 128 },
    itemSize: { min: 24, max: 160 },
    padding: { min: 0, max: 48 },
    hoverScale: { min: 1.0, max: 2.0 },
    dragScale: { min: 1.0, max: 2.5 },
    backgroundOpacity: { min: 0.0, max: 1.0 }
};

function clampNumber(value, min, max, fallback) {
    var n = Number(value);
    if (!isFinite(n)) return fallback;
    return Math.max(min, Math.min(max, n));
}

function parseSettings(raw) {
    var text = String(raw == null ? "" : raw).trim();
    var parsed = null;
    if (text) {
        try {
            parsed = JSON.parse(text);
        } catch (e) {
            parsed = null;
        }
    }
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        parsed = {};
    }

    var out = {};
    for (var key in DEFAULT_SETTINGS) {
        var val = parsed[key];
        var def = DEFAULT_SETTINGS[key];
        var clamp = SETTINGS_CLAMPS[key];
        if (typeof def === "boolean") {
            if (val === undefined || val === null) {
                out[key] = def;
            } else if (typeof val === "string") {
                out[key] = val !== "false" && val !== "0" && val !== "";
            } else {
                out[key] = val !== false;
            }
        } else if (clamp) {
            out[key] = clampNumber(val, clamp.min, clamp.max, def);
        } else {
            out[key] = (val === undefined || val === null) ? def : val;
        }
    }

    if (out.iconSize + 6 > out.itemSize) out.itemSize = Math.round(out.iconSize + 6);
    return out;
}

function serializeSettings(settings) {
    var src = (settings && typeof settings === "object") ? settings : DEFAULT_SETTINGS;
    var cleaned = {};
    for (var key in DEFAULT_SETTINGS) {
        var clamp = SETTINGS_CLAMPS[key];
        var def = DEFAULT_SETTINGS[key];
        var val = src[key];
        if (typeof def === "boolean") {
            cleaned[key] = (val === undefined || val === null) ? def : (typeof val === "string" ? val !== "false" && val !== "0" && val !== "" : val !== false);
        } else if (clamp) {
            cleaned[key] = clampNumber(val, clamp.min, clamp.max, def);
        } else {
            cleaned[key] = (val === undefined || val === null) ? def : val;
        }
    }
    if (cleaned.iconSize + 6 > cleaned.itemSize) cleaned.itemSize = Math.round(cleaned.iconSize + 6);
    return JSON.stringify(cleaned, null, 2);
}

function parseBlacklist(raw) {
    var text = String(raw == null ? "" : raw).trim();
    if (!text) return DEFAULT_BLACKLIST.slice();

    var parsed = null;
    try {
        parsed = JSON.parse(text);
    } catch (e) {
        return DEFAULT_BLACKLIST.slice();
    }
    if (!parsed) return DEFAULT_BLACKLIST.slice();

    var arr = [];
    if (Array.isArray(parsed)) {
        for (var k = 0; k < parsed.length; k++) {
            var item = parsed[k];
            if (typeof item === "string") {
                arr.push(item);
            } else if (item && typeof item === "object") {
                var c = item.appClass || item.id || item.exec || "";
                if (c) arr.push(c);
            }
        }
    } else if (typeof parsed === "object" && Array.isArray(parsed.blacklist)) {
        arr = parsed.blacklist;
    }

    var out = [];
    var seen = {};
    for (var i = 0; i < arr.length; i++) {
        var id = stripDesktop(arr[i]);
        if (!id || seen[id]) continue;
        seen[id] = true;
        out.push(id);
    }
    return out;
}

function serializeBlacklist(blacklistIds) {
    var arr = Array.isArray(blacklistIds) ? blacklistIds : [];
    var cleaned = [];
    var seen = {};
    for (var i = 0; i < arr.length; i++) {
        var id = stripDesktop(arr[i]);
        if (!id || seen[id]) continue;
        seen[id] = true;
        cleaned.push(id);
    }
    return JSON.stringify({ blacklist: cleaned }, null, 2);
}

function isBlacklisted(blacklistIds, appId) {
    var arr = Array.isArray(blacklistIds) ? blacklistIds : [];
    var id = stripDesktop(appId);
    if (!id) return false;
    for (var i = 0; i < arr.length; i++) {
        var b = arr[i];
        if (b === id || id.indexOf(b) !== -1 || b.indexOf(id) !== -1) {
            return true;
        }
    }
    return false;
}

function stripDesktop(id) {
    var value = String(id == null ? "" : id).trim();
    if (value.slice(-8) === ".desktop") value = value.slice(0, -8);
    return value;
}

function toArray(list) {
    if (Array.isArray(list)) return list;
    if (list && typeof list.length === "number") {
        var out = [];
        for (var i = 0; i < list.length; i++) out.push(list[i]);
        return out;
    }
    return [];
}

function parsePinned(raw) {
    var text = String(raw == null ? "" : raw).trim();
    if (!text) return DEFAULT_PINNED.slice();

    var parsed = null;
    try {
        parsed = JSON.parse(text);
    } catch (e) {
        return DEFAULT_PINNED.slice();
    }
    if (!parsed) return DEFAULT_PINNED.slice();

    var arr = [];
    if (Array.isArray(parsed)) {
        // Support legacy object format or string array format
        for (var k = 0; k < parsed.length; k++) {
            var item = parsed[k];
            if (typeof item === "string") {
                arr.push(item);
            } else if (item && typeof item === "object") {
                var c = item.appClass || item.id || item.exec || "";
                c = c.replace(/^pin_/, "");
                if (c) arr.push(c);
            }
        }
    } else if (typeof parsed === "object" && Array.isArray(parsed.pinned)) {
        arr = parsed.pinned;
    }

    if (arr.length === 0) return DEFAULT_PINNED.slice();

    var out = [];
    var seen = {};
    for (var i = 0; i < arr.length; i++) {
        var id = stripDesktop(arr[i]);
        if (!id || seen[id]) continue;
        seen[id] = true;
        out.push(id);
    }
    return out;
}

function serializePinned(pinnedIds) {
    var arr = Array.isArray(pinnedIds) ? pinnedIds : [];
    var cleaned = [];
    var seen = {};
    for (var i = 0; i < arr.length; i++) {
        var id = stripDesktop(arr[i]);
        if (!id || seen[id]) continue;
        seen[id] = true;
        cleaned.push(id);
    }
    return JSON.stringify({ pinned: cleaned }, null, 2);
}

function togglePinned(pinnedIds, appId) {
    var arr = Array.isArray(pinnedIds) ? pinnedIds.slice() : [];
    var id = stripDesktop(appId);
    if (!id) return arr;
    var idx = arr.indexOf(id);
    if (idx >= 0) arr.splice(idx, 1);
    else arr.push(id);
    return arr;
}

function isPinned(pinnedIds, appId) {
    var arr = Array.isArray(pinnedIds) ? pinnedIds : [];
    return arr.indexOf(stripDesktop(appId)) >= 0;
}

function reorderPinned(pinnedIds, dockItems, fromIndex, toIndex) {
    if (fromIndex === toIndex || fromIndex < 0 || toIndex < 0) return pinnedIds;
    if (!dockItems || fromIndex >= dockItems.length || toIndex >= dockItems.length) return pinnedIds;

    var sourceItem = dockItems[fromIndex];
    if (!sourceItem || !sourceItem.appId) return pinnedIds;

    var srcId = stripDesktop(sourceItem.appId);
    var next = [];
    for (var i = 0; i < pinnedIds.length; i++) {
        var pid = stripDesktop(pinnedIds[i]);
        if (pid !== srcId) next.push(pid);
    }

    var insertIdx = Math.max(0, Math.min(next.length, toIndex));
    next.splice(insertIdx, 0, srcId);
    return next;
}

function entryFor(appRows, appId) {
    var want = stripDesktop(appId).toLowerCase();
    if (!want || !appRows) return null;
    // First try exact match or case-insensitive match on entry.id or desktop file name
    for (var i = 0; i < appRows.length; i++) {
        var row = appRows[i];
        var entry = row && row.entry;
        if (!entry) continue;
        var entryId = stripDesktop(entry.id).toLowerCase();
        if (entryId === want || entryId.indexOf(want) !== -1 || want.indexOf(entryId) !== -1) {
            return entry;
        }
        if (entry.wmClass && String(entry.wmClass).toLowerCase() === want) {
            return entry;
        }
        if (entry.exec && String(entry.exec).toLowerCase().indexOf(want) !== -1) {
            return entry;
        }
    }
    // Fallback: check startupWMClass or name
    for (var j = 0; j < appRows.length; j++) {
        var r = appRows[j];
        var e = r && r.entry;
        if (!e) continue;
        if (e.startupWMClass && String(e.startupWMClass).toLowerCase() === want) return e;
        if (e.id && stripDesktop(e.id).toLowerCase().indexOf(want) !== -1) return e;
    }
    return null;
}

function buildDockItems(pinnedIds, blacklistIds, toplevels, activeToplevel, appRows, appLibrary) {
    var pinned = Array.isArray(pinnedIds) ? pinnedIds : [];
    var list = toArray(toplevels);

    var runningMap = {};
    var runningOrder = [];

    var activeApp = activeToplevel ? stripDesktop(activeToplevel.appId) : "";

    for (var i = 0; i < list.length; i++) {
        var toplevel = list[i];
        if (!toplevel) continue;
        var appId = stripDesktop(toplevel.appId);
        if (!appId || appId === "quickshell" || appId === "hyprland") continue;
        if (isBlacklisted(blacklistIds, appId)) continue;

        if (!runningMap[appId]) {
            runningMap[appId] = {
                toplevels: [],
                isActive: false
            };
            runningOrder.push(appId);
        }
        runningMap[appId].toplevels.push(toplevel);
        if (activeApp === appId || toplevel === activeToplevel || toplevel.active === true) {
            runningMap[appId].isActive = true;
        }
    }

    function enrichItem(base) {
        var entry = entryFor(appRows, base.appId);
        if (entry && appLibrary) {
            base.name = appLibrary.entryName(entry) || base.appId;
            base.icon = appLibrary.iconSource(entry.icon) || base.appId;
        } else {
            base.name = base.appId;
            base.icon = base.appId;
        }
        return base;
    }

    var items = [];
    var seen = {};

    // 1. Pinned Apps in specified order (skip if blacklisted)
    for (var j = 0; j < pinned.length; j++) {
        var pid = stripDesktop(pinned[j]);
        if (!pid || seen[pid]) continue;
        if (isBlacklisted(blacklistIds, pid)) continue;
        seen[pid] = true;

        var runInfo = runningMap[pid];
        var isRun = runInfo && runInfo.toplevels.length > 0;
        var item = {
            id: "pin_" + pid,
            appId: pid,
            appClass: pid,
            exec: pid,
            name: pid,
            icon: pid,
            isPinned: true,
            isRunning: isRun,
            isActive: isRun ? runInfo.isActive : false,
            windowCount: isRun ? runInfo.toplevels.length : 0,
            toplevels: isRun ? runInfo.toplevels : []
        };
        items.push(enrichItem(item));
    }

    // 2. Unpinned Running Apps in order of discovery
    for (var k = 0; k < runningOrder.length; k++) {
        var rid = runningOrder[k];
        if (seen[rid]) continue;
        if (isBlacklisted(blacklistIds, rid)) continue;
        seen[rid] = true;

        var rInfo = runningMap[rid];
        var unpinnedItem = {
            id: "run_" + rid,
            appId: rid,
            appClass: rid,
            exec: rid,
            name: rid,
            icon: rid,
            isPinned: false,
            isRunning: true,
            isActive: rInfo.isActive,
            windowCount: rInfo.toplevels.length,
            toplevels: rInfo.toplevels
        };
        items.push(enrichItem(unpinnedItem));
    }

    return items;
}
