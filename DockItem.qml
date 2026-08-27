import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "DockModel.js" as DockModel
import "IconResolver.js" as IconResolver

Item {
    id: root

    property var shell: null
    property var itemData: null
    property int itemIndex: 0
    property int totalCount: 1
    property string barPosition: "top"
    readonly property bool isVertical: barPosition === "left" || barPosition === "right"
    property int iconBaseSize: 28
    property int dockItemSize: 46
    property real hoverScale: 1.12
    property real dragScale: 1.22
    property bool showRunningDots: true
    property bool isDragging: false
    property int systemBorderSize: 2
    property int systemRounding: 12
    property bool isSelected: false
    property int longPressDuration: 600
    readonly property bool containsMouse: mouseArea.containsMouse

    signal moveRequested(int fromIdx, int toIdx)
    signal itemRightClicked(var item, var targetItem, bool withSuper)
    signal itemLeftClicked(var item)
    signal itemFloatToggleRequested(var item)
    signal itemLaunchRequested(var item, bool superHeld)
    signal newWindowRequested(var item, bool superHeld)

    implicitWidth: root.dockItemSize - 4
    implicitHeight: root.dockItemSize - 4
    width: root.dockItemSize - 4
    height: root.dockItemSize - 4
    z: isDragging ? 100 : (isSelected ? 60 : (mouseArea.containsMouse ? 50 : 1))

    // Main animated icon wrapper (strictly centered)
    Item {
        id: iconWrapper
        anchors.centerIn: parent
        width: root.iconBaseSize
        height: root.iconBaseSize

        // Smooth subtle hover and drag zoom
        scale: root.isDragging ? root.dragScale : (mouseArea.containsMouse ? root.hoverScale : 1.0)
        opacity: root.isDragging ? 0.92 : (root.itemData && root.itemData.isMinimized ? 0.55 : 1.0)
        Behavior on scale { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

        // Application Icon Image
        Image {
            id: appIconImage
            anchors.centerIn: parent
            width: root.iconBaseSize
            height: root.iconBaseSize
            sourceSize.width: root.iconBaseSize * 2
            sourceSize.height: root.iconBaseSize * 2
            fillMode: Image.PreserveAspectFit
            smooth: true
            mipmap: true
            asynchronous: true

            source: {
                if (!root.itemData) return ""
                // Priority: explicit user override, then the already-resolved
                // itemData.icon (appLibrary.iconSource(entry.icon)), then the
                // heuristic resolution, then raw app identifiers.
                var custom = IconResolver.getCustomIcon(root.itemData.appId)
                var iconName = custom || root.itemData.icon || ""
                var resolved = IconResolver.resolveIcon(root.itemData.appClass, root.itemData.icon, root.itemData.appId)
                var candidates = [iconName]
                if (resolved && resolved !== iconName) candidates.push(resolved)
                candidates.push(root.itemData.appClass, root.itemData.appId)
                for (var i = 0; i < candidates.length; i++) {
                    var s = ""
                    if (root.shell && root.shell.appLibrary && typeof root.shell.appLibrary.iconSource === "function") {
                        s = root.shell.appLibrary.iconSource(candidates[i])
                    }
                    if (!s || s.length === 0) {
                        s = Quickshell.iconPath(candidates[i], true)
                    }
                    if (s && s.length > 0 && s.indexOf("application-x-executable") === -1) return s
                }
                return Quickshell.iconPath("application-x-executable", true)
            }

            // Fallback text glyph (no border box)
            Text {
                anchors.centerIn: parent
                visible: appIconImage.status !== Image.Ready
                text: root.itemData && root.itemData.name ? root.itemData.name.charAt(0).toUpperCase() : "★"
                font.family: Style.font.family
                font.bold: true
                font.pixelSize: 14
                color: Color.accent
            }
        }

        // Apple signature launch bounce animation
        SequentialAnimation {
            id: launchBounce
            loops: 2
            NumberAnimation { target: iconWrapper; property: "scale"; to: 1.16; duration: 110; easing.type: Easing.OutQuad }
            NumberAnimation { target: iconWrapper; property: "scale"; to: 1.0; duration: 110; easing.type: Easing.InQuad }
        }
    }

    // Running Indicator Dots (one per open window, active window highlighted, always under icon, fades on hover)
    Row {
        id: runningDots
        visible: opacity > 0
        opacity: (root.showRunningDots && root.itemData && root.itemData.isRunning && !mouseArea.containsMouse && !root.isDragging) ? 1.0 : 0.0

        Behavior on opacity { NumberAnimation { duration: 130; easing.type: Easing.OutCubic } }

        spacing: 2
        anchors.top: iconWrapper.bottom
        anchors.topMargin: 2
        anchors.horizontalCenter: parent.horizontalCenter

        Repeater {
            model: {
                if (!root.itemData || !root.itemData.isRunning) return 0
                var w = root.itemData.windows || []
                var n = w.length > 0 ? w.length : root.itemData.windowCount
                if (n < 1) n = 1
                return Math.min(5, n)
            }

            Rectangle {
                width: 3
                height: 3
                radius: width / 2
                color: {
                    var w = (root.itemData && root.itemData.windows) || []
                    var meta = w.length > index ? w[index] : null
                    return (meta && meta.active) ? Color.accent : Color.composed("bar.text", "bar.text-alpha", Color.bar.text, 0.75)
                }
                antialiasing: true
                smooth: true
                Behavior on color { ColorAnimation { duration: 180 } }
            }
        }

        Text {
            visible: (root.itemData && root.itemData.isRunning === true && Number(root.itemData.windowCount) > 5) === true
            text: root.itemData ? ("+" + (root.itemData.windowCount - 5)) : ""
            font.family: Style.font.family
            font.pixelSize: 7
            font.bold: true
            color: Color.composed("bar.text", "bar.text-alpha", Color.bar.text, 0.9)
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        cursorShape: root.isDragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor

        drag.target: root
        drag.axis: root.isVertical ? Drag.YAxis : Drag.XAxis
        drag.minimumX: root.isVertical ? 0 : 0
        drag.maximumX: root.isVertical ? 0 : Math.max(0, (root.totalCount - 1) * root.dockItemSize)
        drag.minimumY: root.isVertical ? 0 : 0
        drag.maximumY: root.isVertical ? Math.max(0, (root.totalCount - 1) * root.dockItemSize) : 0
        drag.threshold: 6

        property bool didDrag: false
        property bool suppressClick: false
        property bool pressSuperHeld: false
        property bool pressShiftHeld: false

        // Long-press opens the same context menu as right-click (touch-friendly)
        Timer {
            id: longPressTimer
            interval: root.longPressDuration
            repeat: false
            onTriggered: {
                mouseArea.suppressClick = true
                root.itemRightClicked(root.itemData, root, mouseArea.pressSuperHeld)
            }
        }

        onPressed: function(mouse) {
            // Reset interaction state on every press so stale flags can't swallow later clicks
            didDrag = false
            suppressClick = false
            // Snapshot modifiers at press time (release-time state can miss early key release)
            pressSuperHeld = (mouse.modifiers & Qt.MetaModifier) !== 0
            pressShiftHeld = (mouse.modifiers & Qt.ShiftModifier) !== 0
            if (mouse.button === Qt.LeftButton) {
                longPressTimer.restart()
            } else {
                longPressTimer.stop()
            }
        }

        onPositionChanged: function(mouse) {
            if (mouseArea.drag.active) {
                // Finger moved into a reorder drag — cancel the pending long press
                longPressTimer.stop()
                if (!root.isDragging && !suppressClick) {
                    root.isDragging = true
                    didDrag = true
                }
            }
        }

        onReleased: function(mouse) {
            if (mouse.button === Qt.LeftButton) longPressTimer.stop()
            if (root.isDragging) {
                root.isDragging = false
                var currentCoord = root.isVertical ? root.y : root.x
                var newIdx = Math.max(0, Math.min(root.totalCount - 1, Math.round(currentCoord / root.dockItemSize)))
                if (newIdx !== root.itemIndex) {
                    root.moveRequested(root.itemIndex, newIdx)
                } else {
                    root.x = root.isVertical ? 0 : (root.itemIndex * root.dockItemSize)
                    root.y = root.isVertical ? (root.itemIndex * root.dockItemSize) : 0
                }
            } else if (suppressClick) {
                // Long press already opened the menu; snap back any drift
                root.x = root.isVertical ? 0 : (root.itemIndex * root.dockItemSize)
                root.y = root.isVertical ? (root.itemIndex * root.dockItemSize) : 0
            }
        }

        onClicked: function(mouse) {
            if (didDrag || suppressClick) return
            // Shift+Left mirrors Middle-click ("Open New Window"); both bypass
            // restore/activate semantics exactly like the middle button does
            if (mouse.button === Qt.MiddleButton || (mouse.button === Qt.LeftButton && pressShiftHeld)) {
                launchBounce.restart()
                root.newWindowRequested(root.itemData, pressSuperHeld)
                return
            }
            if (mouse.button === Qt.LeftButton) {
                launchBounce.restart()
                // Super+click on a running app toggles float/tile of its
                // focus-target window instead of focusing/cycling
                if (pressSuperHeld && root.itemData && root.itemData.isRunning) {
                    root.itemFloatToggleRequested(root.itemData)
                    return
                }
                root.itemLeftClicked(root.itemData)
                if (root.itemData && root.itemData.isMinimized) return
                if (root.itemData && root.itemData.isRunning) {
                    var windows = root.itemData.windows || []
                    var target = null
                    if (windows.length > 0) {
                        target = (root.itemData.isActive && windows.length > 1)
                            ? DockModel.nextWindowAfterActive(windows, null)
                            : windows[0]
                    } else {
                        var tops = root.itemData.toplevels || []
                        if (tops.length > 0) {
                            target = { toplevel: tops[0] }
                        }
                    }
                    if (target && target.toplevel && target.toplevel.activate) {
                        target.toplevel.activate()
                    }
                } else if (root.itemData) {
                    // Launching is centralized in the panel (webapp-class fallback etc.)
                    root.itemLaunchRequested(root.itemData, pressSuperHeld)
                }
            } else if (mouse.button === Qt.RightButton) {
                root.itemRightClicked(root.itemData, root, pressSuperHeld)
            }
        }

        onWheel: function(wheel) {
            if (root.isDragging || !root.itemData || !root.itemData.isRunning || root.itemData.isMinimized) return
            var windows = root.itemData.windows || []
            if (windows.length < 2) return
            var target = DockModel.cycleWindow(windows, null, wheel.angleDelta.y > 0 ? 1 : -1)
            if (target && target.toplevel && target.toplevel.activate) {
                target.toplevel.activate()
            }
        }
    }
}
