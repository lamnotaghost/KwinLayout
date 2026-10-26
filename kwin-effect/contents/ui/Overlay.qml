import QtQuick
import QtCore
import org.kde.kwin
import org.kde.kirigami as Kirigami

Item {
    id: ov

    property var effect
    property var core

    readonly property bool shown: !!effect && effect.visible

    Connections {
        target: ov.effect
        function onConfigurationChanged() {
            if (ov.core) {
                ov.core.onReconfigureRequest();
            }
        }
    }
    property bool closing: false
    readonly property bool open: shown && !closing

    property string mode: ""
    property string targetScreenName: ""
    property var backdropWindows: []

    property var group: []
    property string suggestedName: ""
    property point anchor: Qt.point(0, 0)
    property string menuStep: "menu"
    property int menuIndex: 0
    property string savedName: ""
    readonly property var actions: {
        var list = [{ id: "save", icon: "document-save", text: "Сохранить расположение…" }];
        if (group.length === 2) {
            list.push({ id: "swap", icon: "exchange-positions", text: "Поменять окна местами" });
        }
        list.push({ id: "settings", icon: "configure", text: "Настройки шаблонов…" });
        return list;
    }

    property var moveItems: []
    readonly property int moveDuration: Kirigami.Units.longDuration * 2.5

    property int settleWaited: 0

    Timer {
        id: moveEndTimer
        interval: ov.moveDuration + 40
        onTriggered: ov.settleOrClose()
    }

    Timer {
        id: settleTimer
        interval: 40
        onTriggered: ov.settleOrClose()
    }

    function windowsSettled() {
        return moveItems.every(function (it) {
            if (it.w.deleted) {
                return true;
            }
            var g = it.w.frameGeometry;
            return Math.abs(g.x - it.to.x) <= 4 && Math.abs(g.y - it.to.y) <= 4
                && Math.abs(g.width - it.to.w) <= 4 && Math.abs(g.height - it.to.h) <= 4;
        });
    }

    readonly property int repaintHold: 120
    property bool holding: false

    function settleOrClose() {
        if (holding) {
            closeNow();
            return;
        }
        var settled = windowsSettled();
        if (settled || settleWaited >= 600) {
            console.log("windowlayouts: окна " + (settled ? "встали" : "не встали") + " за " + settleWaited + " мс; "
                        + moveItems.map(function (it) {
                            var g = it.w.frameGeometry;
                            return core.windowAppName(it.w) + " Δ(" + Math.round(g.x - it.to.x) + "," + Math.round(g.y - it.to.y)
                                + "," + Math.round(g.width - it.to.w) + "," + Math.round(g.height - it.to.h) + ")";
                        }).join(" "));
            holding = true;
            settleTimer.interval = repaintHold;
            settleTimer.restart();
        } else {
            settleWaited += settleTimer.interval;
            settleTimer.restart();
        }
    }

    function startMoveTimers() {
        settleWaited = 0;
        holding = false;
        settleTimer.interval = 40;
        settleTimer.stop();
        moveEndTimer.restart();
    }

    property var pickTemplate: null
    property var pickQueue: []
    property int pickStep: 0
    property int pickIndex: 0
    property var pickChosen: []
    property bool pickFromSwitcher: false
    readonly property var pickEntry: pickStep < pickQueue.length ? pickQueue[pickStep] : null
    readonly property var pickWindows: {
        if (!pickEntry) {
            return [];
        }
        var chosen = pickChosen;
        return pickEntry.windows.filter(function (w) {
            return !w.deleted && chosen.indexOf(w) === -1;
        });
    }
    readonly property var pickCurrent: pickIndex >= 0 && pickIndex < pickWindows.length ? pickWindows[pickIndex] : null

    property var templates: []
    property real screenAspect: 16 / 9
    property int switcherIndex: 0
    property int switcherColumns: 1
    readonly property int switcherCount: templates.length + 1
    property var saveWindows: []
    property var saveSlots: []
    property string saveSuggested: ""
    property bool savingName: false
    property string justSavedName: ""

    Timer {
        id: justSavedTimer
        interval: 2500
        onTriggered: ov.justSavedName = ""
    }
    readonly property int cardWidth: 220
    readonly property int previewHeight: Math.round(Math.max(90, Math.min(160, cardWidth / screenAspect)))
    readonly property int cellWidth: cardWidth + 24
    readonly property int cellHeight: previewHeight + 56

    Timer {
        id: safetyTimer
        interval: 120000
        onTriggered: {
            console.warn("windowlayouts: эффект закрыт по таймауту");
            ov.close();
        }
    }

    Timer {
        id: doneTimer
        interval: 1100
        onTriggered: ov.close()
    }

    Timer {
        id: fadeOutTimer
        interval: Kirigami.Units.longDuration
        onTriggered: ov.closeNow()
    }

    property bool dimEnabled: false
    property real dimStrength: 0
    property bool dimPanels: false
    property bool dimDesktop: false
    property bool dimKeepAbove: false
    property bool dimByGroup: true

    Component {
        id: kwinrcComponent
        Settings {
            location: StandardPaths.writableLocation(StandardPaths.GenericConfigLocation) + "/kwinrc"
        }
    }

    function readBool(s, key, def) {
        var v = s.value(key, def ? "true" : "false");
        return v === true || String(v).toLowerCase() === "true";
    }

    function readDimSettings() {
        var s = kwinrcComponent.createObject(ov);
        dimEnabled = readBool(s, "Plugins/diminactiveEnabled", false);
        dimStrength = Math.max(0, Math.min(100, Number(s.value("Effect-diminactive/Strength", 25)))) / 100;
        dimPanels = readBool(s, "Effect-diminactive/DimPanels", false);
        dimDesktop = readBool(s, "Effect-diminactive/DimDesktop", false);
        dimKeepAbove = readBool(s, "Effect-diminactive/DimKeepAbove", true);
        dimByGroup = readBool(s, "Effect-diminactive/DimByGroup", true);
        s.destroy();
    }

    function isDimmed(w) {
        if (!dimEnabled || dimStrength <= 0) {
            return false;
        }
        var a = Workspace.activeWindow;
        if (!a || String(a.internalId) === String(w.internalId)) {
            return false;
        }
        if ((w.dock && !dimPanels) || (w.desktopWindow && !dimDesktop) || (w.keepAbove && !dimKeepAbove)) {
            return false;
        }
        if (dimByGroup && core.sameApp({ app: String(a.desktopFileName || ""), wmClass: String(a.resourceClass || "") }, w)) {
            return false;
        }
        return true;
    }

    function snapshotWindows(exclude) {
        readDimSettings();
        var out = [];
        var l = Workspace.stackingOrder;
        for (var i = 0; i < l.length; ++i) {
            var w = l[i];
            if (exclude && exclude.indexOf(w) !== -1) {
                continue;
            }
            if (!w.deleted && !w.minimized && !w.dock && (w.managed || w.desktopWindow) && core.onCurrentDesktop(w)) {
                out.push(w);
            }
        }
        backdropWindows = out;
    }

    function show(screen) {
        fadeOutTimer.stop();
        moveItems = [];
        closing = false;
        targetScreenName = screen ? screen.name : "";
        snapshotWindows();
        effect.visible = true;
        safetyTimer.restart();
        console.log("windowlayouts: эффект показан (" + mode + ") на " + targetScreenName);
        Qt.callLater(activateTarget);
    }

    function activateTarget() {
        var screens = Workspace.screens;
        for (var i = 0; i < screens.length; ++i) {
            if (screens[i].name === targetScreenName) {
                var v = effect.viewForScreen(screens[i]);
                if (v) {
                    effect.activateView(v);
                }
                return;
            }
        }
    }

    function openMenu(screen, anchorPoint, windows, name) {
        mode = "menu";
        group = windows;
        suggestedName = name;
        anchor = anchorPoint;
        menuStep = "menu";
        menuIndex = 0;
        show(screen);
    }

    function openSwitcher(screen, aspect, list) {
        mode = "switcher";
        templates = list;
        saveWindows = core.windowsForSave(screen);
        saveSlots = saveWindows.map(core.slotFromWindow);
        saveSuggested = core.defaultName(saveWindows);
        savingName = false;
        justSavedName = "";
        screenAspect = aspect > 0 ? aspect : 16 / 9;
        switcherIndex = list.length > 0 ? 1 : 0;
        show(screen);
    }

    function close() {
        if (!shown) {
            closeNow();
            return;
        }
        if (closing) {
            return;
        }
        safetyTimer.stop();
        doneTimer.stop();
        closing = true;
        if (fadeOutTimer.interval > 0) {
            fadeOutTimer.restart();
        } else {
            closeNow();
        }
    }

    function closeNow() {
        fadeOutTimer.stop();
        moveEndTimer.stop();
        settleTimer.stop();
        safetyTimer.stop();
        doneTimer.stop();
        if (effect) {
            effect.visible = false;
        }
    }

    function trigger(id) {
        if (id === "save") {
            menuStep = "name";
        } else if (id === "swap") {
            startSwap(group[0], group[1]);
        } else if (id === "settings") {
            close();
            core.openSettings();
        }
    }

    function rectObj(r) {
        return { x: r.x, y: r.y, w: r.width, h: r.height };
    }

    function animateMoves(items) {
        items = items || [];
        var anyMoves = items.some(function (it) {
            return it.from.x !== it.to.x || it.from.y !== it.to.y || it.from.w !== it.to.w || it.from.h !== it.to.h;
        });
        if (!anyMoves || moveDuration <= 0 || !shown) {
            close();
            return;
        }
        safetyTimer.stop();
        doneTimer.stop();
        fadeOutTimer.stop();
        moveItems = items;
        closing = true;
        startMoveTimers();
    }

    function playMoves(items) {
        items = (items || []).filter(function (it) {
            return it.from.x !== it.to.x || it.from.y !== it.to.y || it.from.w !== it.to.w || it.from.h !== it.to.h;
        });
        if (items.length === 0 || moveDuration <= 0 || shown) {
            return;
        }
        mode = "";
        snapshotWindows();
        moveItems = items;
        closing = true;
        effect.visible = true;
        startMoveTimers();
    }

    function startSwap(a, b) {
        var from = { a: rectObj(a.frameGeometry), b: rectObj(b.frameGeometry) };
        var to = core.swapWindows(a, b);
        if (!to) {
            close();
            return;
        }
        animateMoves([
            { w: a, from: from.a, to: rectObj(to.a) },
            { w: b, from: from.b, to: rectObj(to.b) }
        ]);
    }

    function saveTemplate(name) {
        var t = core.saveGroup(group, name);
        savedName = t.name;
        menuStep = "done";
        doneTimer.start();
    }

    function selectNext() {
        switcherIndex = (switcherIndex + 1) % switcherCount;
    }

    function selectPrevious() {
        switcherIndex = (switcherIndex + switcherCount - 1) % switcherCount;
    }

    function activateSwitcherIndex(i) {
        if (i === 0) {
            beginSave();
        } else {
            applyIndex(i - 1);
        }
    }

    function beginSave() {
        if (saveWindows.length > 0) {
            savingName = true;
        }
    }

    function finishSave(name) {
        var t = core.saveGroup(saveWindows, name);
        templates = core.loadTemplates();
        savingName = false;
        switcherIndex = templates.length;
        justSavedName = t.name;
        justSavedTimer.restart();
    }

    function applyIndex(i) {
        if (i < 0 || i >= templates.length) {
            return;
        }
        requestApply(templates[i]);
    }

    function requestApply(t) {
        var queue = core.windowChoices(t);
        if (queue.length === 0) {
            if (shown) {
                animateMoves(core.applyTemplate(t));
            } else {
                playMoves(core.applyTemplate(t));
            }
            return;
        }
        pickFromSwitcher = open && mode === "switcher";
        pickTemplate = t;
        pickQueue = queue;
        pickStep = 0;
        pickIndex = 0;
        pickChosen = [];
        var screen = core.screenAt(Workspace.cursorPos);
        var area = core.screenArea(screen);
        screenAspect = area.height > 0 ? area.width / area.height : 16 / 9;
        console.log("windowlayouts: «" + t.name + "» — нужно выбрать окна: "
                    + queue.map(function (q) { return (q.slot.title || q.slot.app) + " ×" + q.windows.length; }).join(", "));
        mode = "pick";
        if (!pickFromSwitcher) {
            show(screen);
        }
    }

    function choose(w) {
        if (!w || !pickEntry || closing) {
            return;
        }
        var chosen = pickChosen.slice();
        chosen[pickEntry.index] = w;
        pickChosen = chosen;
        pickIndex = 0;
        if (pickStep + 1 < pickQueue.length) {
            pickStep += 1;
            return;
        }
        animateMoves(core.applyTemplate(pickTemplate, chosen));
    }

    function cancelPick() {
        if (pickStep > 0) {
            pickStep -= 1;
            var chosen = pickChosen.slice();
            chosen[pickQueue[pickStep].index] = undefined;
            pickChosen = chosen;
            pickIndex = 0;
        } else if (pickFromSwitcher) {
            mode = "switcher";
        } else {
            close();
        }
    }

    function handleKey(event) {
        if (closing) {
            event.accepted = true;
            return;
        }
        safetyTimer.restart();
        var key = event.key;
        if (key === Qt.Key_Escape) {
            if (mode === "pick") {
                cancelPick();
            } else if (mode === "switcher" && savingName) {
                savingName = false;
            } else if (mode === "menu" && menuStep === "name") {
                menuStep = "menu";
            } else {
                close();
            }
            event.accepted = true;
            return;
        }
        if (mode === "menu") {
            if (menuStep === "menu") {
                if (key === Qt.Key_Up) {
                    menuIndex = (menuIndex + actions.length - 1) % actions.length;
                } else if (key === Qt.Key_Down || key === Qt.Key_Tab) {
                    menuIndex = (menuIndex + 1) % actions.length;
                } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
                    trigger(actions[menuIndex].id);
                } else {
                    return;
                }
            } else if (menuStep === "done" && (key === Qt.Key_Return || key === Qt.Key_Enter)) {
                close();
            } else {
                return;
            }
            event.accepted = true;
            return;
        }
        if (mode === "pick") {
            var n = pickWindows.length;
            if (n === 0) {
                return;
            }
            if (key === Qt.Key_Right || key === Qt.Key_Tab || key === Qt.Key_Down) {
                pickIndex = (pickIndex + 1) % n;
            } else if (key === Qt.Key_Left || key === Qt.Key_Backtab || key === Qt.Key_Up) {
                pickIndex = (pickIndex + n - 1) % n;
            } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
                choose(pickCurrent);
            } else if (key >= Qt.Key_1 && key <= Qt.Key_9 && key - Qt.Key_1 < n) {
                choose(pickWindows[key - Qt.Key_1]);
            } else {
                return;
            }
            event.accepted = true;
            return;
        }
        if (mode === "switcher") {
            if (savingName) {
                return;
            }
            var columns = Math.max(1, switcherColumns);
            if (key === Qt.Key_Right || key === Qt.Key_Tab) {
                selectNext();
            } else if (key === Qt.Key_Left || key === Qt.Key_Backtab) {
                selectPrevious();
            } else if (key === Qt.Key_Down) {
                switcherIndex = Math.min(switcherCount - 1, switcherIndex + columns);
            } else if (key === Qt.Key_Up) {
                switcherIndex = Math.max(0, switcherIndex - columns);
            } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
                activateSwitcherIndex(switcherIndex);
            } else if (key === Qt.Key_L && (event.modifiers & Qt.MetaModifier) && (event.modifiers & Qt.ControlModifier)) {
                selectNext();
            } else if (key >= Qt.Key_1 && key <= Qt.Key_9 && !(event.modifiers & (Qt.ControlModifier | Qt.MetaModifier | Qt.AltModifier))) {
                applyIndex(key - Qt.Key_1);
            } else {
                return;
            }
            event.accepted = true;
        }
    }
}
