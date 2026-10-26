import QtQuick
import org.kde.kwin

SceneEffect {
    id: effect

    readonly property string cacheBust: "?v=" + Date.now()
    property var overlay: null

    visible: false

    Component.onDestruction: visible = false

    delegate: FocusScope {
        id: screenRoot
        focus: true
        Loader {
            id: viewLoader
            anchors.fill: parent
            focus: true
        }
        Component.onCompleted: viewLoader.setSource(Qt.resolvedUrl("OverlayView.qml") + effect.cacheBust,
                                                     { overlay: effect.overlay })
    }

    Loader {
        id: overlayLoader
    }

    Loader {
        id: coreLoader
    }

    Component.onCompleted: {
        overlayLoader.setSource(Qt.resolvedUrl("Overlay.qml") + cacheBust, { effect: effect });
        effect.overlay = overlayLoader.item;
        coreLoader.setSource(Qt.resolvedUrl("Core.qml") + cacheBust, { overlay: effect.overlay });
        overlayLoader.item.core = coreLoader.item;
    }
}
