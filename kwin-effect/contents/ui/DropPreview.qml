import QtQuick
import QtQuick.Window
import org.kde.kirigami as Kirigami

Window {
    id: win

    visible: false
    color: "transparent"
    flags: Qt.ToolTip | Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint
        | Qt.WindowDoesNotAcceptFocus | Qt.WindowTransparentForInput

    function showAt(r) {
        win.x = r.x;
        win.y = r.y;
        win.width = Math.max(1, r.width);
        win.height = Math.max(1, r.height);
        if (!win.visible) {
            frame.opacity = 0;
            win.show();
            fadeIn.restart();
        }
    }

    function hidePreview() {
        fadeIn.stop();
        win.hide();
    }

    Rectangle {
        id: frame
        anchors.fill: parent
        anchors.margins: 4
        radius: Kirigami.Units.cornerRadius
        color: Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g,
                       Kirigami.Theme.highlightColor.b, 0.25)
        border.width: 2
        border.color: Kirigami.Theme.highlightColor

        NumberAnimation on opacity {
            id: fadeIn
            running: false
            to: 1
            duration: Kirigami.Units.shortDuration
        }
    }
}
