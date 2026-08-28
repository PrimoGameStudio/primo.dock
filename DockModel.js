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
    iconSize: 38,
    itemSize: 80,
    padding: 48,
    hoverScale: 2,
    dragScale: 2,
    backgroundOpacity: 0.98,
    showRunningDots: true,
    showTooltips: true,
    showTooltipsDelay: 350,
    longPressDuration: 600,
    toggleWithBar: true,
    showVisualizer: true,
    visualizerBars: 32,
    monitor: "",
    floatingWindowScaleX: 0.75,
    floatingWindowScaleY: 0.75
};

var SETTINGS_CLAMPS = {
    iconSize: { min: 12, max: 128 },
    itemSize: { min: 24, max: 160 },
    padding: { min: 0, max: 48 },
    hoverScale: { min: 1.0, max: 2.0 },
    dragScale: { min: 1.0, max: 2.5 },
    backgroundOpacity: { min: 0.0, max: 1.0 },
    showTooltipsDelay: { min: 0, max: 5000 },
    longPressDuration: { min: 300, max: 2000 },
    visualizerBars: { min: 4, max: 64 },
    floatingWindowScaleX: { min: 0.1, max: 1.0 },
    floatingWindowScaleY: { min: 0.1, max: 1.0 }
};

function clampNumber(value, min, max, fallback) {
    var n = Number(value);
    if (!isFinite(n)) return fallback;
    return Math.max(min, Math.min(max, n));
}

var MAX_SETTINGS_SIZE = 65536;

function isSafeRaw(raw, maxSize) {
    if (raw == null) return true;
    var s = String(raw);
    if (s.length > maxSize) return false;
    if (s.indexOf("\u0000") !== -1) return false;
    return true;
}

function parseSettings(raw) {
    if (!isSafeRaw(raw, MAX_SETTINGS_SIZE)) return parseSettings("");
    var text = String(raw == null ? "" : raw).trim();
    if (text.length > MAX_SETTINGS_SIZE) return parseSettings("");
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
        if (key === "monitor" && (val === undefined || val === null || val === "")) {
            if (parsed["display"] !== undefined && parsed["display"] !== null) {
                val = parsed["display"];
            }
        }
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
    if (!isSafeRaw(raw, MAX_SETTINGS_SIZE)) return DEFAULT_BLACKLIST.slice();
    var text = String(raw == null ? "" : raw).trim();
    if (!text) return DEFAULT_BLACKLIST.slice();
    if (text.length > MAX_SETTINGS_SIZE) return DEFAULT_BLACKLIST.slice();

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
    if (!isSafeRaw(raw, MAX_SETTINGS_SIZE)) return DEFAULT_PINNED.slice();
    var text = String(raw == null ? "" : raw).trim();
    if (!text) return DEFAULT_PINNED.slice();
    if (text.length > MAX_SETTINGS_SIZE) return DEFAULT_PINNED.slice();

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

// Chromium --app windows expose ids/classes like "chrome-<host>__<path>-<profile>"
// (e.g. "chrome-www.facebook.com__-Default"). Their .desktop entries frequently
// don't exist, but the URL is fully recoverable from the id itself.
var WEBAPP_CLASS_RE = /^chrome-(.+)-([A-Za-z0-9]+)$/;

function isWebappClassId(appId) {
    var m = WEBAPP_CLASS_RE.exec(String(appId || ""));
    if (!m) return false;
    var body = m[1];
    var sep = body.indexOf("__");
    var host = sep >= 0 ? body.slice(0, sep) : body;
    return host.length > 0 && host.indexOf(".") > 0;
}

// Apps that accept a flag to force an additional window when relaunched.
// Single-instance apps without such a flag will still hand off / focus.
var NEW_INSTANCE_FLAGS = {
    "librewolf": "--new-window",
    "firefox": "--new-window",
    "firefox-esr": "--new-window",
    "chromium": "--new-window",
    "google-chrome": "--new-window",
    "brave-browser": "--new-window",
    "vivaldi-stable": "--new-window",
    "microsoft-edge": "--new-window"
};

function newInstanceFlag(appId) {
    return NEW_INSTANCE_FLAGS[String(appId || "").toLowerCase()] || "";
}

function webappUrlFromId(appId) {
    var m = WEBAPP_CLASS_RE.exec(String(appId || ""));
    if (!m) return "";
    var body = m[1];
    var sep = body.indexOf("__");
    var host = sep >= 0 ? body.slice(0, sep) : body;
    var path = sep >= 0 ? body.slice(sep + 2) : "";
    if (!host || host.indexOf(".") < 0) return "";
    var url = "https://" + host;
    if (path) url += "/" + path.replace(/_/g, "/");
    return url;
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

// Attach per-window metadata (workspace, monitor, focus priority) to a toplevel.
// Workspace/monitor come from the Quickshell HyprlandToplevel attached property.
function toplevelMeta(toplevel, focusedWorkspaceId, focusedMonitorName, pre) {
    var meta = {
        toplevel: toplevel,
        title: (toplevel && toplevel.title) ? toplevel.title : "",
        address: "",
        workspaceId: -1,
        workspaceName: "",
        monitorName: "",
        active: !!(toplevel && toplevel.activated),
        onFocusedWorkspace: false,
        onFocusedMonitor: false,
        minimized: !!(toplevel && toplevel.minimized)
    };
    // Preferred path: precomputed QML-side info (attached properties are not
    // readable from this library file). Legacy lookup kept as fallback.
    if (pre) {
        meta.address = String(pre.address || "");
        meta.workspaceId = (pre.workspaceId !== undefined) ? pre.workspaceId : -1;
        meta.workspaceName = String(pre.workspaceName || "");
        meta.monitorName = String(pre.monitorName || "");
    } else {
        try {
            var ht = toplevel ? toplevel.HyprlandToplevel : null;
            if (ht) {
                if (ht.address) meta.address = "0x" + String(ht.address);
                var ws = ht.workspace;
                if (ws) {
                    if (ws.id !== undefined) meta.workspaceId = ws.id;
                    if (ws.name) meta.workspaceName = String(ws.name);
                }
                var mon = ht.monitor;
                if (mon && mon.name) meta.monitorName = String(mon.name);
            }
        } catch (e) {}
    }
    if (focusedWorkspaceId !== undefined && meta.workspaceId === focusedWorkspaceId) {
        meta.onFocusedWorkspace = true;
    }
    if (focusedMonitorName && meta.monitorName === focusedMonitorName) {
        meta.onFocusedMonitor = true;
    }
    return meta;
}

// Stable sort: windows on the focused workspace first, then the focused monitor, then the rest.
function sortWindows(metas) {
    var arr = Array.isArray(metas) ? metas.slice() : [];
    function priority(m) {
        if (m && m.onFocusedWorkspace) return 0;
        if (m && m.onFocusedMonitor) return 1;
        return 2;
    }
    arr.sort(function(a, b) {
        return priority(a) - priority(b);
    });
    return arr;
}

// macOS-style rotation: next window after the currently active one (full cycle).
function nextWindowAfterActive(windows, activeToplevel) {
    var arr = Array.isArray(windows) ? windows : [];
    if (arr.length === 0) return null;
    if (arr.length === 1) return arr[0];
    var activeIdx = -1;
    for (var i = 0; i < arr.length; i++) {
        var m = arr[i];
        if (m.active || (activeToplevel && m.toplevel && m.toplevel === activeToplevel)) {
            activeIdx = i;
            break;
        }
    }
    if (activeIdx < 0) return arr[0];
    return arr[(activeIdx + 1) % arr.length];
}

// Step through windows by direction (+1/-1) for scroll-wheel cycling.
function cycleWindow(windows, activeToplevel, direction) {
    var arr = Array.isArray(windows) ? windows : [];
    if (arr.length === 0) return null;
    var activeIdx = -1;
    for (var i = 0; i < arr.length; i++) {
        var m = arr[i];
        if (m.active || (activeToplevel && m.toplevel && m.toplevel === activeToplevel)) {
            activeIdx = i;
            break;
        }
    }
    var step = direction > 0 ? 1 : -1;
    if (activeIdx < 0) {
        return step > 0 ? arr[0] : arr[arr.length - 1];
    }
    var next = activeIdx + step;
    if (next < 0) next = arr.length - 1;
    if (next >= arr.length) next = 0;
    return arr[next];
}

function buildDockItems(pinnedIds, blacklistIds, toplevels, activeToplevel, appRows, appLibrary, minimizedIds, focusedWorkspaceId, focusedMonitorName, minimizedAddrSet, minimizedClassTitleSet, toplevelInfos) {
    var pinned = Array.isArray(pinnedIds) ? pinnedIds : [];
    var list = toArray(toplevels);

    var minimizedSet = {};
    var minArr = Array.isArray(minimizedIds) ? minimizedIds : [];
    for (var mi = 0; mi < minArr.length; mi++) {
        var mid = stripDesktop(minArr[mi]);
        if (mid) minimizedSet[mid] = true;
    }
    function isMinimized(appId) {
        return minimizedSet[stripDesktop(appId)] === true;
    }

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
                raw: [],
                isActive: false
            };
            runningOrder.push(appId);
        }
        runningMap[appId].raw.push(toplevel);
        if (activeApp === appId || toplevel === activeToplevel || toplevel.activated === true) {
            runningMap[appId].isActive = true;
        }
    }

    // Build per-window metadata (sorted by focus priority) for each running app.
    var infoMap = new Map();
    if (toplevelInfos) {
        for (var ti = 0; ti < toplevelInfos.length; ti++) {
            var inf = toplevelInfos[ti];
            if (inf && inf.toplevel) infoMap.set(inf.toplevel, inf);
        }
    }
    for (var rk in runningMap) {
        var rinfo = runningMap[rk];
        var metas = [];
        for (var w = 0; w < rinfo.raw.length; w++) {
            var wm = toplevelMeta(rinfo.raw[w], focusedWorkspaceId, focusedMonitorName, infoMap.get(rinfo.raw[w]));
            // Per-window "parked on special:minimized" state. EXCLUSIVE sources:
            // address-carrying metas trust only the exact address match — the
            // class+title heuristic applies solely to address-less snapshots,
            // otherwise duplicate titles flip every sibling row's state.
            wm.isDocked = false;
            if (wm.address) {
                if (minimizedAddrSet) {
                    var bare = String(wm.address).toLowerCase().replace(/^0x/, "");
                    wm.isDocked = minimizedAddrSet[bare] === true;
                }
            } else if (minimizedClassTitleSet) {
                var ctKey = String(wm.toplevel ? wm.toplevel.appId : "") + "\u001f" + String(wm.title || "");
                wm.isDocked = minimizedClassTitleSet[ctKey] === true;
            }
            metas.push(wm);
        }
        rinfo.toplevels = rinfo.raw;
        rinfo.windows = sortWindows(metas);
        rinfo.hasMultipleWindows = rinfo.raw.length > 1;
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
            isMinimized: isRun && isMinimized(pid),
            windowCount: isRun ? runInfo.toplevels.length : 0,
            toplevels: isRun ? runInfo.toplevels : [],
            windows: isRun ? runInfo.windows : [],
            hasMultipleWindows: isRun ? runInfo.hasMultipleWindows : false
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
            isMinimized: isMinimized(rid),
            windowCount: rInfo.toplevels.length,
            toplevels: rInfo.toplevels,
            windows: rInfo.windows,
            hasMultipleWindows: rInfo.hasMultipleWindows
        };
        items.push(enrichItem(unpinnedItem));
    }

    // 3. Minimized Apps that are no longer visible in the toplevel list
    // (e.g. parked on a special workspace) so they can be restored from the dock
    for (var pid2 in minimizedSet) {
        if (seen[pid2] || isBlacklisted(blacklistIds, pid2)) continue;
        seen[pid2] = true;
        var minimizedItem = {
            id: "min_" + pid2,
            appId: pid2,
            appClass: pid2,
            exec: pid2,
            name: pid2,
            icon: pid2,
            isPinned: false,
            isRunning: true,
            isActive: false,
            isMinimized: true,
            windowCount: 0,
            toplevels: [],
            windows: [],
            hasMultipleWindows: false
        };
        items.push(enrichItem(minimizedItem));
    }

    return items;
}
