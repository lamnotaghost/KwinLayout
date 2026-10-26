import QtQuick
import QtQuick.Window
import org.kde.kirigami as Kirigami

Window {
    id: win

    property var core
    property bool vertical: true
    property point handlePos: Qt.point(0, 0)
    readonly property int handleSize: 30

    width: handleSize
    height: handleSize
    visible: false
    color: "transparent"
    flags: Qt.ToolTip | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.WindowDoesNotAcceptFocus

    function showAt(pos, isVertical) {
        win.vertical = isVertical;
        moveTo(pos);
        win.show();
    }

    function hideHandle() {
        win.hide();
    }

    function moveTo(pos) {
        win.handlePos = pos;
        win.x = pos.x;
        win.y = pos.y;
    }

    function containsGlobal(p) {
        return visible && p.x >= x - 4 && p.x < x + width + 4 && p.y >= y - 4 && p.y < y + height + 4;
    }

    Rectangle {
        id: bubble
        anchors.fill: parent
        radius: width / 2
        readonly property bool hot: mouse.containsMouse || mouse.pressed
        color: hot ? Kirigami.Theme.highlightColor : Kirigami.Theme.backgroundColor
        border.width: 1
        border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                              Kirigami.Theme.textColor.b, 0.25)
        Behavior on color { ColorAnimation { duration: 100 } }

        Kirigami.Icon {
            anchors.centerIn: parent
            width: 18
            height: 18
            source: win.vertical ? "view-split-left-right" : "view-split-top-bottom"
            color: bubble.hot ? Kirigami.Theme.highlightedTextColor : Kirigami.Theme.textColor
            isMask: true
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: dragging ? (win.vertical ? Qt.SplitHCursor : Qt.SplitVCursor) : Qt.PointingHandCursor

        property bool dragging: false
        property point pressPos

        onPressed: {
            dragging = false;
            pressPos = win.core.cursorPos();
        }
        onPositionChanged: function (event) {
            if (!pressed || event.buttons !== Qt.LeftButton) {
                return;
            }
            var p = win.core.cursorPos();
            if (!dragging && Math.abs(win.vertical ? p.x - pressPos.x : p.y - pressPos.y) > 3) {
                dragging = win.core.beginDrag(pressPos);
            }
            if (dragging) {
                win.core.updateDrag();
            }
        }
        onReleased: {
            if (dragging) {
                dragging = false;
                win.core.endDrag();
            } else {
                win.core.openMenu();
            }
        }
        onCanceled: {
            if (dragging) {
                dragging = false;
                win.core.endDrag();
            }
        }
    }
}
