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
    }

    function toggle() {
        root.opened = !root.opened
        root.activeMenuItem = null
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

    // Safe compositor unmap-remap sequence on orientation shift
    Timer {
        id: remapTimer
        interval: 100
        repeat: false
        onTriggered: {
            if (root.opened && root.pluginEnabled) dockWindow.visible = true
        }
    }

    onBarPositionChanged: {
        dockWindow.visible = false
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

    // Blank Space Context Menu State
    property bool isDockMenuOpen: false

    // Exact geometric coordinate centering for the overlay menu
    readonly property real calculatedMenuLeft: {
        var screenW = dockWindow.screen ? dockWindow.screen.width : 1920
        var dockW = root.isVertical ? root.dockWindowThickness : root.dockSurfaceLength
        var dockLeft = (screenW - dockW) / 2
        var iconCenterX = root.isVertical
            ? dockLeft + root.dockWindowThickness / 2
            : dockLeft + (root.dockWindowLength - root.dockContentLength) / 2 + root.activeMenuItemIndex * root.dockItemSize + (root.dockItemSize - 4) / 2
        var menuW = 230
        var targetLeft = iconCenterX - menuW / 2
        return Math.round(Math.max(6, Math.min(screenW - menuW - 6, targetLeft)))
    }

    readonly property real calculatedMenuTop: {
        var screenH = dockWindow.screen ? dockWindow.screen.height : 1080
        var dockH = root.isVertical ? root.dockSurfaceLength : root.dockWindowThickness
        var dockTop = (screenH - dockH) / 2
        var iconCenterY = root.isVertical
            ? dockTop + (root.dockWindowLength - root.dockContentLength) / 2 + root.activeMenuItemIndex * root.dockItemSize + (root.dockItemSize - 4) / 2
            : dockTop + root.dockWindowThickness / 2
        var menuH = root.actionMenuHeight
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
        root.dockSettings = DockModel.parseSettings(userSettingsFile.text() || "")
        root.pinnedIds = DockModel.parsePinned(userPinnedFile.text() || "")
        root.blacklistIds = DockModel.parseBlacklist(userBlacklistFile.text() || "")
        root.refreshLayers()
        root.updatePluginEnabled()
        root.updateDockItems()
        return "ok"
    }

    // Minimized window tracking (windows parked on the special:minimized workspace)
    property var minimizedIds: []

    Process {
        id: minimizedProbe
        property var pending: []
        command: ["bash", "-c", "hyprctl clients -j | jq -r '.[] | select(.workspace.name == \"special:minimized\") | .class'; printf '\\n'"]
        stdout: SplitParser {
            onRead: function(line) {
                var value = String(line).trim()
                if (value && value.length > 0) {
                    minimizedProbe.pending.push(value)
                }
            }
        }
        onExited: function(exitCode, exitStatus) {
            var next = minimizedProbe.pending.slice()
            minimizedProbe.pending = []
            if (!root.arraysEqual(root.minimizedIds, next)) {
                root.minimizedIds = next
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
        minimizedProbe.pending = []
        minimizedProbe.running = true
    }

    onMinimizedIdsChanged: updateDockItems()

    // Pinned & Blacklist apps persistence
    property string userPinnedPath: Quickshell.env("HOME") + "/.config/omarchy/dock-pinned.json"
    property string userBlacklistPath: Quickshell.env("HOME") + "/.config/omarchy/dock-blacklist.json"
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
        }
    }

    // Basic dock settings persistence (~/.config/omarchy/dock-settings.json)
    property string settingsPath: Quickshell.env("HOME") + "/.config/omarchy/dock-settings.json"
    property string iconsPath: Quickshell.env("HOME") + "/.config/omarchy/dock-icons.json"
    property var dockSettings: DockModel.DEFAULT_SETTINGS

    readonly property int dockItemSize: Number(dockSettings.itemSize) || 80
    readonly property int dockIconSize: Number(dockSettings.iconSize) || 38
    readonly property int dockPadding: Number(dockSettings.padding) || 48
    readonly property real dockHoverScale: Number(dockSettings.hoverScale) || 2
    readonly property real dockDragScale: Number(dockSettings.dragScale) || 2
    readonly property real dockBackgroundOpacity: Number(dockSettings.backgroundOpacity) || 0.98
    readonly property bool dockShowRunningDots: dockSettings.showRunningDots !== false
    readonly property bool dockShowTooltips: dockSettings.showTooltips !== false
    readonly property bool dockToggleWithBar: dockSettings.toggleWithBar !== false
    readonly property bool dockShowVisualizer: dockSettings.showVisualizer !== false
    readonly property int dockVisualizerBars: Number(dockSettings.visualizerBars) || 32

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

    function updateDockItems() {
        var toplevels = ToplevelManager.toplevels ? ToplevelManager.toplevels.values : []
        var active = ToplevelManager.activeToplevel
        var lib = shell ? shell.appLibrary : null
        var fws = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : undefined
        var fmon = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
        root.dockItems = DockModel.buildDockItems(root.pinnedIds, root.blacklistIds, toplevels, active, root.appRows, lib, root.minimizedIds, fws, fmon)
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

    FileView {
        id: userPinnedFile
        path: root.userPinnedPath
        watchChanges: true
        atomicWrites: true
        printErrors: false
        onLoaded: {
            root.pinnedIds = DockModel.parsePinned(text())
            root.updateDockItems()
        }
        onLoadFailed: {
            root.pinnedIds = DockModel.DEFAULT_PINNED.slice()
            root.savePinned()
            root.updateDockItems()
        }
        onFileChanged: userPinnedFile.reload()
    }

    FileView {
        id: userBlacklistFile
        path: root.userBlacklistPath
        watchChanges: true
        atomicWrites: true
        printErrors: false
        onLoaded: {
            root.blacklistIds = DockModel.parseBlacklist(text())
            root.updateDockItems()
        }
        onLoadFailed: {
            root.blacklistIds = DockModel.DEFAULT_BLACKLIST.slice()
            root.saveBlacklist()
            root.updateDockItems()
        }
        onFileChanged: userBlacklistFile.reload()
    }

    FileView {
        id: userSettingsFile
        path: root.settingsPath
        watchChanges: true
        atomicWrites: true
        printErrors: false
        onLoaded: {
            root.dockSettings = DockModel.parseSettings(text())
            root.updateDockItems()
        }
        onLoadFailed: {
            root.dockSettings = DockModel.parseSettings("")
            root.saveSettings()
            root.updateDockItems()
        }
        onFileChanged: userSettingsFile.reload()
    }

    // Custom per-app icon overrides persistence (~/.config/omarchy/dock-icons.json)
    FileView {
        id: userIconsFile
        path: root.iconsPath
        watchChanges: true
        atomicWrites: true
        printErrors: false
        onLoaded: {
            var overrides = null
            try {
                overrides = JSON.parse(text() || "{}")
            } catch(e) {
                overrides = {}
            }
            IconResolver.loadCustomIcons(overrides)
            root.updateDockItems()
        }
        onLoadFailed: {
            IconResolver.loadCustomIcons({})
            root.saveCustomIcons()
        }
        onFileChanged: userIconsFile.reload()
    }

    function saveCustomIcons() {
        var json = JSON.stringify(IconResolver.allCustomIcons(), null, 2)
        userIconsFile.setText(json + "\n")
    }

    function saveSettings() {
        var json = DockModel.serializeSettings(root.dockSettings)
        userSettingsFile.setText(json + "\n")
    }

    function savePinned() {
        var json = DockModel.serializePinned(root.pinnedIds)
        userPinnedFile.setText(json + "\n")
    }

    function setPinned(next) {
        root.pinnedIds = next
        root.savePinned()
        root.updateDockItems()
    }

    function saveBlacklist() {
        var json = DockModel.serializeBlacklist(root.blacklistIds)
        userBlacklistFile.setText(json + "\n")
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
    function launchApp(item) {
        if (!item || !item.appId) return
        if (root.shell && root.shell.appLibrary && typeof root.shell.appLibrary.launch === "function") {
            root.shell.appLibrary.launch(item.appId, item.name)
        } else {
            var target = item.appId ? (item.appId + ".desktop") : (item.exec + ".desktop")
            Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(target) + " || uwsm-app -- " + item.exec)
        }
    }

    // Activate a specific window from the window list
    function activateWindow(meta) {
        if (!meta || !meta.toplevel) return
        if (meta.toplevel.activate) meta.toplevel.activate()
        root.activeMenuItem = null
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

    // Scrollable window-list rows (capped at 8)
    readonly property int winListRows: {
        var item = root.activeMenuItem
        if (!item || !item.isRunning || !item.windows) return 0
        return Math.max(1, Math.min(8, item.windows.length))
    }

    // Total action-card height accounting for the window list (exact ColumnLayout fit)
    readonly property real actionMenuHeight: {
        var item = root.activeMenuItem
        var sum = 32 * 3 // pin, new window, icon
        var n = 3
        if (item && item.isRunning) {
            sum += 32 // close window
            n += 1
            if (item.windowCount > 1) {
                sum += 32 // close all windows
                n += 1
            }
            sum += 32 // minimize
            n += 1
            sum += 26 // "Windows" header
            n += 1
            sum += root.winListRows * 26 // window list
            n += 1
        }
        return sum + (n - 1) * 2 + 4
    }

    Component.onCompleted: {
        root.dockSettings = DockModel.parseSettings(userSettingsFile.text() || "")
        root.pinnedIds = DockModel.parsePinned(userPinnedFile.text() || "")
        root.blacklistIds = DockModel.parseBlacklist(userBlacklistFile.text() || "")
        refreshLayers()
        updatePluginEnabled()
        refreshMinimized()
        updateDockItems()
    }

    readonly property int itemsCount: Math.max(1, root.dockItems.length)

    // Outside-click dismissal for the action menu
    HyprlandFocusGrab {
        active: root.isMenuOpen || root.isDockMenuOpen
        windows: [menuWindow, dockMenuWindow, dockWindow]
        onCleared: {
            root.activeMenuItem = null
            root.isDockMenuOpen = false
        }
    }

    // 1. The Main Solid Dock Window (Permanent, strictly 46px height/width, 100% jitter-free)
    PanelWindow {
        id: dockWindow
        visible: root.opened && root.pluginEnabled && !remapTimer.running

        WlrLayershell.namespace: "omarchy-dock"
        WlrLayershell.layer: WlrLayer.Top
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
            visible: root.opened && root.pluginEnabled && (!root.dockToggleWithBar || !root.barHidden) && !remapTimer.running

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
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: function(mouse) {
                    if (mouse.button === Qt.RightButton) {
                        root.activeMenuItem = null
                        root.isDockMenuOpen = !root.isDockMenuOpen
                    } else {
                        root.activeMenuItem = null
                        root.isDockMenuOpen = false
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
                        isSelected: root.activeMenuItem && root.activeMenuItem.appClass === modelData.appClass

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

                        onNewWindowRequested: function(item) {
                            root.activeMenuItem = null
                            root.launchApp(item)
                        }

                        onItemRightClicked: function(item, targetItem) {
                            if (root.activeMenuItem && root.activeMenuItem.appClass === item.appClass) {
                                root.activeMenuItem = null
                            } else {
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
        visible: root.dockShowTooltips && root.hoveredItemData !== null && !root.isMenuOpen

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
        var screenW = dockWindow.screen ? dockWindow.screen.width : 1920
        var dockW = root.isVertical ? root.dockWindowThickness : root.dockSurfaceLength
        var dockLeft = (screenW - dockW) / 2
        var iconCenterX = root.isVertical
            ? dockLeft + root.dockWindowThickness / 2
            : dockLeft + (root.dockWindowLength - root.dockContentLength) / 2 + root.hoveredItemIndex * root.dockItemSize + (root.dockItemSize - 4) / 2
        var targetLeft = iconCenterX - tooltipBubble.width / 2
        return Math.round(Math.max(6, Math.min(screenW - tooltipBubble.width - 6, targetLeft)))
    }

    readonly property real calculatedTooltipTop: {
        var screenH = dockWindow.screen ? dockWindow.screen.height : 1080
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
        visible: root.isMenuOpen && root.opened && root.pluginEnabled

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

                // ★ / ☆ Star Pin / Unpin Item
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    radius: Math.min(6, root.systemRounding)
                    color: pinMouse.containsMouse ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 10

                        Text {
                            text: (root.activeMenuItem && root.activeMenuItem.isPinned) ? "★" : "☆"
                            font.family: Style.font.family
                            font.pixelSize: 14
                            font.bold: true
                            color: (root.activeMenuItem && root.activeMenuItem.isPinned)
                                ? Color.accent
                                : (pinMouse.containsMouse ? Color.accent : Color.popups.text)
                        }

                        Text {
                            Layout.fillWidth: true
                            text: (root.activeMenuItem && root.activeMenuItem.isPinned) ? "Unpin from Dock" : "Pin to Dock"
                            font.family: Style.font.family
                            font.pixelSize: 13
                            color: pinMouse.containsMouse ? Color.accent : Color.popups.text
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        id: pinMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (!root.activeMenuItem) return
                            root.setPinned(DockModel.togglePinned(root.pinnedIds, root.activeMenuItem.appId))
                            root.activeMenuItem = null
                        }
                    }
                }

                // ＋ Open New Window Item
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
                            root.launchApp(root.activeMenuItem)
                            root.activeMenuItem = null
                        }
                    }
                }

                // ✕ Close Window Item (if running)
                Rectangle {
                    visible: root.activeMenuItem && root.activeMenuItem.isRunning
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
                            color: closeMouse.containsMouse ? Color.urgent : Color.muted
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
                    visible: root.activeMenuItem && root.activeMenuItem.isRunning && root.activeMenuItem.windowCount > 1
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
                            text: "✕✕"
                            font.family: Style.font.family
                            font.pixelSize: 11
                            font.bold: true
                            color: closeAllMouse.containsMouse ? Color.urgent : Color.muted
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

                // 🗕 Minimize Window Item (if running)
                Rectangle {
                    visible: root.activeMenuItem && root.activeMenuItem.isRunning
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
                            text: "🗕"
                            font.family: Style.font.family
                            font.pixelSize: 11
                            font.bold: true
                            color: minMouse.containsMouse ? Color.accent : Color.muted
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "Minimize to Dock"
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
                                root.minimizeItem(root.activeMenuItem)
                            }
                            root.activeMenuItem = null
                        }
                    }
                }

                // Windows List Header (if running)
                Rectangle {
                    visible: root.activeMenuItem && root.activeMenuItem.isRunning
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

                // Scrollable Window List (if running)
                Item {
                    visible: root.activeMenuItem && root.activeMenuItem.isRunning
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

                // 🎨 Custom Icon Item
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 32
                    radius: Math.min(6, root.systemRounding)
                    color: iconMouse.containsMouse ? Style.hoverFillFor(Color.popups.text, Color.accent) : "transparent"

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        spacing: 10

                        Text {
                            text: "🎨"
                            font.family: Style.font.family
                            font.pixelSize: 12
                            color: iconMouse.containsMouse ? Color.accent : Color.popups.text
                        }

                        Text {
                            Layout.fillWidth: true
                            text: "Change Icon"
                            font.family: Style.font.family
                            font.pixelSize: 13
                            color: iconMouse.containsMouse ? Color.accent : Color.popups.text
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        id: iconMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (root.activeMenuItem) {
                                iconInputDialog.targetItem = root.activeMenuItem
                                iconInputText.text = IconResolver.getCustomIcon(root.activeMenuItem.appId) || root.activeMenuItem.icon || ""
                                iconInputDialog.visible = true
                            }
                            root.activeMenuItem = null
                        }
                    }
                }
            }
        }
    }

    // 3. Blank Space Context Menu Window
    PanelWindow {
        id: dockMenuWindow
        visible: root.isDockMenuOpen && root.opened && root.pluginEnabled

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
        exclusionMode: ExclusionMode.Ignore
        color: "transparent"

        anchors.top: true
        anchors.left: true
        anchors.right: true
        anchors.bottom: true

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
                    text: iconInputDialog.targetItem ? ("Set Custom Icon: " + iconInputDialog.targetItem.name) : "Set Custom Icon"
                    font.family: Style.font.family
                    font.bold: true
                    font.pixelSize: 14
                    color: Color.popups.text
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
                            onClicked: iconInputDialog.visible = false
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
                            onClicked: {
                                if (iconInputDialog.targetItem && iconInputDialog.targetItem.appId) {
                                    IconResolver.setCustomIcon(iconInputDialog.targetItem.appId, iconInputText.text)
                                    root.saveCustomIcons()
                                    root.updateDockItems()
                                }
                                iconInputDialog.visible = false
                            }
                        }
                    }
                }
            }
        }
    }
}
