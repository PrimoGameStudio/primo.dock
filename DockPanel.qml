import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "DockModel.js" as DockModel
import "IconResolver.js" as IconResolver

Item {
    id: root

    // Properties injected by Omarchy Shell host
    property string omarchyPath: Quickshell.env("OMARCHY_PATH")
    property var shell: null
    property var manifest: null
    property var pluginRegistry: null

    // Dock state & Multi-source Live Bar Position Tracking
    property bool opened: true
    property bool pluginEnabled: true
    property string shellConfigPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    property string detectedBarPosition: "top"

    // Live bar position (only used to position the dock on the opposite side of the screen)
    property string barPosition: {
        if (shell && shell.bar && shell.bar.position) return shell.bar.position
        if (shell && shell.barConfig && shell.barConfig.position) return shell.barConfig.position
        return detectedBarPosition
    }
    readonly property bool isVertical: barPosition === "left" || barPosition === "right"

    // Direct IPC handler for primo.dock target
    IpcHandler {
        target: "primo.dock"
        function open() { root.open(""); return "ok" }
        function close() { root.close(); return "ok" }
        function toggle() { root.toggle(); return "ok" }
        function refresh() { return root.refresh() }
    }

    // Methods called by shell.summon / shell.hide / shell.toggle
    function open(payloadJson) {
        root.opened = true
    }

    function close() {
        root.opened = false
        root.activeMenuItem = null
        root.activeSystemItem = null
    }

    function toggle() {
        root.opened = !root.opened
        root.activeMenuItem = null
        root.activeSystemItem = null
    }

    // Standalone plugin lifecycle: enabled by default, disabled ONLY if in disabledPlugins
    function updatePluginEnabled() {
        root.pluginEnabled = true
    }

    FileView {
        id: shellConfigFile
        path: root.shellConfigPath
        watchChanges: true
        printErrors: false
        onLoaded: {
            root.updatePluginEnabled()
            try {
                var cfg = JSON.parse(text())
                if (cfg && cfg.bar && cfg.bar.position) {
                    root.detectedBarPosition = cfg.bar.position
                }
            } catch(e) {}
        }
        onFileChanged: {
            reload()
            root.updatePluginEnabled()
            try {
                var cfg = JSON.parse(text())
                if (cfg && cfg.bar && cfg.bar.position) {
                    root.detectedBarPosition = cfg.bar.position
                }
            } catch(e) {}
            root.refreshLayers()
        }
    }

    Connections {
        target: root.pluginRegistry ? root.pluginRegistry : (shell ? shell.pluginRegistry : null)
        ignoreUnknownSignals: true
        function onPluginsChanged() { root.updatePluginEnabled() }
    }

    // Safe compositor unmap-remap sequence on orientation shift or monitor standby/wake
    property bool forceRemap: false

    readonly property var targetScreen: {
        var mon = root.dockSettings.monitor
        var screens = Quickshell.screens || []
        if (!mon || mon === "primary") return screens.length > 0 ? screens[0] : null
        for (var i = 0; i < screens.length; i++) {
            if (screens[i].name === mon) return screens[i]
        }
        return screens.length > 0 ? screens[0] : null
    }

    readonly property var screenModel: {
        var mon = root.dockSettings.monitor
        var screens = Quickshell.screens || []
        if (mon === "all") return screens
        var s = root.targetScreen
        return s ? [s] : []
    }

    Connections {
        target: Quickshell
        function onScreensChanged() {
            root.forceRemap = true
            remapTimer.restart()
        }
    }

    Process {
        id: monitorSocketProc
        running: true
        command: ["bash", "-c", "socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/hyprland/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock 2>/dev/null || sleep infinity"]
        stdout: SplitParser {
            onRead: function(line) {
                var text = String(line).trim()
                if (text.indexOf("monitoradded") === 0 || text.indexOf("monitorremoved") === 0 || text.indexOf("dpms") === 0) {
                    root.forceRemap = true
                    remapTimer.restart()
                    root.refreshLayers()
                }
            }
        }
    }

    Timer {
        id: remapTimer
        interval: 150
        repeat: false
        onTriggered: {
            root.forceRemap = false
        }
    }

    onBarPositionChanged: {
        root.forceRemap = true
        remapTimer.restart()
    }

    // Periodic sync timer for guaranteed real-time layer alignment
    Timer {
        id: syncPollTimer
        interval: 1000
        repeat: true
        running: true
        onTriggered: {
            root.refreshLayers()
        }
    }

    // Real-time Bar Position detection via Hyprland layer shell
    Process {
        id: layersProc
        running: true
        command: ["hyprctl", "layers", "-j"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    var data = JSON.parse(text)
                    for (var mon in data) {
                        var levels = data[mon].levels || {}
                        for (var lvl in levels) {
                            var layers = levels[lvl] || []
                            for (var i = 0; i < layers.length; i++) {
                                var l = layers[i]
                                if (l.namespace === "omarchy-bar") {
                                    var newPos = (l.w < l.h) ? (l.x === 0 ? "left" : "right") : (l.y === 0 ? "top" : "bottom")
                                    if (root.detectedBarPosition !== newPos) {
                                        root.detectedBarPosition = newPos
                                    }
                                    return
                                }
                            }
                        }
                    }
                } catch(e) {}
            }
        }
    }

    function refreshLayers() {
        if (!layersProc.running) layersProc.running = true
    }

    // Dynamic system tiling border size & rounding
    property int systemBorderSize: 2
    property int systemRounding: Style.cornerRadius >= 0 ? Style.cornerRadius : 12

    // Single Active Right-Click Menu State & Precise Target Index
    property var activeMenuItem: null
    property int activeMenuItemIndex: 0
    readonly property bool isMenuOpen: activeMenuItem !== null

    // Desktop-file quick actions ([Desktop Action] sections) for the open app menu
    readonly property int maxMenuActions: 6
    property var activeMenuEntry: null
    property var activeMenuActions: []
    readonly property int menuActionRows: Math.min(root.activeMenuActions.length, root.maxMenuActions)

    // Single predicate for "this desktop action duplicates Open New Window"
    function isNewWindowAction(a) {
        if (!a) return false
        var idKey = String(a.id || "").toLowerCase().replace(/[-_.]/g, "")
        var nm = String(a.name || "").toLowerCase()
        return idKey.indexOf("newwindow") >= 0 || nm.indexOf("new window") === 0
    }

    // Index of the desktop action that duplicates "Open New Window" (merged into the ＋ row), else -1
    readonly property int newWindowActionIndex: {
        for (var i = 0; i < root.menuActionRows; i++) {
            if (root.isNewWindowAction(root.activeMenuActions[i])) return i
        }
        return -1
    }
    readonly property bool hasMergedNewWindowAction: root.newWindowActionIndex >= 0

    // "Windows" group (header + list) only appears once an app has two-plus windows
    readonly property bool showWindowList: !!root.activeMenuItem && root.activeMenuItem.isRunning === true
        && Number(root.activeMenuItem.windowCount) >= 2

    // Actions shown under the "Actions" header (excludes the merged new-window action)
    readonly property var listedMenuActions: {
        var acts = []
        for (var i = 0; i < root.menuActionRows; i++) {
            if (root.hasMergedNewWindowAction && i === root.newWindowActionIndex) continue
            acts.push(root.activeMenuActions[i])
        }
        return acts
    }

    // Resolve the .desktop entry + its actions whenever the app menu opens/closes
    onActiveMenuItemChanged: {
        if (!root.activeMenuItem) {
            root.activeMenuEntry = null
            root.activeMenuActions = []
            return
        }
        root.activeMenuEntry = root.resolveDesktopEntry(root.activeMenuItem)
        var de = root.activeMenuEntry
        root.activeMenuActions = (de && de.actions && de.actions.length > 0) ? de.actions : []
    }

    function resolveDesktopEntry(item) {
        try {
            var id = String((item && item.appId) || "")
            var de = id.length > 0 ? DesktopEntries.byId(id) : null
            if (!de && id.length > 0) de = DesktopEntries.heuristicLookup(id)
            var cls = String((item && item.appClass) || "")
            if (!de && cls.length > 0) de = DesktopEntries.heuristicLookup(cls)
            return (de && de.isValid && de.isValid()) ? de : (de || null)
        } catch (e) {
            return null
        }
    }

    // Launch a [Desktop Action] command under uwsm like every other launcher here.
    // entry: the DesktopEntry the action belongs to (for workingDirectory); when
    // omitted, falls back to the open app menu's resolved entry.
    function launchDesktopAction(action, entry) {
        if (!action || !action.command || action.command.length === 0) return
        var src = (entry !== undefined) ? entry : root.activeMenuEntry
        var cmd = ["uwsm-app", "--"]
        for (var i = 0; i < action.command.length; i++) cmd.push(String(action.command[i]))
        if (src && src.workingDirectory && String(src.workingDirectory).length > 0) {
            Quickshell.execDetached({ command: cmd, workingDirectory: String(src.workingDirectory) })
        } else {
            Quickshell.execDetached({ command: cmd })
        }
    }

    // Watch (≤6s) for the next NEW client of classHint and float + resize it.
    // Must be started BEFORE dispatching the launch so pre-existing windows
    // land in the baseline snapshot. Fresh Hyprland windows are tiled, so a
    // float toggle is deterministic; falls back to the core dispatcher.
    // After floating, the window is resized to floatingWindowScaleX/Y (default
    // 0.75 = 3/4 width + 3/4 height) and centered on its monitor (accounting
    // for monitor scale and global layout coordinates).
    function floatNextWindowOfClass(classHint) {
        var cls = String(classHint || "")
        if (!cls) return
        var ratioX = root.dockFloatingWindowScaleX
        var ratioY = root.dockFloatingWindowScaleY
        var itemSize = root.dockItemSize
        var script = "CLS=" + Util.shellQuote(cls) + "; RATIO_X=" + Util.shellQuote(String(ratioX)) + "; RATIO_Y=" + Util.shellQuote(String(ratioY)) + "; ITEM_SIZE=" + Util.shellQuote(String(itemSize)) + "; "
            + "BEFORE=$(hyprctl clients -j | jq -r '.[].address' | sort); "
            + "for i in $(seq 1 60); do "
            + "ADDR=$(hyprctl clients -j | jq -r --arg c \"$CLS\" '.[] | select(.class == $c) | .address' | sort | comm -13 <(printf '%s\\n' \"$BEFORE\") - | head -n1); "
            + "if [ -n \"$ADDR\" ]; then "
            + "hyprctl dispatch \"hl.dsp.window.float({ window = \\\"address:$ADDR\\\", action = \\\"toggle\\\" })\" 2>/dev/null; RC=$?; "
            + "[ $RC -ne 0 ] && { hyprctl dispatch \"togglefloating address:$ADDR\" 2>/dev/null; RC=$?; [ $RC -ne 0 ] && hyprctl dispatch \"togglefloating $ADDR\" 2>/dev/null; }; "
            + "for _ in 1 2 3 4 5; do FLOAT=$(hyprctl clients -j | jq -r --arg a \"$ADDR\" '.[] | select(.address==$a) | .floating'); if [ \"$FLOAT\" = \"true\" ]; then break; fi; sleep 0.1; done; "
            + "if [ \"$FLOAT\" != \"true\" ]; then exit 0; fi; "
            + "MON=$(hyprctl clients -j | jq -r --arg a \"$ADDR\" '.[] | select(.address==$a) | .monitor'); "
            + "MW=$(hyprctl monitors -j | jq -r --arg m \"$MON\" '.[] | select(.id==($m|tonumber)) | .width'); MH=$(hyprctl monitors -j | jq -r --arg m \"$MON\" '.[] | select(.id==($m|tonumber)) | .height'); MX=$(hyprctl monitors -j | jq -r --arg m \"$MON\" '.[] | select(.id==($m|tonumber)) | .x'); MY=$(hyprctl monitors -j | jq -r --arg m \"$MON\" '.[] | select(.id==($m|tonumber)) | .y'); SCALE=$(hyprctl monitors -j | jq -r --arg m \"$MON\" '.[] | select(.id==($m|tonumber)) | .scale'); "
            + "if [ -z \"$MW\" ] || [ \"$MW\" = \"null\" ] || [ -z \"$MH\" ] || [ \"$MH\" = \"null\" ]; then MW=$(hyprctl monitors -j | jq -r '.[] | select(.focused==true) | .width'); MH=$(hyprctl monitors -j | jq -r '.[] | select(.focused==true) | .height'); MX=$(hyprctl monitors -j | jq -r '.[] | select(.focused==true) | .x'); MY=$(hyprctl monitors -j | jq -r '.[] | select(.focused==true) | .y'); SCALE=$(hyprctl monitors -j | jq -r '.[] | select(.focused==true) | .scale'); fi; "
            + "if [ -z \"$SCALE\" ] || [ \"$SCALE\" = \"null\" ]; then SCALE=1; fi; "
            + "if [ -n \"$MW\" ] && [ -n \"$MH\" ] && [ \"$MW\" != \"null\" ] && [ \"$MH\" != \"null\" ]; then "
            + "NW=$(awk -v mw=\"$MW\" -v s=\"$SCALE\" -v r=\"$RATIO_X\" 'BEGIN{printf \"%d\", mw/s*r}'); NH=$(awk -v mh=\"$MH\" -v s=\"$SCALE\" -v r=\"$RATIO_Y\" 'BEGIN{printf \"%d\", mh/s*r}'); MWL=$(awk -v mw=\"$MW\" -v s=\"$SCALE\" 'BEGIN{printf \"%d\", mw/s}'); MHL=$(awk -v mh=\"$MH\" -v s=\"$SCALE\" 'BEGIN{printf \"%d\", mh/s}'); "
            + "NX=$((MX + (MWL - NW)/2)); NY=$((MY + (MHL - NH)/2 - ITEM_SIZE/2)); "
            + "hyprctl dispatch \"hl.dsp.window.resize({ window = \\\"address:$ADDR\\\", x = $NW, y = $NH })\" 2>/dev/null; "
            + "sleep 0.05; "
            + "hyprctl dispatch \"hl.dsp.window.move({ window = \\\"address:$ADDR\\\", x = $NX, y = $NY })\" 2>/dev/null; "
            + "fi; "
            + "exit 0; fi; "
            + "sleep 0.1; done"
        Util.execDetached("bash -c " + Util.shellQuote(script))
    }

    // Resize a known floating window to floatingWindowScaleX/Y and center it.
    // Called after a successful tiled->floating toggle so existing windows
    // also obey the 3/4 monitor sizing (with monitor scale correction).
    function resizeFloatingWindow(addr) {
        var a = String(addr || "")
        if (!a) return
        var ratioX = root.dockFloatingWindowScaleX
        var ratioY = root.dockFloatingWindowScaleY
        var itemSize = root.dockItemSize
        var script = "ADDR=" + Util.shellQuote(a) + "; RATIO_X=" + Util.shellQuote(String(ratioX)) + "; RATIO_Y=" + Util.shellQuote(String(ratioY)) + "; ITEM_SIZE=" + Util.shellQuote(String(itemSize)) + "; "
            + "for _ in 1 2 3 4 5; do FLOAT=$(hyprctl clients -j | jq -r --arg a \"$ADDR\" '.[] | select(.address==$a) | .floating'); if [ \"$FLOAT\" = \"true\" ]; then break; fi; sleep 0.1; done; "
            + "if [ \"$FLOAT\" != \"true\" ]; then exit 0; fi; "
            + "MON=$(hyprctl clients -j | jq -r --arg a \"$ADDR\" '.[] | select(.address==$a) | .monitor'); "
            + "MW=$(hyprctl monitors -j | jq -r --arg m \"$MON\" '.[] | select(.id==($m|tonumber)) | .width'); MH=$(hyprctl monitors -j | jq -r --arg m \"$MON\" '.[] | select(.id==($m|tonumber)) | .height'); MX=$(hyprctl monitors -j | jq -r --arg m \"$MON\" '.[] | select(.id==($m|tonumber)) | .x'); MY=$(hyprctl monitors -j | jq -r --arg m \"$MON\" '.[] | select(.id==($m|tonumber)) | .y'); SCALE=$(hyprctl monitors -j | jq -r --arg m \"$MON\" '.[] | select(.id==($m|tonumber)) | .scale'); "
            + "if [ -z \"$MW\" ] || [ \"$MW\" = \"null\" ] || [ -z \"$MH\" ] || [ \"$MH\" = \"null\" ]; then MW=$(hyprctl monitors -j | jq -r '.[] | select(.focused==true) | .width'); MH=$(hyprctl monitors -j | jq -r '.[] | select(.focused==true) | .height'); MX=$(hyprctl monitors -j | jq -r '.[] | select(.focused==true) | .x'); MY=$(hyprctl monitors -j | jq -r '.[] | select(.focused==true) | .y'); SCALE=$(hyprctl monitors -j | jq -r '.[] | select(.focused==true) | .scale'); fi; "
            + "if [ -z \"$SCALE\" ] || [ \"$SCALE\" = \"null\" ]; then SCALE=1; fi; "
            + "if [ -z \"$MW\" ] || [ -z \"$MH\" ] || [ \"$MW\" = \"null\" ] || [ \"$MH\" = \"null\" ]; then exit 0; fi; "
            + "NW=$(awk -v mw=\"$MW\" -v s=\"$SCALE\" -v r=\"$RATIO_X\" 'BEGIN{printf \"%d\", mw/s*r}'); NH=$(awk -v mh=\"$MH\" -v s=\"$SCALE\" -v r=\"$RATIO_Y\" 'BEGIN{printf \"%d\", mh/s*r}'); MWL=$(awk -v mw=\"$MW\" -v s=\"$SCALE\" 'BEGIN{printf \"%d\", mw/s}'); MHL=$(awk -v mh=\"$MH\" -v s=\"$SCALE\" 'BEGIN{printf \"%d\", mh/s}'); "
            + "NX=$((MX + (MWL - NW)/2)); NY=$((MY + (MHL - NH)/2 - ITEM_SIZE/2)); "
            + "hyprctl dispatch \"hl.dsp.window.resize({ window = \\\"address:$ADDR\\\", x = $NW, y = $NH })\" 2>/dev/null; "
            + "sleep 0.05; "
            + "hyprctl dispatch \"hl.dsp.window.move({ window = \\\"address:$ADDR\\\", x = $NX, y = $NY })\" 2>/dev/null; "
        Util.execDetached("bash -c " + Util.shellQuote(script))
    }

    // Unified "Open New Window" semantics shared by middle-click and the ＋ row:
    // prefer the app's own [Desktop Action new-window] command when defined,
    // otherwise force a brand-new instance via the launchApp chain.
    function openNewWindowForItem(item, superHeld) {
        var de = root.resolveDesktopEntry(item)
        if (superHeld && item) root.floatNextWindowOfClass(String(item.appId || ""))
        var acts = (de && de.actions) ? de.actions : []
        var cap = Math.min(acts.length, root.maxMenuActions)
        for (var i = 0; i < cap; i++) {
            if (root.isNewWindowAction(acts[i])) {
                root.launchDesktopAction(acts[i], de)
                return
            }
        }
        root.launchApp(item, true)
    }

    // Super+right-click / Super+long-press System menu state (mutually exclusive with app menu)
    property var activeSystemItem: null
    property int activeSystemItemIndex: 0
    readonly property bool isSystemMenuOpen: activeSystemItem !== null

    // Index of whichever action menu is currently open (used for icon-centered geometry)
    readonly property int menuPositioningIndex: root.isMenuOpen ? root.activeMenuItemIndex : root.activeSystemItemIndex

    // Blank Space Context Menu State
    property bool isDockMenuOpen: false

    // Exact geometric coordinate centering for the overlay menu
    readonly property real calculatedMenuLeft: {
        var s = root.targetScreen
        var screenW = s ? s.width : 1920
        var dockW = root.isVertical ? root.dockWindowThickness : root.dockSurfaceLength
        var dockLeft = (screenW - dockW) / 2
        var iconCenterX = root.isVertical
            ? dockLeft + root.dockWindowThickness / 2
            : dockLeft + (root.dockWindowLength - root.dockContentLength) / 2 + root.menuPositioningIndex * root.dockItemSize + (root.dockItemSize - 4) / 2
        var menuW = 230
        var targetLeft = iconCenterX - menuW / 2
        return Math.round(Math.max(6, Math.min(screenW - menuW - 6, targetLeft)))
    }

    readonly property real calculatedMenuTop: {
        var s = root.targetScreen
        var screenH = s ? s.height : 1080
        var dockH = root.isVertical ? root.dockSurfaceLength : root.dockWindowThickness
        var dockTop = (screenH - dockH) / 2
        var iconCenterY = root.isVertical
            ? dockTop + (root.dockWindowLength - root.dockContentLength) / 2 + root.menuPositioningIndex * root.dockItemSize + (root.dockItemSize - 4) / 2
            : dockTop + root.dockWindowThickness / 2
        var menuH = root.isMenuOpen ? root.actionMenuHeight : root.systemMenuHeight
        var targetTop = iconCenterY - menuH / 2
        return Math.round(Math.max(6, Math.min(screenH - menuH - 6, targetTop)))
    }

    Process {
        id: borderSizeProc
        running: true
        command: ["hyprctl", "getoption", "general:border_size", "-j"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    var parsed = JSON.parse(text)
                    if (parsed && parsed.int !== undefined && parsed.int > 0) {
                        root.systemBorderSize = parsed.int
                    }
                } catch(e) {}
            }
        }
    }

    Process {
        id: roundingProc
        running: true
        command: ["hyprctl", "getoption", "decoration:rounding", "-j"]
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                try {
                    var parsed = JSON.parse(text)
                    if (parsed && parsed.int !== undefined && parsed.int >= 0) {
                        root.systemRounding = parsed.int
                    }
                } catch(e) {}
            }
        }
    }

    function refresh() {
        var docText = userSettingsFile.text() || ""
        root.dockSettings = DockModel.parseSettings(docText)
        root.pinnedIds = DockModel.parsePinned(docText)
        root.blacklistIds = DockModel.parseBlacklist(docText)
        IconResolver.loadCustomIcons(root.extractCustomIcons(docText))
        root.refreshLayers()
        root.updatePluginEnabled()
        root.updateDockItems()
        return "ok"
    }

    // Minimized window tracking (windows parked on the special:minimized workspace)
    property var minimizedIds: []
    property var minimizedAddrs: ({})
    property var minimizedClassTitles: ({})

    Process {
        id: minimizedProbe
        property var pendingClasses: []
        property var pendingAddrs: []
        property var pendingClassTitles: []
        command: ["bash", "-c", "hyprctl clients -j | jq -r '.[] | select(.workspace.name == \"special:minimized\") | .class + \"\\t\" + .address + \"\\t\" + (.title // \"\")'"]
        stdout: SplitParser {
            onRead: function(line) {
                var value = String(line).trim()
                if (!value || value.length === 0) return
                // class <TAB> address <TAB> title(title may itself contain tabs -> keep the remainder)
                var parts = value.split("\t")
                minimizedProbe.pendingClasses.push(parts[0] || "")
                // Normalize to bare lowercase hex so it matches snapshot meta.address values
                var addr = String(parts[1] || "").toLowerCase().replace(/^0x/, "")
                if (addr.length > 0) minimizedProbe.pendingAddrs.push(addr)
                var title = parts.slice(2).join("\t")
                minimizedProbe.pendingClassTitles.push(String(parts[0] || "") + "\u001f" + title)
            }
        }
        onExited: function(exitCode, exitStatus) {
            var nextClasses = minimizedProbe.pendingClasses.slice()
            var nextAddrsMap = {}
            for (var i = 0; i < minimizedProbe.pendingAddrs.length; i++) {
                nextAddrsMap[minimizedProbe.pendingAddrs[i]] = true
            }
            var nextCTMap = {}
            for (var j = 0; j < minimizedProbe.pendingClassTitles.length; j++) {
                nextCTMap[minimizedProbe.pendingClassTitles[j]] = true
            }
            minimizedProbe.pendingClasses = []
            minimizedProbe.pendingAddrs = []
            minimizedProbe.pendingClassTitles = []
            if (!root.arraysEqual(root.minimizedIds, nextClasses)) {
                root.minimizedIds = nextClasses
            }
            if (JSON.stringify(root.minimizedAddrs) !== JSON.stringify(nextAddrsMap)) {
                root.minimizedAddrs = nextAddrsMap
            }
            if (JSON.stringify(root.minimizedClassTitles) !== JSON.stringify(nextCTMap)) {
                root.minimizedClassTitles = nextCTMap
            }
        }
    }

    function arraysEqual(a, b) {
        if (!Array.isArray(a) || !Array.isArray(b)) return a === b
        if (a.length !== b.length) return false
        var set = {}
        for (var i = 0; i < a.length; i++) set[a[i]] = true
        for (var j = 0; j < b.length; j++) if (!set[b[j]]) return false
        return true
    }

    function refreshMinimized() {
        minimizedProbe.pendingClasses = []
        minimizedProbe.pendingAddrs = []
        minimizedProbe.running = true
    }

    onMinimizedIdsChanged: updateDockItems()
    onMinimizedAddrsChanged: updateDockItems()
    onMinimizedClassTitlesChanged: updateDockItems()

    // All persistent state lives in primo.dock-settings.json (single FileView)
    property var pinnedIds: []
    property var blacklistIds: []
    property var dockItems: []
    property var appRows: (shell && shell.appLibrary) ? shell.appLibrary.sortedEntries("") : []

    // Bar hidden state for "toggleWithBar"
    property bool barHidden: false

    Process {
        id: barHiddenProbe
        running: true
        command: ["bash", "-c", "[[ -f $HOME/.local/state/omarchy/toggles/bar-off ]] && echo yes || echo no"]
        stdout: SplitParser { onRead: function(line) { root.barHidden = String(line).trim() === "yes" } }
    }
    FileView {
        id: barOffFile
        path: Quickshell.env("HOME") + "/.local/state/omarchy/toggles/bar-off"
        watchChanges: true
        printErrors: false
        onLoaded: barHiddenProbe.running = true
        onLoadFailed: barHiddenProbe.running = true
        onFileChanged: barHiddenProbe.running = true
    }

    Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: {
            barHiddenProbe.running = true
            root.refreshMinimized()
            root.refreshTitlesIfDrifted()
        }
    }

    // Basic dock settings + pinned apps persistence (~/.config/omarchy/primo.dock-settings.json)
    property string settingsPath: Quickshell.env("HOME") + "/.config/omarchy/primo.dock-settings.json"
    property var dockSettings: DockModel.DEFAULT_SETTINGS

    readonly property int dockItemSize: Number(dockSettings.itemSize) || 80
    readonly property int dockIconSize: Number(dockSettings.iconSize) || 38
    readonly property int dockPadding: Number(dockSettings.padding) || 48
    readonly property real dockHoverScale: Number(dockSettings.hoverScale) || 2
    readonly property real dockDragScale: Number(dockSettings.dragScale) || 2
    readonly property real dockBackgroundOpacity: Number(dockSettings.backgroundOpacity) || 0.98
    readonly property bool dockShowRunningDots: dockSettings.showRunningDots !== false
    readonly property bool dockShowTooltips: dockSettings.showTooltips !== false
    readonly property int dockLongPressDuration: Number(dockSettings.longPressDuration) || 600
    readonly property bool dockToggleWithBar: dockSettings.toggleWithBar !== false
    readonly property bool dockShowVisualizer: dockSettings.showVisualizer !== false
    readonly property int dockVisualizerBars: Number(dockSettings.visualizerBars) || 32
    readonly property real dockFloatingWindowScaleX: {
        var v = Number(dockSettings.floatingWindowScaleX)
        if (!isFinite(v)) return 0.75
        return Math.max(0.1, Math.min(1.0, v))
    }
    readonly property real dockFloatingWindowScaleY: {
        var v = Number(dockSettings.floatingWindowScaleY)
        if (!isFinite(v)) return 0.75
        return Math.max(0.1, Math.min(1.0, v))
    }

    // Cava audio visualizer process & data array
    property var visualizerLevels: []

    Process {
        id: cavaProc
        running: root.pluginEnabled && root.dockShowVisualizer
        command: ["bash", "-c", "config_file=$(mktemp); trap 'rm -f \"$config_file\"' EXIT; echo -e '[general]\\nbars = " + root.dockVisualizerBars + "\\n[output]\\nmethod = raw\\nraw_target = /dev/stdout\\ndata_format = ascii\\nascii_max_range = 100' > \"$config_file\"; exec cava -p \"$config_file\""]
        stdout: SplitParser {
            onRead: function(line) {
                var text = String(line).trim()
                if (!text) return
                var parts = text.split(";")
                var nums = []
                for (var i = 0; i < parts.length; i++) {
                    var n = Number(parts[i])
                    if (!isNaN(n)) {
                        nums.push(n / 100.0)
                    }
                }
                if (nums.length > 0) {
                    root.visualizerLevels = nums
                }
            }
        }
    }

    // Currently hovered item tracking for tooltips
    property var hoveredItemData: null
    property int hoveredItemIndex: -1

    Timer {
        id: tooltipDelayTimer
        interval: Number(dockSettings.showTooltipsDelay) || 350
        repeat: false
        property var pendingData: null
        property int pendingIndex: -1
        onTriggered: {
            root.hoveredItemData = pendingData
            root.hoveredItemIndex = pendingIndex
        }
    }

    // Derived dock card geometry (itemSize slots + padding, 2px antialiasing buffer)
    readonly property real dockWindowThickness: dockItemSize + 2
    readonly property real dockSurfaceThickness: dockItemSize - 2
    readonly property real dockContentThickness: dockItemSize - 4
    readonly property real dockWindowLength: root.itemsCount * dockItemSize + dockPadding + 4
    readonly property real dockSurfaceLength: root.itemsCount * dockItemSize + dockPadding
    readonly property real dockContentLength: root.itemsCount * dockItemSize + dockPadding - 10

    // QML-side snapshot of Hyprland per-window data. Attached properties
    // (toplevel.HyprlandToplevel) only resolve inside import context —
    // DockModel.js (.pragma library) cannot read them, so we precompute here.
    property var toplevelInfos: []

    function computeToplevelInfos() {
        var tops = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
        var infos = []
        for (var i = 0; i < tops.length; i++) {
            var t = tops[i]
            var ht = t ? t.HyprlandToplevel : null
            var addr = (ht && ht.address) ? String(ht.address) : ""
            if (addr.length > 0 && addr.indexOf("0x") !== 0) addr = "0x" + addr
            var ws = ht ? ht.workspace : null
            var mon = ht ? ht.monitor : null
            infos.push({
                toplevel: t,
                title: (t && t.title) ? String(t.title) : "",
                address: addr,
                workspaceId: (ws && ws.id !== undefined) ? ws.id : -1,
                workspaceName: (ws && ws.name) ? String(ws.name) : "",
                monitorName: (mon && mon.name) ? String(mon.name) : ""
            })
        }
        return infos
    }

    // Titles (and lazily-reported Hyprland fields) settle AFTER a window opens;
    // nothing else fires a rebuild when only they change, so poll for drift.
    function refreshTitlesIfDrifted() {
        if (!root.toplevelInfos || root.toplevelInfos.length === 0) return
        if (!root.toplevelInfosMatch(computeToplevelInfos(), root.toplevelInfos)) {
            root.updateDockItems()
        }
    }

    function toplevelInfosMatch(a, b) {
        if (!Array.isArray(a) || !Array.isArray(b)) return false
        if (a.length !== b.length) return false
        for (var i = 0; i < a.length; i++) {
            var x = a[i] || {}
            var y = b[i] || {}
            if (x.toplevel !== y.toplevel) return false
            if (x.title !== y.title) return false
            if (x.address !== y.address) return false
            if (x.workspaceId !== y.workspaceId) return false
            if (x.workspaceName !== y.workspaceName) return false
            if (x.monitorName !== y.monitorName) return false
        }
        return true
    }

    function updateDockItems() {
        root.toplevelInfos = computeToplevelInfos()
        var toplevels = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
        var active = ToplevelManager.activeToplevel
        var lib = shell ? shell.appLibrary : null
        var fws = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : undefined
        var fmon = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
        root.dockItems = DockModel.buildDockItems(root.pinnedIds, root.blacklistIds, toplevels, active, root.appRows, lib, root.minimizedIds, fws, fmon, root.minimizedAddrs, root.minimizedClassTitles, root.toplevelInfos)
        rebindOpenMenusToFreshItems()
    }

    // Locate an open menu's target inside a freshly built dockItems array so the
    // open card tracks live data instead of a stale snapshot (frozen titles,
    // window counts, pill states). Matched by stable id, then appId.
    function findRebuiltItem(oldItem) {
        if (!oldItem) return null
        for (var i = 0; i < root.dockItems.length; i++) {
            if (root.dockItems[i] && root.dockItems[i].id === oldItem.id) return root.dockItems[i]
        }
        for (var j = 0; j < root.dockItems.length; j++) {
            if (root.dockItems[j] && root.dockItems[j].appId === oldItem.appId) return root.dockItems[j]
        }
        return null
    }

    function rebindOpenMenusToFreshItems() {
        if (root.activeMenuItem) {
            var next = findRebuiltItem(root.activeMenuItem)
            if (next !== root.activeMenuItem) {
                root.activeMenuItemIndex = root.dockItems.indexOf(next)
                // Retriggering onActiveMenuItemChanged also refreshes desktop-action data;
                // assigning null (app gone) closes the card via isMenuOpen
                root.activeMenuItem = next
            }
        }
        if (root.activeSystemItem) {
            var sysNext = findRebuiltItem(root.activeSystemItem)
            if (sysNext !== root.activeSystemItem) {
                root.activeSystemItemIndex = root.dockItems.indexOf(sysNext)
                root.activeSystemItem = sysNext
            }
        }
    }

    onPinnedIdsChanged: updateDockItems()
    onBlacklistIdsChanged: updateDockItems()
    onAppRowsChanged: updateDockItems()
    onShellChanged: {
        root.appRows = (shell && shell.appLibrary) ? shell.appLibrary.sortedEntries("") : []
        root.updateDockItems()
    }

    Connections {
        target: ToplevelManager.toplevels
        function onValuesChanged() { root.updateDockItems() }
    }

    Connections {
        target: ToplevelManager
        function onActiveToplevelChanged() { root.updateDockItems() }
    }

    Connections {
        target: Hyprland
        function onFocusedWorkspaceChanged() { root.updateDockItems() }
        function onFocusedMonitorChanged() { root.updateDockItems() }
    }

    Connections {
        target: shell ? shell.appLibrary : null
        enabled: target !== null
        function onAppsChanged() {
            root.appRows = shell.appLibrary.sortedEntries("")
            root.updateDockItems()
        }
    }

    // Pinned apps live inside primo.dock-settings.json under "pinned"
    // (single FileView: userSettingsFile)

    FileView {
        id: userSettingsFile
        path: root.settingsPath
        watchChanges: true
        atomicWrites: true
        printErrors: false
        onLoaded: {
            var doc = text()
            root.dockSettings = DockModel.parseSettings(doc)
            // Pinned apps ride in the same document under "pinned"
            root.pinnedIds = DockModel.parsePinned(doc)
            // So do the blacklist and custom icon overrides
            root.blacklistIds = DockModel.parseBlacklist(doc)
            IconResolver.loadCustomIcons(root.extractCustomIcons(doc))
            root.updateDockItems()
        }
        onLoadFailed: {
            root.dockSettings = DockModel.parseSettings("")
            root.pinnedIds = DockModel.DEFAULT_PINNED.slice()
            root.blacklistIds = DockModel.DEFAULT_BLACKLIST.slice()
            IconResolver.loadCustomIcons({})
            root.saveDockState()
            root.updateDockItems()
        }
        onFileChanged: userSettingsFile.reload()
    }

    function saveCustomIcons() {
        root.saveDockState()
    }

    // Single atomic write covering settings, pinned, blacklist and icon overrides
    function saveDockState() {
        var doc = {}
        try { doc = JSON.parse(DockModel.serializeSettings(root.dockSettings)) } catch (e) {}
        doc.pinned = JSON.parse(DockModel.serializePinned(root.pinnedIds)).pinned
        doc.blacklist = JSON.parse(DockModel.serializeBlacklist(root.blacklistIds)).blacklist
        doc.customIcons = IconResolver.allCustomIcons()
        userSettingsFile.setText(JSON.stringify(doc, null, 2) + "\n")
    }

    // Extract the flat appId→icon map from a merged state document
    function extractCustomIcons(docText) {
        try {
            var d = JSON.parse(docText || "{}")
            return (d && d.customIcons && typeof d.customIcons === "object") ? d.customIcons : {}
        } catch (e) {
            return {}
        }
    }

    // Kept as aliases: many call sites persist one section, but state is
    // stored in a single document
    function saveSettings() {
        root.saveDockState()
    }

    function savePinned() {
        root.saveDockState()
    }

    function setPinned(next) {
        root.pinnedIds = next
        root.savePinned()
        root.updateDockItems()
    }

    function saveBlacklist() {
        root.saveDockState()
    }

    function setBlacklist(next) {
        root.blacklistIds = next
        root.saveBlacklist()
        root.updateDockItems()
    }

    // Minimize an app to the dock (park all its windows on the special:minimized workspace)
    function minimizeItem(item) {
        if (!item || !item.appId) return
        var metas = (item.windows && item.windows.length) ? item.windows : []
        var dispatched = false
        for (var i = 0; i < metas.length; i++) {
            var addr = metas[i] ? metas[i].address : ""
            if (!addr) continue
            var lua = 'hl.dsp.window.move({ workspace = "special:minimized", follow = false, window = "address:' + addr + '" })'
            Util.execDetached("hyprctl dispatch " + Util.shellQuote(lua))
            dispatched = true
        }
        if (!dispatched) {
            // Fallback: no per-window addresses available — move the first matching window by class
            var luaFallback = 'hl.dsp.window.move({ workspace = "special:minimized", follow = false, window = "class:' + item.appId + '" })'
            Util.execDetached("hyprctl dispatch " + Util.shellQuote(luaFallback))
        }
        root.refreshMinimized()
    }

    // Restore a minimized app back to the current workspace and focus one of its windows
    function restoreItem(item) {
        if (!item || !item.appId) return
        var script = "ACTIVE=$(hyprctl activeworkspace -j | jq -r .id); "
            + "ADDRS=$(hyprctl clients -j | jq -r '.[] | select(.workspace.name == \"special:minimized\" and .class == \""
            + item.appId + "\") | .address'); "
            + "last=\"\"; "
            + "for addr in $ADDRS; do "
            + "last=\"$addr\"; "
            + "hyprctl dispatch \"hl.dsp.window.move({ workspace = $ACTIVE, follow = false, window = \\\"address:$addr\\\" })\" >/dev/null 2>&1; "
            + "done; "
            + "if [ -n \"$last\" ]; then "
            + "hyprctl dispatch \"hl.dsp.window.move({ workspace = $ACTIVE, follow = true, window = \\\"address:$last\\\" })\" >/dev/null 2>&1; "
            + "fi"
        Util.execDetached("bash -c " + Util.shellQuote(script))
        root.refreshMinimized()
    }

    // Launch a fresh instance of an app (used by middle-click and the action card)
    // Launch an app. forceNew=true (middle-click / "Open New Window") bypasses
    // focus-or-launch helpers so a genuinely new instance is requested.
    function launchApp(item, forceNew) {
        if (!item || !item.appId) return
        // Chromium --app ids (chrome-<host>__<path>-<profile>) usually have no
        // .desktop entry — relaunch via the URL the class encodes instead
        var appId = String(item.appId)
        if (!DesktopEntries.byId(appId) && DockModel.isWebappClassId(appId)) {
            var url = DockModel.webappUrlFromId(appId)
            if (url.length > 0) {
                if (forceNew) {
                    Util.execDetached(root.omarchyPath + "/bin/omarchy-launch-webapp " + Util.shellQuote(url))
                } else {
                    Util.execDetached(root.omarchyPath + "/bin/omarchy-launch-or-focus-webapp "
                        + Util.shellQuote(appId) + " " + Util.shellQuote(url))
                }
                return
            }
        }
        // Known multi-instance-capable apps get their new-window flag injected.
        // The "--" terminator is required: gtk-launch's GOption parser rejects
        // unknown flags (exit before launch) unless they follow it.
        if (forceNew) {
            var flag = DockModel.newInstanceFlag(appId)
            if (flag) {
                Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(appId + ".desktop") + " -- " + Util.shellQuote(flag))
                return
            }
        }
        if (root.shell && root.shell.appLibrary && typeof root.shell.appLibrary.launch === "function") {
            root.shell.appLibrary.launch(item.appId, item.name)
        } else {
            var target = item.appId ? (item.appId + ".desktop") : (item.exec + ".desktop")
            Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(target) + " || uwsm-app -- " + item.exec)
        }
    }

    // Close a single window (per-window ✕ / "Close Window" action)
    function closeWindow(meta) {
        if (!meta || !meta.toplevel) return
        if (meta.toplevel.close) meta.toplevel.close()
        root.activeMenuItem = null
    }

    // Close every window of an app ("Close All Windows" action)
    function closeAllWindows(item) {
        if (!item || !item.toplevels) return
        for (var t = 0; t < item.toplevels.length; t++) {
            if (item.toplevels[t].close) item.toplevels[t].close()
        }
        root.activeMenuItem = null
    }

    // Active window of an app (falls back to the first listed window)
    function activeWindowOf(item) {
        if (!item || !item.windows) return null
        var wins = item.windows
        for (var i = 0; i < wins.length; i++) {
            if (wins[i].active) return wins[i]
        }
        return wins.length > 0 ? wins[0] : null
    }

    // Park a single window on the special:minimized workspace.
    // Snapshot addresses can be empty/stale (HyprlandToplevel association timing),
    // so fall back to resolving the window live via hyprctl (class + title match).
    function minimizeWindow(meta) {
        if (!meta || !meta.toplevel) return
        if (meta.address) {
            var lua = 'hl.dsp.window.move({ workspace = "special:minimized", follow = false, window = "address:' + meta.address + '" })'
            Util.execDetached("hyprctl dispatch " + Util.shellQuote(lua))
        } else {
            var cls = String(meta.toplevel.appId || "")
            var ttl = String(meta.title || "")
            var script = "ADDR=$(hyprctl clients -j | jq -r --arg c " + Util.shellQuote(cls) + " --arg t " + Util.shellQuote(ttl)
                + " 'first(.[] | select(.class == $c and .title == $t and .workspace.name != \"special:minimized\") | .address) // empty' | head -n1); "
                + "[ -n \"$ADDR\" ] && hyprctl dispatch \"hl.dsp.window.move({ workspace = \\\"special:minimized\\\", follow = false, window = \\\"address:$ADDR\\\" })\""
            Util.execDetached("bash -c " + Util.shellQuote(script))
        }
        root.refreshMinimized()
        root.activeMenuItem = null
    }

    // Bring a single parked window back to the focused workspace and focus it
    function restoreWindow(meta) {
        if (!meta || !meta.toplevel) return
        var wsId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : 1
        if (meta.address) {
            var lua = 'hl.dsp.window.move({ workspace = ' + Number(wsId) + ', follow = true, window = "address:' + meta.address + '" })'
            Util.execDetached("hyprctl dispatch " + Util.shellQuote(lua))
        } else {
            var cls = String(meta.toplevel.appId || "")
            var ttl = String(meta.title || "")
            var script = "ADDR=$(hyprctl clients -j | jq -r --arg c " + Util.shellQuote(cls) + " --arg t " + Util.shellQuote(ttl)
                + " 'first(.[] | select(.class == $c and .title == $t and .workspace.name == \"special:minimized\") | .address) // empty' | head -n1); "
                + "[ -n \"$ADDR\" ] && hyprctl dispatch \"hl.dsp.window.move({ workspace = $ACTIVE, follow = true, window = \\\"address:$ADDR\\\" })\""
            var full = "ACTIVE=$(hyprctl activeworkspace -j | jq -r .id); " + script
            Util.execDetached("bash -c " + Util.shellQuote(full))
        }
        root.refreshMinimized()
        root.activeMenuItem = null
    }

    // Activate a specific window from the window list.
    // Docked (special:minimized) windows must be restored off the hidden workspace —
    // a bare activate() would make Hyprland switch to that workspace instead.
    // isDocked is probe-derived; toplevel.minimized does NOT reflect special workspaces.
    function activateWindow(meta) {
        if (!meta || !meta.toplevel) return
        if (meta.isDocked) {
            root.restoreWindow(meta)
            return
        }
        if (meta.toplevel.activate) meta.toplevel.activate()
        root.activeMenuItem = null
    }

    // Scrollable window-list rows (capped at 8)
    readonly property int winListRows: {
        var item = root.activeMenuItem
        if (!item || !item.isRunning || !item.windows || !root.showWindowList) return 0
        return Math.min(8, item.windows.length)
    }

    // Total action-card height accounting for the window list (exact ColumnLayout fit)
    readonly property real actionMenuHeight: {
        var item = root.activeMenuItem
        var sum = 32 * 1 // new window
        var n = 1
        sum += 26 // "Actions" header (always shown above new window)
        n += 1
        if (item && item.isRunning) {
            sum += 32 // close window OR close all windows (mutually exclusive rows)
            n += 1
            sum += 32 // minimize
            n += 1
            if (root.showWindowList) {
                sum += 26 // "Windows" header
                n += 1
                sum += root.winListRows * 26 // window list
                n += 1
            }
        }
        if (root.listedMenuActions.length > 0) {
            sum += root.listedMenuActions.length * 32 // desktop-file action rows
            n += root.listedMenuActions.length
        }
        return sum + (n - 1) * 2 + 4
    }

    // System menu card height (two 32px rows + spacing + card padding)
    readonly property real systemMenuHeight: 32 * 2 + 2 + 4

    Component.onCompleted: {
        var docText = userSettingsFile.text() || ""
        root.dockSettings = DockModel.parseSettings(docText)
        root.pinnedIds = DockModel.parsePinned(docText)
        root.blacklistIds = DockModel.parseBlacklist(docText)
        IconResolver.loadCustomIcons(root.extractCustomIcons(docText))
        refreshLayers()
        updatePluginEnabled()
        refreshMinimized()
        updateDockItems()
    }

    readonly property int itemsCount: Math.max(1, root.dockItems.length)

    // Outside-click dismissal for the action menu
    HyprlandFocusGrab {
        active: root.isMenuOpen || root.isDockMenuOpen || root.isSystemMenuOpen
        windows: [menuWindow, systemMenuWindow, dockMenuWindow, dockWindow]
        onCleared: {
            root.activeMenuItem = null
            root.activeSystemItem = null
            root.isDockMenuOpen = false
        }
    }

    // 1. The Main Solid Dock Window (Permanent, strictly 46px height/width, 100% jitter-free)
    PanelWindow {
        id: dockWindow
        screen: root.targetScreen
        visible: root.opened && root.pluginEnabled && !root.forceRemap

        WlrLayershell.namespace: "omarchy-dock"
        WlrLayershell.layer: WlrLayer.Top
        // OnDemand: clicking the dock grants keyboard focus so live modifier state
        // (e.g. Super held) is delivered before the button event — enables Super+click menus
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        exclusionMode: (root.opened && root.pluginEnabled && visible && (!root.dockToggleWithBar || !root.barHidden)) ? ExclusionMode.Auto : ExclusionMode.Ignore
        color: "transparent"

        anchors {
            top: root.barPosition === "bottom"
            bottom: root.barPosition === "top"
            left: root.barPosition === "right"
            right: root.barPosition === "left"
        }

        margins {
            bottom: (!root.isVertical && root.barPosition === "top") ? ((root.dockToggleWithBar && root.barHidden) ? -(root.dockWindowThickness + 10) : (Style.gapsOut || 5)) : 0
            top: (!root.isVertical && root.barPosition === "bottom") ? ((root.dockToggleWithBar && root.barHidden) ? -(root.dockWindowThickness + 10) : (Style.gapsOut || 5)) : 0
            right: (root.isVertical && root.barPosition === "left") ? ((root.dockToggleWithBar && root.barHidden) ? -(root.dockWindowThickness + 10) : (Style.gapsOut || 5)) : 0
            left: (root.isVertical && root.barPosition === "right") ? ((root.dockToggleWithBar && root.barHidden) ? -(root.dockWindowThickness + 10) : (Style.gapsOut || 5)) : 0
        }

        // Exact, uncompromised dock dimensions with 2px antialiasing buffer
        implicitWidth: root.isVertical ? root.dockWindowThickness : root.dockWindowLength
        implicitHeight: root.isVertical ? root.dockWindowLength : root.dockWindowThickness

        // Main Visual Dock Card
        Rectangle {
            id: dockSurface
            anchors.centerIn: parent
            width: root.isVertical ? root.dockSurfaceThickness : root.dockSurfaceLength
            height: root.isVertical ? root.dockSurfaceLength : root.dockSurfaceThickness
            visible: root.opened && root.pluginEnabled && (!root.dockToggleWithBar || !root.barHidden) && !root.forceRemap

            color: Color.composed("bar.background", "bar.background-alpha", Color.background, root.dockBackgroundOpacity)
            border.width: root.systemBorderSize
            border.color: Color.accent
            radius: root.systemRounding
            antialiasing: true
            smooth: true

            Behavior on color { ColorAnimation { duration: 250 } }
            Behavior on border.color { ColorAnimation { duration: 250 } }
            Behavior on radius { NumberAnimation { duration: 250 } }

            // Blank space mouse area for right-click context menu
            // Long-press (touch-friendly) also opens the dock menu
            MouseArea {
                id: blankSpaceMouse
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton

                property bool suppressClick: false
                property real pressX: 0
                property real pressY: 0

                onPressed: function(mouse) {
                    suppressClick = false
                    if (mouse.button === Qt.LeftButton) {
                        pressX = mouse.x
                        pressY = mouse.y
                        blankLongPressTimer.restart()
                    } else {
                        blankLongPressTimer.stop()
                    }
                }

                onPositionChanged: function(mouse) {
                    // Finger moved — treat as a swipe/cancel, not a long press
                    var dx = mouse.x - pressX
                    var dy = mouse.y - pressY
                    if (dx * dx + dy * dy > 144) { // > 12px movement
                        blankLongPressTimer.stop()
                    }
                }

                onReleased: function(mouse) {
                    if (mouse.button === Qt.LeftButton) blankLongPressTimer.stop()
                }

                onClicked: function(mouse) {
                    if (suppressClick) return
                    if (mouse.button === Qt.RightButton) {
                        root.activeMenuItem = null
                        root.activeSystemItem = null
                        root.isDockMenuOpen = !root.isDockMenuOpen
                    } else {
                        root.activeMenuItem = null
                        root.activeSystemItem = null
                        root.isDockMenuOpen = false
                    }
                }

                Timer {
                    id: blankLongPressTimer
                    interval: root.dockLongPressDuration
                    repeat: false
                    onTriggered: {
                        blankSpaceMouse.suppressClick = true
                        root.activeMenuItem = null
                        root.activeSystemItem = null
                        root.isDockMenuOpen = !root.isDockMenuOpen
                    }
                }
            }

            // Audio Visualizer Backdrop
            Item {
                id: visualizerBackdrop
                anchors.fill: parent
                anchors.margins: root.systemBorderSize + 2
                z: 0
                visible: root.dockShowVisualizer

                Row {
                    anchors.fill: parent
                    spacing: 2
                    opacity: 0.25

                    Repeater {
                        model: root.visualizerLevels
                        delegate: Rectangle {
                            required property var modelData
                            width: (parent.width - (root.visualizerLevels.length - 1) * 2) / root.visualizerLevels.length
                            height: parent.height * Math.max(0.05, modelData)
                            anchors.bottom: parent.bottom
                            color: Color.accent
                            radius: 2

                            Behavior on height {
                                NumberAnimation { duration: 50 }
                            }
                        }
                    }
                }
            }

            Item {
                id: dockContent
                anchors.centerIn: parent
                width: root.isVertical ? root.dockContentThickness : root.dockContentLength
                height: root.isVertical ? root.dockContentLength : root.dockContentThickness
                z: 1

                Repeater {
                    model: root.dockItems

                    DockItem {
                        itemData: modelData
                        itemIndex: index
                        totalCount: root.itemsCount
                        barPosition: root.barPosition
                        shell: root.shell
                        iconBaseSize: root.dockIconSize
                        dockItemSize: root.dockItemSize
                        hoverScale: root.dockHoverScale
                        dragScale: root.dockDragScale
                        showRunningDots: root.dockShowRunningDots
                        systemBorderSize: root.systemBorderSize
                        systemRounding: root.systemRounding
                        longPressDuration: root.dockLongPressDuration
                        isSelected: (root.activeMenuItem && root.activeMenuItem.appClass === modelData.appClass)
                            || (root.activeSystemItem && root.activeSystemItem.appClass === modelData.appClass)

                        // Update tooltip tracked index and data on hover
                        onContainsMouseChanged: {
                            if (containsMouse) {
                                if (!isDragging) {
                                    tooltipDelayTimer.stop()
                                    tooltipDelayTimer.pendingData = modelData
                                    tooltipDelayTimer.pendingIndex = index
                                    if (root.hoveredItemData !== null) {
                                        // If another tooltip is already visible, switch immediately without delay
                                        root.hoveredItemData = modelData
                                        root.hoveredItemIndex = index
                                    } else {
                                        tooltipDelayTimer.restart()
                                    }
                                }
                            } else {
                                if (tooltipDelayTimer.pendingIndex === index) {
                                    tooltipDelayTimer.stop()
                                    tooltipDelayTimer.pendingData = null
                                    tooltipDelayTimer.pendingIndex = -1
                                }
                                if (root.hoveredItemIndex === index) {
                                    root.hoveredItemData = null
                                    root.hoveredItemIndex = -1
                                }
                            }
                        }

                        onIsDraggingChanged: {
                            if (isDragging) {
                                tooltipDelayTimer.stop()
                                tooltipDelayTimer.pendingData = null
                                tooltipDelayTimer.pendingIndex = -1
                                root.hoveredItemData = null
                                root.hoveredItemIndex = -1
                            }
                        }

                        x: root.isVertical ? 0 : (index * root.dockItemSize)
                        y: root.isVertical ? (index * root.dockItemSize) : 0

                        onItemLeftClicked: function(item) {
                            root.activeMenuItem = null
                            if (item && item.isMinimized) {
                                root.restoreItem(item)
                            }
                        }

                        onItemLaunchRequested: function(item, superHeld) {
                            // Watcher must snapshot before the launch dispatch
                            if (superHeld && item) root.floatNextWindowOfClass(String(item.appId || ""))
                            root.launchApp(item)
                        }

                        onItemFloatToggleRequested: function(item) {
                            // Toggle float/tile on the window a normal click would
                            // focus: the active one, or the cycle-next candidate.
                            // When toggling tiled->floating, also resize to
                            // floatingWindowScale (default 0.75 = 3/4) and center.
                            if (!item) return
                            var wins = item.windows || []
                            var target = null
                            if (wins.length > 0) {
                                target = (item.isActive && wins.length > 1)
                                    ? DockModel.nextWindowAfterActive(wins, null)
                                    : wins[0]
                            } else {
                                var tops = item.toplevels || []
                                if (tops.length > 0) target = { toplevel: tops[0] }
                            }
                            if (!target || !target.address) return
                            var addr = String(target.address)
                            var ratioX = root.dockFloatingWindowScaleX
                            var ratioY = root.dockFloatingWindowScaleY
                            var itemSize = root.dockItemSize
                            var script = "ADDR=" + Util.shellQuote(addr) + "; RATIO_X=" + Util.shellQuote(String(ratioX)) + "; RATIO_Y=" + Util.shellQuote(String(ratioY)) + "; ITEM_SIZE=" + Util.shellQuote(String(itemSize)) + "; "
                                + "BEFORE_FLOAT=$(hyprctl clients -j | jq -r --arg a \"$ADDR\" '.[] | select(.address==$a) | .floating'); "
                                + "hyprctl dispatch \"hl.dsp.window.float({ window = \\\"address:$ADDR\\\", action = \\\"toggle\\\" })\" 2>/dev/null; RC=$?; "
                                + "[ $RC -ne 0 ] && { hyprctl dispatch \"togglefloating address:$ADDR\" 2>/dev/null; RC=$?; [ $RC -ne 0 ] && hyprctl dispatch \"togglefloating $ADDR\" 2>/dev/null; }; "
                                + "for _ in 1 2 3 4 5 6; do FLOAT=$(hyprctl clients -j | jq -r --arg a \"$ADDR\" '.[] | select(.address==$a) | .floating'); if [ \"$FLOAT\" != \"$BEFORE_FLOAT\" ]; then break; fi; sleep 0.08; done; "
                                + "if [ \"$FLOAT\" != \"true\" ]; then exit 0; fi; "
                                + "MON=$(hyprctl clients -j | jq -r --arg a \"$ADDR\" '.[] | select(.address==$a) | .monitor'); "
                                + "MW=$(hyprctl monitors -j | jq -r --arg m \"$MON\" '.[] | select(.id==($m|tonumber)) | .width'); MH=$(hyprctl monitors -j | jq -r --arg m \"$MON\" '.[] | select(.id==($m|tonumber)) | .height'); MX=$(hyprctl monitors -j | jq -r --arg m \"$MON\" '.[] | select(.id==($m|tonumber)) | .x'); MY=$(hyprctl monitors -j | jq -r --arg m \"$MON\" '.[] | select(.id==($m|tonumber)) | .y'); SCALE=$(hyprctl monitors -j | jq -r --arg m \"$MON\" '.[] | select(.id==($m|tonumber)) | .scale'); "
                                + "if [ -z \"$MW\" ] || [ \"$MW\" = \"null\" ] || [ -z \"$MH\" ] || [ \"$MH\" = \"null\" ]; then MW=$(hyprctl monitors -j | jq -r '.[] | select(.focused==true) | .width'); MH=$(hyprctl monitors -j | jq -r '.[] | select(.focused==true) | .height'); MX=$(hyprctl monitors -j | jq -r '.[] | select(.focused==true) | .x'); MY=$(hyprctl monitors -j | jq -r '.[] | select(.focused==true) | .y'); SCALE=$(hyprctl monitors -j | jq -r '.[] | select(.focused==true) | .scale'); fi; "
                                + "if [ -z \"$SCALE\" ] || [ \"$SCALE\" = \"null\" ]; then SCALE=1; fi; "
                                + "if [ -z \"$MW\" ] || [ -z \"$MH\" ] || [ \"$MW\" = \"null\" ] || [ \"$MH\" = \"null\" ]; then exit 0; fi; "
                                + "NW=$(awk -v mw=\"$MW\" -v s=\"$SCALE\" -v r=\"$RATIO_X\" 'BEGIN{printf \"%d\", mw/s*r}'); NH=$(awk -v mh=\"$MH\" -v s=\"$SCALE\" -v r=\"$RATIO_Y\" 'BEGIN{printf \"%d\", mh/s*r}'); MWL=$(awk -v mw=\"$MW\" -v s=\"$SCALE\" 'BEGIN{printf \"%d\", mw/s}'); MHL=$(awk -v mh=\"$MH\" -v s=\"$SCALE\" 'BEGIN{printf \"%d\", mh/s}'); "
                                + "NX=$((MX + (MWL - NW)/2)); NY=$((MY + (MHL - NH)/2 - ITEM_SIZE/2)); "
                                + "hyprctl dispatch \"hl.dsp.window.resize({ window = \\\"address:$ADDR\\\", x = $NW, y = $NH })\" 2>/dev/null; "
                                + "sleep 0.05; "
                                + "hyprctl dispatch \"hl.dsp.window.move({ window = \\\"address:$ADDR\\\", x = $NX, y = $NY })\" 2>/dev/null; "
                            Util.execDetached("bash -c " + Util.shellQuote(script))
                        }

                        onNewWindowRequested: function(item, superHeld) {
                            root.activeMenuItem = null
                            root.openNewWindowForItem(item, superHeld)
                        }

                        onItemRightClicked: function(item, targetItem, withSuper) {
                            if (withSuper) {
                                // Super held: toggle the System menu for this icon
                                if (root.activeSystemItem && root.activeSystemItem.appClass === item.appClass) {
                                    root.activeSystemItem = null
                                } else {
                                    root.activeMenuItem = null
                                    root.activeSystemItemIndex = index
                                    root.activeSystemItem = item
                                }
                            } else if (root.activeMenuItem && root.activeMenuItem.appClass === item.appClass) {
                                root.activeMenuItem = null
                            } else {
                                root.activeSystemItem = null
                                root.activeMenuItemIndex = index
                                root.activeMenuItem = item
                            }
                        }

                        onMoveRequested: function(fromIdx, toIdx) {
                            root.setPinned(DockModel.reorderPinned(root.pinnedIds, root.dockItems, fromIdx, toIdx))
                        }
                    }
                }
            }
        }
    }

    // 2. Hover Tooltip (Shown when hovering over an icon, floats cleanly above/below/beside dock depending on barPosition)
    PanelWindow {
        id: tooltipWindow
        screen: root.targetScreen
        visible: root.dockShowTooltips && root.hoveredItemData !== null && !root.isMenuOpen && !root.isSystemMenuOpen && !root.forceRemap

        WlrLayershell.namespace: "omarchy-dock-tooltip"
        WlrLayershell.layer: WlrLayer.Overlay
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        anchors {
            top: root.barPosition === "bottom" ? true : (root.isVertical ? true : false)
            bottom: root.barPosition === "top" ? true : false
            left: root.barPosition === "right" ? true : (!root.isVertical ? true : false)
            right: root.barPosition === "left" ? true : false
        }

        margins {
            // Match the floating distance above/below/beside the main dock
            bottom: (!root.isVertical && root.barPosition === "top") ? ((Style.gapsOut || 5) + root.dockItemSize + 4) : 0
            top: (!root.isVertical && root.barPosition === "bottom") ? ((Style.gapsOut || 5) + root.dockItemSize + 4) : (root.isVertical ? root.calculatedTooltipTop : 0)
            right: (root.isVertical && root.barPosition === "left") ? ((Style.gapsOut || 5) + root.dockItemSize + 4) : 0
            left: (root.isVertical && root.barPosition === "right") ? ((Style.gapsOut || 5) + root.dockItemSize + 4) : (!root.isVertical ? root.calculatedTooltipLeft : 0)
        }

        implicitWidth: tooltipBubble.width
        implicitHeight: tooltipBubble.height

        Rectangle {
            id: tooltipBubble
            width: tooltipLabel.implicitWidth + 24
            height: tooltipLabel.implicitHeight + 12
            color: Color.composed("popups.background", "popups.background-alpha", Color.background, 0.95)
            border.width: root.systemBorderSize
            border.color: Color.accent
            radius: Math.min(8, root.systemRounding)
            antialiasing: true
            smooth: true

            Text {
                id: tooltipLabel
                anchors.centerIn: parent
                text: {
                    if (!root.hoveredItemData) return ""
                    var base = root.hoveredItemData.name
                    if (root.hoveredItemData.windowCount > 1) {
                        base += " — " + root.hoveredItemData.windowCount + " windows"
                    }
                    return base
                }
                font.family: Style.font.family
                font.pixelSize: 12
                font.bold: true
                color: Color.popups.text
            }
        }
    }

    // Exact geometric coordinate centering for the tooltip bubble
    readonly property real calculatedTooltipLeft: {
        var s = root.targetScreen
        var screenW = s ? s.width : 1920
        var dockW = root.isVertical ? root.dockWindowThickness : root.dockSurfaceLength
        var dockLeft = (screenW - dockW) / 2
        var iconCenterX = root.isVertical
            ? dockLeft + root.dockWindowThickness / 2
            : dockLeft + (root.dockWindowLength - root.dockContentLength) / 2 + root.hoveredItemIndex * root.dockItemSize + (root.dockItemSize - 4) / 2
        var targetLeft = iconCenterX - tooltipBubble.width / 2
        return Math.round(Math.max(6, Math.min(screenW - tooltipBubble.width - 6, targetLeft)))
    }

    readonly property real calculatedTooltipTop: {
        var s = root.targetScreen
        var screenH = s ? s.height : 1080
        var dockH = root.isVertical ? root.dockSurfaceLength : root.dockWindowThickness
        var dockTop = (screenH - dockH) / 2
        var iconCenterY = root.isVertical
            ? dockTop + (root.dockWindowLength - root.dockContentLength) / 2 + root.hoveredItemIndex * root.dockItemSize + (root.dockItemSize - 4) / 2
            : dockTop + root.dockWindowThickness / 2
        var targetTop = iconCenterY - tooltipBubble.height / 2
        return Math.round(Math.max(6, Math.min(screenH - tooltipBubble.height - 6, targetTop)))
    }

    // 2. The Isolated Action Card Popup Overlay Window (Floats strictly centered over the clicked icon)
    PanelWindow {
        id: menuWindow
        screen: root.targetScreen
        visible: root.isMenuOpen && root.opened && root.pluginEnabled && !root.forceRemap

        WlrLayershell.namespace: "omarchy-dock-menu"
        WlrLayershell.layer: WlrLayer.Overlay
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        anchors {
            top: root.barPosition === "bottom" ? true : (root.isVertical ? true : false)
            bottom: root.barPosition === "top" ? true : false
            left: root.barPosition === "right" ? true : (!root.isVertical ? true : false)
            right: root.barPosition === "left" ? true : false
        }

        margins {
            bottom: (!root.isVertical && root.barPosition === "top") ? ((Style.gapsOut || 5) + 52) : 0
            top: (!root.isVertical && root.barPosition === "bottom") ? ((Style.gapsOut || 5) + 52) : (root.isVertical ? root.calculatedMenuTop : 0)
            right: (root.isVertical && root.barPosition === "left") ? ((Style.gapsOut || 5) + 52) : 0
            left: (root.isVertical && root.barPosition === "right") ? ((Style.gapsOut || 5) + 52) : (!root.isVertical ? root.calculatedMenuLeft : 0)
        }

        implicitWidth: 260
        implicitHeight: root.actionMenuHeight

        // Visual Action Card
        Rectangle {
            anchors.centerIn: parent
            width: 252
            height: root.actionMenuHeight
            color: Color.composed("popups.background", "popups.background-alpha", Color.background, 0.96)
            border.width: root.systemBorderSize
            border.color: Color.accent
            radius: Math.min(10, root.systemRounding)
            antialiasing: true
            smooth: true

            // Vertical list layout for icon + label menu items
            ColumnLayout {
                id: actionCol
                anchors.fill: parent
                anchors.margins: 2
                spacing: 2

                // Actions header (shown on every app card, above Open New Window)
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 26
                    color: "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10

                        Text {
                            text: "Actions"
                            font.family: Style.font.family
                            font.pixelSize: 12
                            font.bold: true
                            color: Color.muted
                        }
                    }
                }

                // ＋ Open New Window Item (first row of the Actions section; merges a
                // matching [Desktop Action new-window] command when one exists)
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    radius: Math.min(6, root.systemRounding)
                    color: newMouse.containsMouse ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 10

                        Text {
                            text: "＋"
                            font.family: Style.font.family
                            font.pixelSize: 13
                            font.bold: true
                            color: newMouse.containsMouse ? Color.accent : Color.popups.text
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "Open New Window"
                            font.family: Style.font.family
                            font.pixelSize: 13
                            color: newMouse.containsMouse ? Color.accent : Color.popups.text
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        id: newMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            // Same semantics as middle-click: merged desktop action
                            // when defined, else force a new instance. Holding Alt
                            // floats the window that appears.
                            var alt = (mouse.modifiers & Qt.AltModifier) !== 0
                            root.openNewWindowForItem(root.activeMenuItem, alt)
                            root.activeMenuItem = null
                        }
                    }
                }

                // Desktop-file action rows (new-window actions are merged into the ＋ row above)
                Repeater {
                    model: root.listedMenuActions

                    delegate: Rectangle {
                        id: actRow
                        required property var modelData
                        readonly property var actionData: modelData || null
                        Layout.fillWidth: true
                        Layout.preferredHeight: 32
                        radius: Math.min(6, root.systemRounding)
                        color: actRowMouse.containsMouse ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent"

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            spacing: 10

                            Text {
                                text: "▸"
                                font.family: Style.font.family
                                font.pixelSize: 13
                                color: actRowMouse.containsMouse ? Color.accent : Color.muted
                            }

                            Text {
                                Layout.fillWidth: true
                                text: actRow.actionData ? String(actRow.actionData.name || actRow.actionData.id || "Action") : ""
                                font.family: Style.font.family
                                font.pixelSize: 13
                                color: actRowMouse.containsMouse ? Color.accent : Color.popups.text
                                elide: Text.ElideRight
                            }
                        }

                        MouseArea {
                            id: actRowMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.launchDesktopAction(actRow.actionData)
                                root.activeMenuItem = null
                            }
                        }
                    }
                }

                // ✕ Close Window Item (single-window running apps only;
                // multi-window apps get "Close All Windows" instead)
                Rectangle {
                    visible: !!root.activeMenuItem && root.activeMenuItem.isRunning === true
                        && Number(root.activeMenuItem.windowCount) < 2
                    Layout.fillWidth: true
                    Layout.preferredHeight: visible ? 32 : 0
                    radius: Math.min(6, root.systemRounding)
                    color: closeMouse.containsMouse ? Style.hoverFillFor(Color.urgent, Color.urgent) : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 10

                        Text {
                            text: "✕"
                            font.family: Style.font.family
                            font.pixelSize: 11
                            font.bold: true
                            color: closeMouse.containsMouse ? Color.urgent : Color.popups.text
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "Close Window"
                            font.family: Style.font.family
                            font.pixelSize: 13
                            color: closeMouse.containsMouse ? Color.urgent : Color.popups.text
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        id: closeMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.closeWindow(root.activeWindowOf(root.activeMenuItem))
                        }
                    }
                }

                // ✕✕ Close All Windows Item (if running with multiple windows)
                Rectangle {
                    visible: !!root.activeMenuItem && root.activeMenuItem.isRunning === true && Number(root.activeMenuItem.windowCount) > 1
                    Layout.fillWidth: true
                    Layout.preferredHeight: visible ? 32 : 0
                    radius: Math.min(6, root.systemRounding)
                    color: closeAllMouse.containsMouse ? Style.hoverFillFor(Color.urgent, Color.urgent) : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 10

                        Text {
                            text: "✕"
                            font.family: Style.font.family
                            font.pixelSize: 11
                            font.bold: true
                            color: closeAllMouse.containsMouse ? Color.urgent : Color.popups.text
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "Close All Windows"
                            font.family: Style.font.family
                            font.pixelSize: 13
                            color: closeAllMouse.containsMouse ? Color.urgent : Color.popups.text
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        id: closeAllMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.closeAllWindows(root.activeMenuItem)
                        }
                    }
                }

                // 🗕 / 🗗 Minimize ↔ Restore Item (if running)
                Rectangle {
                    visible: !!root.activeMenuItem && root.activeMenuItem.isRunning === true
                    Layout.fillWidth: true
                    Layout.preferredHeight: visible ? 32 : 0
                    radius: Math.min(6, root.systemRounding)
                    color: minMouse.containsMouse ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 10

                        Text {
                            text: (root.activeMenuItem && root.activeMenuItem.isMinimized) ? "🗗" : "🗕"
                            font.family: Style.font.family
                            font.pixelSize: 11
                            font.bold: true
                            color: minMouse.containsMouse ? Color.accent : Color.popups.text
                        }

                        Text {
                            Layout.fillWidth: true
                            text: {
                                var item = root.activeMenuItem
                                var all = !!item && Number(item.windowCount) >= 2
                                if (!item) return "Minimize to Dock"
                                return item.isMinimized
                                    ? (all ? "Restore All from Dock" : "Restore from Dock")
                                    : (all ? "Minimize All to Dock" : "Minimize to Dock")
                            }
                            font.family: Style.font.family
                            font.pixelSize: 13
                            color: minMouse.containsMouse ? Color.accent : Color.popups.text
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        id: minMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (root.activeMenuItem && root.activeMenuItem.appId) {
                                if (root.activeMenuItem.isMinimized) {
                                    root.restoreItem(root.activeMenuItem)
                                } else {
                                    root.minimizeItem(root.activeMenuItem)
                                }
                            }
                            root.activeMenuItem = null
                        }
                    }
                }

                // Windows List Header (if running with two-plus windows)
                Rectangle {
                    visible: root.showWindowList
                    Layout.fillWidth: true
                    Layout.preferredHeight: visible ? 26 : 0
                    color: "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 8

                        Text {
                            text: "Windows"
                            font.family: Style.font.family
                            font.pixelSize: 10
                            font.bold: true
                            color: Color.muted
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 1
                            Layout.alignment: Qt.AlignVCenter
                            color: Color.composed("bar.text", "bar.text-alpha", Color.bar.text, 0.15)
                        }

                        Text {
                            text: root.activeMenuItem ? String(root.activeMenuItem.windowCount) : ""
                            font.family: Style.font.family
                            font.pixelSize: 10
                            color: Color.muted
                        }
                    }
                }

                // Scrollable Window List (if running with two-plus windows)
                Item {
                    visible: root.showWindowList
                    Layout.fillWidth: true
                    Layout.preferredHeight: visible ? root.winListRows * 26 : 0

                    ListView {
                        id: winListView
                        anchors.fill: parent
                        anchors.rightMargin: 4
                        model: (root.activeMenuItem && root.activeMenuItem.windows) || []
                        clip: true
                        interactive: root.activeMenuItem && root.activeMenuItem.windows.length > root.winListRows
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool isActiveWin: modelData && modelData.active === true
                            readonly property bool rowHover: winRowArea.containsMouse
                            width: winListView.width
                            height: 26
                            radius: 5
                            color: rowHover ? Style.hoverFillFor(Color.popups.text, Color.accent) : (isActiveWin ? Color.composed("accent", "accent-alpha", Color.accent, 0.16) : "transparent")

                            MouseArea {
                                id: winRowArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.activateWindow(modelData)
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 4
                                spacing: 6

                                Text {
                                    text: modelData && modelData.workspaceName ? "[" + modelData.workspaceName + "]" : ""
                                    font.family: Style.font.family
                                    font.pixelSize: 9
                                    color: Color.muted
                                }

                                Text {
                                    Layout.fillWidth: true
                                    text: (modelData && modelData.title) ? modelData.title : "(untitled)"
                                    font.family: Style.font.family
                                    font.pixelSize: 12
                                    elide: Text.ElideRight
                                    color: isActiveWin ? Color.accent : Color.popups.text
                                }

                                // Per-window minimize ↔ restore pill (hover-revealed)
                                Rectangle {
                                    visible: winRowArea.containsMouse
                                    width: 16
                                    height: 16
                                    radius: 8
                                    // Solid accent on hover; faint wash at rest — glyph uses
                                    // full-strength colors so it never blends into the fill
                                    color: dockWinArea.containsMouse ? Color.accent : Style.hoverFillFor(Color.popups.text, Color.accent)

                                    Text {
                                        anchors.centerIn: parent
                                        text: (modelData && modelData.isDocked) ? "🗗" : "🗕"
                                        font.family: Style.font.family
                                        font.pixelSize: 9
                                        font.bold: true
                                        color: dockWinArea.containsMouse ? Color.background : Color.popups.text
                                    }

                                    MouseArea {
                                        id: dockWinArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (modelData && modelData.isDocked) {
                                                root.restoreWindow(modelData)
                                            } else {
                                                root.minimizeWindow(modelData)
                                            }
                                        }
                                    }
                                }

                                Rectangle {
                                    visible: winRowArea.containsMouse
                                    width: 16
                                    height: 16
                                    radius: 8
                                    color: closeWinArea.containsMouse ? Color.urgent : Style.hoverFillFor(Color.popups.text, Color.accent)

                                    Text {
                                        anchors.centerIn: parent
                                        text: "✕"
                                        font.family: Style.font.family
                                        font.pixelSize: 9
                                        font.bold: true
                                        color: closeWinArea.containsMouse ? Color.background : Color.popups.text
                                    }

                                    MouseArea {
                                        id: closeWinArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.closeWindow(modelData)
                                    }
                                }
                            }
                        }

                        // Thin accent scrollbar (only when content overflows)
                        Rectangle {
                            id: winScrollBar
                            visible: winListView.contentHeight > winListView.height
                            width: 3
                            height: Math.max(12, winListView.height * (winListView.height / winListView.contentHeight))
                            x: winListView.width - 3
                            y: winListView.contentY * (winListView.height / winListView.contentHeight)
                            radius: 1.5
                            color: Color.composed("bar.text", "bar.text-alpha", Color.bar.text, 0.45)
                        }
                    }
                }

            }
        }
    }

    // 2b. Super-held System Menu (floats centered over the clicked icon, same as the app menu)
    PanelWindow {
        id: systemMenuWindow
        screen: root.targetScreen
        visible: root.isSystemMenuOpen && root.opened && root.pluginEnabled && !root.forceRemap

        WlrLayershell.namespace: "omarchy-dock-menu"
        WlrLayershell.layer: WlrLayer.Overlay
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        anchors {
            top: root.barPosition === "bottom" ? true : (root.isVertical ? true : false)
            bottom: root.barPosition === "top" ? true : false
            left: root.barPosition === "right" ? true : (!root.isVertical ? true : false)
            right: root.barPosition === "left" ? true : false
        }

        margins {
            bottom: (!root.isVertical && root.barPosition === "top") ? ((Style.gapsOut || 5) + 52) : 0
            top: (!root.isVertical && root.barPosition === "bottom") ? ((Style.gapsOut || 5) + 52) : (root.isVertical ? root.calculatedMenuTop : 0)
            right: (root.isVertical && root.barPosition === "left") ? ((Style.gapsOut || 5) + 52) : 0
            left: (root.isVertical && root.barPosition === "right") ? ((Style.gapsOut || 5) + 52) : (!root.isVertical ? root.calculatedMenuLeft : 0)
        }

        implicitWidth: 260
        implicitHeight: root.systemMenuHeight

        // Visual System Card
        Rectangle {
            anchors.centerIn: parent
            width: 252
            height: root.systemMenuHeight
            color: Color.composed("popups.background", "popups.background-alpha", Color.background, 0.96)
            border.width: root.systemBorderSize
            border.color: Color.accent
            radius: Math.min(10, root.systemRounding)
            antialiasing: true
            smooth: true

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 2
                spacing: 2

                // ★ / ☆ Star Pin / Unpin Item
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    radius: Math.min(6, root.systemRounding)
                    color: sysPinMouse.containsMouse ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 10

                        Text {
                            text: (root.activeSystemItem && root.activeSystemItem.isPinned) ? "★" : "☆"
                            font.family: Style.font.family
                            font.pixelSize: 14
                            font.bold: true
                            color: (root.activeSystemItem && root.activeSystemItem.isPinned)
                                ? Color.accent
                                : (sysPinMouse.containsMouse ? Color.accent : Color.popups.text)
                        }

                        Text {
                            Layout.fillWidth: true
                            text: (root.activeSystemItem && root.activeSystemItem.isPinned) ? "Unpin from Dock" : "Pin to Dock"
                            font.family: Style.font.family
                            font.pixelSize: 13
                            color: sysPinMouse.containsMouse ? Color.accent : Color.popups.text
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        id: sysPinMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (!root.activeSystemItem) return
                            root.setPinned(DockModel.togglePinned(root.pinnedIds, root.activeSystemItem.appId))
                            root.activeSystemItem = null
                        }
                    }
                }

                // 🎨 Change Icon Item (moved from the app action card)
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    radius: Math.min(6, root.systemRounding)
                    color: sysIconMouse.containsMouse ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 10

                        Text {
                            text: "🎨"
                            font.family: Style.font.family
                            font.pixelSize: 12
                            color: sysIconMouse.containsMouse ? Color.accent : Color.popups.text
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "Change Icon"
                            font.family: Style.font.family
                            font.pixelSize: 13
                            color: sysIconMouse.containsMouse ? Color.accent : Color.popups.text
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        id: sysIconMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (root.activeSystemItem) {
                                iconInputDialog.targetItem = root.activeSystemItem
                                iconInputText.text = IconResolver.getCustomIcon(root.activeSystemItem.appId) || root.activeSystemItem.icon || ""
                                iconInputDialog.visible = true
                            }
                            root.activeSystemItem = null
                        }
                    }
                }
            }
        }
    }

    // 3. Blank Space Context Menu Window
    PanelWindow {
        id: dockMenuWindow
        screen: root.targetScreen
        visible: root.isDockMenuOpen && root.opened && root.pluginEnabled && !root.forceRemap

        WlrLayershell.namespace: "omarchy-dock-menu"
        WlrLayershell.layer: WlrLayer.Overlay
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        anchors {
            top: root.barPosition === "bottom" ? true : (root.isVertical ? true : false)
            bottom: root.barPosition === "top" ? true : false
            left: root.barPosition === "right" ? true : (!root.isVertical ? true : false)
            right: root.barPosition === "left" ? true : false
        }

        margins {
            bottom: (!root.isVertical && root.barPosition === "top") ? ((Style.gapsOut || 5) + 52) : 0
            top: (!root.isVertical && root.barPosition === "bottom") ? ((Style.gapsOut || 5) + 52) : (root.isVertical ? root.calculatedMenuTop : 0)
            right: (root.isVertical && root.barPosition === "left") ? ((Style.gapsOut || 5) + 52) : 0
            left: (root.isVertical && root.barPosition === "right") ? ((Style.gapsOut || 5) + 52) : (!root.isVertical ? root.calculatedMenuLeft : 0)
        }

        implicitWidth: 260
        implicitHeight: 2 * 32 + 16

        Rectangle {
            anchors.centerIn: parent
            width: 252
            height: 2 * 32 + 8
            color: Color.composed("popups.background", "popups.background-alpha", Color.background, 0.96)
            border.width: root.systemBorderSize
            border.color: Color.accent
            radius: Math.min(10, root.systemRounding)
            antialiasing: true
            smooth: true

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 2
                spacing: 2

                // 👁 Toggle with Top Bar Item
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    radius: Math.min(6, root.systemRounding)
                    color: tglBarMouse.containsMouse ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 10

                        Text {
                            text: root.dockToggleWithBar ? "✓" : "○"
                            font.family: Style.font.family
                            font.pixelSize: 13
                            font.bold: true
                            color: root.dockToggleWithBar ? Color.accent : (tglBarMouse.containsMouse ? Color.accent : Color.popups.text)
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "Toggle with Top Bar"
                            font.family: Style.font.family
                            font.pixelSize: 13
                            color: tglBarMouse.containsMouse ? Color.accent : Color.popups.text
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        id: tglBarMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            root.dockSettings.toggleWithBar = !root.dockToggleWithBar
                            root.saveSettings()
                            root.updateDockItems()
                            root.isDockMenuOpen = false
                        }
                    }
                }

                // ⚙ Configure Dock Settings
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    radius: Math.min(6, root.systemRounding)
                    color: cfgMouse.containsMouse ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 10

                        Text {
                            text: "⚙"
                            font.family: Style.font.family
                            font.pixelSize: 13
                            color: cfgMouse.containsMouse ? Color.accent : Color.popups.text
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "Configure Dock"
                            font.family: Style.font.family
                            font.pixelSize: 13
                            color: cfgMouse.containsMouse ? Color.accent : Color.popups.text
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        id: cfgMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            Util.execDetached("uwsm-app -- ${EDITOR:-micro} " + Util.shellQuote(root.settingsPath) + " || ${EDITOR:-micro} " + Util.shellQuote(root.settingsPath) + " || xdg-open " + Util.shellQuote(root.settingsPath))
                            root.isDockMenuOpen = false
                        }
                    }
                }
            }
        }
    }

    // Popup for setting custom icon
    PanelWindow {
        id: iconInputDialog
        property var targetItem: null
        visible: false

        WlrLayershell.namespace: "omarchy-dock-dialog"
        WlrLayershell.layer: WlrLayer.Overlay
        // Layer surfaces get no keyboard by default; OnDemand grants it on click
        // so the path TextInput can actually be typed into
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.OnDemand
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        anchors.top: true
        anchors.left: true
        anchors.right: true
        anchors.bottom: true

        function saveIconEntry() {
            if (iconInputDialog.targetItem && iconInputDialog.targetItem.appId) {
                IconResolver.setCustomIcon(iconInputDialog.targetItem.appId, iconInputText.text)
                root.saveCustomIcons()
                root.updateDockItems()
            }
            iconInputDialog.visible = false
        }

        function cancelIconEntry() {
            iconInputDialog.visible = false
        }

        onVisibleChanged: {
            if (visible) iconInputText.forceActiveFocus()
        }

        MouseArea {
            anchors.fill: parent
            onClicked: iconInputDialog.visible = false
        }

        Rectangle {
            anchors.centerIn: parent
            width: 320
            height: 140
            color: Color.composed("popups.background", "popups.background-alpha", Color.background, 0.98)
            border.width: root.systemBorderSize
            border.color: Color.accent
            radius: root.systemRounding
            antialiasing: true
            smooth: true

            MouseArea {
                anchors.fill: parent
                // absorb clicks inside dialog
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 12

                Text {
                    Layout.fillWidth: true
                    text: iconInputDialog.targetItem ? ("Set Custom Icon: " + iconInputDialog.targetItem.name) : "Set Custom Icon"
                    font.family: Style.font.family
                    font.bold: true
                    font.pixelSize: 14
                    color: Color.popups.text
                    elide: Text.ElideRight
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 32
                    color: Color.composed("bar.background", "bar.background-alpha", Color.background, 0.9)
                    border.width: 1
                    border.color: Color.accent
                    radius: 6

                    TextInput {
                        id: iconInputText
                        anchors.fill: parent
                        anchors.margins: 6
                        font.family: Style.font.family
                        font.pixelSize: 14
                        color: Color.popups.text
                        selectByMouse: true
                        clip: true
                        focus: true
                        Keys.onReturnPressed: iconInputDialog.saveIconEntry()
                        Keys.onEnterPressed: iconInputDialog.saveIconEntry()
                        Keys.onEscapePressed: iconInputDialog.cancelIconEntry()
                    }

                    // Placeholder hint (plain TextInput has no placeholderText)
                    Text {
                        anchors.fill: parent
                        anchors.margins: 6
                        visible: iconInputText.text.length === 0
                        text: "icon-name or /path/to/icon.png"
                        font.family: Style.font.family
                        font.pixelSize: 14
                        color: Color.muted
                        elide: Text.ElideRight
                    }
                }

                RowLayout {
                    Layout.alignment: Qt.AlignRight
                    spacing: 8

                    Rectangle {
                        width: 70
                        height: 28
                        radius: 6
                        color: cancelMouse.containsMouse ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent"
                        border.width: 1
                        border.color: Color.muted

                        Text {
                            anchors.centerIn: parent
                            text: "Cancel"
                            font.family: Style.font.family
                            font.pixelSize: 12
                            color: Color.popups.text
                        }

                        MouseArea {
                            id: cancelMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: iconInputDialog.cancelIconEntry()
                        }
                    }

                    Rectangle {
                        width: 70
                        height: 28
                        radius: 6
                        color: okMouse.containsMouse ? Style.hoverFillFor(Color.accent, Color.accent) : Color.accent

                        Text {
                            anchors.centerIn: parent
                            text: "Save"
                            font.family: Style.font.family
                            font.bold: true
                            font.pixelSize: 12
                            color: Color.background
                        }

                        MouseArea {
                            id: okMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: iconInputDialog.saveIconEntry()
                        }
                    }
                }
            }
        }
    }
}
