import QtQuick
import QtQuick.Layouts
import org.kde.kwin as KWinComponents
import org.kde.kwin
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PC3

Item {
    id: view

    property var overlay
    readonly property var ov: overlay

    readonly property var scr: KWinComponents.SceneView.screen
    readonly property rect geo: scr ? scr.geometry : Qt.rect(0, 0, width, height)
    readonly property bool isTarget: !!scr && !!ov && scr.name === ov.targetScreenName

    focus: true
    Keys.onPressed: function (event) { ov.handleKey(event); }

    Rectangle {
        anchors.fill: parent
        color: "black"
    }
    KWinComponents.DesktopBackground {
        anchors.fill: parent
        activity: Workspace.currentActivity
        desktop: Workspace.currentDesktop
        outputName: view.scr ? view.scr.name : ""
    }
    Repeater {
        model: view.ov ? view.ov.backdropWindows : []
        delegate: Item {
            id: win
            required property var modelData
            readonly property string wid: String(modelData.internalId)
            readonly property var mv: {
                var items = view.ov ? view.ov.moveItems : [];
                for (var i = 0; i < items.length; ++i) {
                    if (String(items[i].w.internalId) === wid) {
                        return items[i];
                    }
                }
                return null;
            }
            readonly property rect live: modelData.frameGeometry
            property real t: 0
            readonly property real fx: mv ? mv.from.x + (mv.to.x - mv.from.x) * t : live.x
            readonly property real fy: mv ? mv.from.y + (mv.to.y - mv.from.y) * t : live.y
            readonly property real fw: mv ? mv.from.w + (mv.to.w - mv.from.w) * t : live.width
            readonly property real fh: mv ? mv.from.h + (mv.to.h - mv.from.h) * t : live.height

            x: fx - view.geo.x
            y: fy - view.geo.y
            width: fw
            height: fh
            visible: fx < view.geo.x + view.geo.width && fx + fw > view.geo.x
                && fy < view.geo.y + view.geo.height && fy + fh > view.geo.y

            KWinComponents.WindowThumbnail {
                id: thumb
                client: win.modelData
                width: Math.max(1, win.live.width)
                height: Math.max(1, win.live.height)
                transform: Scale {
                    xScale: win.width / thumb.width
                    yScale: win.height / thumb.height
                }
            }

            Rectangle {
                anchors.fill: parent
                color: "black"
                opacity: view.ov && view.ov.isDimmed(win.modelData) ? view.ov.dimStrength : 0
                Behavior on opacity {
                    NumberAnimation { duration: Kirigami.Units.longDuration }
                }
            }

            onMvChanged: {
                anim.stop();
                t = 0;
                if (mv) {
                    anim.start();
                }
            }

            NumberAnimation {
                id: anim
                target: win
                property: "t"
                from: 0
                to: 1
                duration: view.ov ? view.ov.moveDuration : 0
                easing.type: Easing.InOutCubic
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onPressed: view.ov.close()
    }

    Loader {
        active: view.isTarget && view.ov.mode === "menu"
        anchors.fill: parent
        sourceComponent: menuComponent
    }

    Loader {
        active: view.isTarget && view.ov.mode === "switcher"
        anchors.fill: parent
        sourceComponent: switcherComponent
    }

    Component {
        id: menuComponent

        Item {
            Rectangle {
                id: bubble
                width: 30
                height: 30
                radius: 15
                x: view.ov.anchor.x - view.geo.x - 15
                y: view.ov.anchor.y - view.geo.y - 15
                color: Kirigami.Theme.highlightColor
                Kirigami.Icon {
                    anchors.centerIn: parent
                    width: 18
                    height: 18
                    source: view.ov.group.length > 1
                        && Math.abs(view.ov.group[0].frameGeometry.y - view.ov.group[1].frameGeometry.y) < 4
                        ? "view-split-left-right" : "view-split-top-bottom"
                    color: Kirigami.Theme.highlightedTextColor
                    isMask: true
                }
            }

            Kirigami.ShadowedRectangle {
                id: panel
                width: 300
                height: content.implicitHeight + 2 * Kirigami.Units.largeSpacing
                x: Math.max(8, Math.min(parent.width - width - 8, bubble.x + bubble.width + 8))
                y: Math.max(8, Math.min(parent.height - height - 8, bubble.y - 8))
                radius: Kirigami.Units.cornerRadius
                color: Kirigami.Theme.backgroundColor
                border.width: 1
                border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                      Kirigami.Theme.textColor.b, 0.2)
                shadow.size: 24
                shadow.yOffset: 4
                shadow.color: Qt.rgba(0, 0, 0, 0.45)

                transformOrigin: Item.TopLeft
                opacity: 0
                scale: 0.95
                Component.onCompleted: menuAppear.start()
                ParallelAnimation {
                    id: menuAppear
                    NumberAnimation { target: panel; property: "opacity"; to: 1; duration: Kirigami.Units.longDuration; easing.type: Easing.OutCubic }
                    NumberAnimation { target: panel; property: "scale"; to: 1; duration: Kirigami.Units.longDuration; easing.type: Easing.OutCubic }
                }
                ParallelAnimation {
                    id: menuDisappear
                    NumberAnimation { target: panel; property: "opacity"; to: 0; duration: Kirigami.Units.longDuration; easing.type: Easing.InCubic }
                    NumberAnimation { target: panel; property: "scale"; to: 0.95; duration: Kirigami.Units.longDuration; easing.type: Easing.InCubic }
                }
                Connections {
                    target: view.ov
                    function onClosingChanged() {
                        if (view.ov.closing) {
                            menuAppear.stop();
                            menuDisappear.start();
                        } else {
                            menuDisappear.stop();
                            menuAppear.start();
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                }

                ColumnLayout {
                    id: content
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Kirigami.Units.largeSpacing
                    spacing: Kirigami.Units.smallSpacing

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        Repeater {
                            model: view.ov.group
                            Kirigami.Icon {
                                required property var modelData
                                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                source: modelData ? modelData.icon : ""
                            }
                        }
                        PC3.Label {
                            Layout.fillWidth: true
                            text: view.ov.group.length + " " + (view.ov.group.length < 5 ? "окна" : "окон")
                            opacity: 0.7
                            elide: Text.ElideRight
                        }
                    }

                    Repeater {
                        model: view.ov.menuStep === "menu" ? view.ov.actions : []
                        Rectangle {
                            required property var modelData
                            required property int index
                            Layout.fillWidth: true
                            implicitHeight: row.implicitHeight + 2 * Kirigami.Units.smallSpacing
                            radius: Kirigami.Units.smallSpacing
                            color: index === view.ov.menuIndex ? Qt.rgba(Kirigami.Theme.highlightColor.r,
                                                                         Kirigami.Theme.highlightColor.g,
                                                                         Kirigami.Theme.highlightColor.b, 0.35)
                                                               : "transparent"
                            RowLayout {
                                id: row
                                anchors.fill: parent
                                anchors.margins: Kirigami.Units.smallSpacing
                                spacing: Kirigami.Units.smallSpacing * 2
                                Kirigami.Icon {
                                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                                    Layout.preferredHeight: Kirigami.Units.iconSizes.small
                                    source: modelData.icon
                                }
                                PC3.Label {
                                    Layout.fillWidth: true
                                    text: modelData.text
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onEntered: view.ov.menuIndex = index
                                onClicked: view.ov.trigger(modelData.id)
                            }
                        }
                    }

                    PC3.Label {
                        visible: view.ov.menuStep === "name"
                        text: "Название шаблона"
                    }
                    PC3.TextField {
                        id: nameField
                        visible: view.ov.menuStep === "name"
                        Layout.fillWidth: true
                        onVisibleChanged: {
                            if (visible) {
                                text = view.ov.suggestedName;
                                selectAll();
                                forceActiveFocus();
                            } else {
                                view.forceActiveFocus();
                            }
                        }
                        onAccepted: view.ov.saveTemplate(text)
                        Keys.onEscapePressed: view.ov.menuStep = "menu"
                    }
                    RowLayout {
                        visible: view.ov.menuStep === "name"
                        Layout.fillWidth: true
                        Item { Layout.fillWidth: true }
                        PC3.Button {
                            text: "Отмена"
                            onClicked: view.ov.menuStep = "menu"
                        }
                        PC3.Button {
                            text: "Сохранить"
                            icon.name: "document-save"
                            onClicked: view.ov.saveTemplate(nameField.text)
                        }
                    }

                    RowLayout {
                        visible: view.ov.menuStep === "done"
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing * 2
                        Kirigami.Icon {
                            Layout.preferredWidth: Kirigami.Units.iconSizes.small
                            Layout.preferredHeight: Kirigami.Units.iconSizes.small
                            source: "checkmark"
                        }
                        PC3.Label {
                            Layout.fillWidth: true
                            text: "Шаблон «" + view.ov.savedName + "» сохранён"
                            wrapMode: Text.Wrap
                        }
                    }
                }
            }
        }
    }

    Component {
        id: switcherComponent

        Item {
            id: sw
            readonly property int columns: Math.max(1, Math.min(view.ov.templates.length,
                                                                Math.floor((width * 0.85) / view.ov.cellWidth)))
            onColumnsChanged: view.ov.switcherColumns = columns
            Component.onCompleted: view.ov.switcherColumns = columns

            Kirigami.ShadowedRectangle {
                id: switcherPanel
                anchors.centerIn: parent
                width: (view.ov.templates.length > 0 ? Math.max(360, sw.columns * view.ov.cellWidth) : 440)
                    + 2 * Kirigami.Units.largeSpacing
                height: column.implicitHeight + 2 * Kirigami.Units.largeSpacing
                radius: Kirigami.Units.cornerRadius
                color: Kirigami.Theme.backgroundColor
                border.width: 1
                border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                      Kirigami.Theme.textColor.b, 0.2)
                shadow.size: 32
                shadow.yOffset: 6
                shadow.color: Qt.rgba(0, 0, 0, 0.45)

                opacity: 0
                scale: 0.95
                Component.onCompleted: switcherAppear.start()
                ParallelAnimation {
                    id: switcherAppear
                    NumberAnimation { target: switcherPanel; property: "opacity"; to: 1; duration: Kirigami.Units.longDuration; easing.type: Easing.OutCubic }
                    NumberAnimation { target: switcherPanel; property: "scale"; to: 1; duration: Kirigami.Units.longDuration; easing.type: Easing.OutCubic }
                }
                ParallelAnimation {
                    id: switcherDisappear
                    NumberAnimation { target: switcherPanel; property: "opacity"; to: 0; duration: Kirigami.Units.longDuration; easing.type: Easing.InCubic }
                    NumberAnimation { target: switcherPanel; property: "scale"; to: 0.95; duration: Kirigami.Units.longDuration; easing.type: Easing.InCubic }
                }
                Connections {
                    target: view.ov
                    function onClosingChanged() {
                        if (view.ov.closing) {
                            switcherAppear.stop();
                            switcherDisappear.start();
                        } else {
                            switcherDisappear.stop();
                            switcherAppear.start();
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.AllButtons
                }

                ColumnLayout {
                    id: column
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Kirigami.Units.largeSpacing
                    spacing: Kirigami.Units.largeSpacing

                    PC3.Label {
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        text: "Шаблоны окон"
                        font.bold: true
                    }

                    ColumnLayout {
                        visible: view.ov.templates.length === 0
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing
                        PC3.Label {
                            Layout.preferredWidth: 440
                            Layout.alignment: Qt.AlignHCenter
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                            opacity: 0.8
                            text: "Шаблонов пока нет. Поставьте окна рядом, наведите курсор на границу между ними и нажмите на появившуюся кнопку — или создайте шаблон в настройках."
                        }
                        PC3.Button {
                            Layout.alignment: Qt.AlignHCenter
                            text: "Открыть настройки"
                            icon.name: "configure"
                            onClicked: {
                                view.ov.close();
                                view.ov.core.openSettings();
                            }
                        }
                    }

                    GridLayout {
                        visible: view.ov.templates.length > 0
                        Layout.alignment: Qt.AlignHCenter
                        columns: sw.columns
                        rowSpacing: 0
                        columnSpacing: 0

                        Repeater {
                            model: view.ov.templates
                            delegate: Item {
                                id: card
                                required property var modelData
                                required property int index
                                readonly property bool current: index === view.ov.switcherIndex
                                Layout.preferredWidth: view.ov.cellWidth
                                Layout.preferredHeight: view.ov.cellHeight

                                Rectangle {
                                    anchors.fill: parent
                                    anchors.margins: 2
                                    radius: Kirigami.Units.cornerRadius
                                    visible: card.current
                                    color: Qt.rgba(Kirigami.Theme.highlightColor.r, Kirigami.Theme.highlightColor.g,
                                                   Kirigami.Theme.highlightColor.b, 0.3)
                                    border.width: 2
                                    border.color: Kirigami.Theme.highlightColor
                                }

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: Kirigami.Units.largeSpacing
                                    spacing: Kirigami.Units.smallSpacing

                                    Rectangle {
                                        id: preview
                                        Layout.preferredWidth: view.ov.cardWidth
                                        Layout.preferredHeight: view.ov.previewHeight
                                        radius: Kirigami.Units.smallSpacing
                                        color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                                       Kirigami.Theme.textColor.b, 0.08)

                                        Repeater {
                                            model: card.modelData.slots
                                            Rectangle {
                                                required property var modelData
                                                readonly property real fx0: Math.min(Math.max(modelData.x, 0), 0.95)
                                                readonly property real fy0: Math.min(Math.max(modelData.y, 0), 0.95)
                                                readonly property real fw: Math.min(modelData.w, 1 - fx0)
                                                readonly property real fh: Math.min(modelData.h, 1 - fy0)
                                                x: fx0 * preview.width + 2
                                                y: fy0 * preview.height + 2
                                                width: Math.max(4, fw * preview.width - 4)
                                                height: Math.max(4, fh * preview.height - 4)
                                                radius: 3
                                                color: Kirigami.Theme.alternateBackgroundColor
                                                border.width: 1
                                                border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g,
                                                                      Kirigami.Theme.textColor.b, 0.3)
                                                Kirigami.Icon {
                                                    anchors.centerIn: parent
                                                    width: Math.min(32, parent.width - 6, parent.height - 6)
                                                    height: width
                                                    source: view.ov.core ? view.ov.core.slotIcon(parent.modelData) : ""
                                                    fallback: "application-x-executable"
                                                }
                                            }
                                        }
                                    }

                                    PC3.Label {
                                        Layout.fillWidth: true
                                        horizontalAlignment: Text.AlignHCenter
                                        elide: Text.ElideRight
                                        text: (card.index < 9 ? (card.index + 1) + ". " : "") + card.modelData.name
                                    }
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onEntered: view.ov.switcherIndex = card.index
                                    onClicked: view.ov.applyIndex(card.index)
                                }
                            }
                        }
                    }

                    PC3.Label {
                        visible: view.ov.templates.length > 0
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignHCenter
                        opacity: 0.6
                        font.pointSize: Kirigami.Theme.smallFont.pointSize
                        text: "Enter — применить · Esc — закрыть · 1–9 — сразу"
                    }
                }
            }
        }
    }
}
