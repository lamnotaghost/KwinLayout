import QtQuick
import QtCore
import org.kde.kwin

Item {
    id: core

    readonly property int gapTolerance: 24
    readonly property int minOverlap: 120
    readonly property int hoverReach: 6
    readonly property int launchTimeoutMs: 45000
    readonly property int dragMinSize: 150

    readonly property string cacheBust: "?v=" + Date.now()
    readonly property url storeUrl: StandardPaths.writableLocation(StandardPaths.GenericConfigLocation) + "/windowlayoutsrc"

    property var edges: []
    property bool edgesDirty: true
    property var hoverEdge: null
    property var shownEdge: null
    property bool moveResizeActive: false
    property var pendingLaunches: []
    property var trackedWindows: ({})
    property var drag: null

    readonly property var handle: handleLoader.item
    readonly property var dropPreview: dropPreviewLoader.item
    property var overlay: null
    readonly property bool popupOpen: !!overlay && overlay.shown

    Component {
        id: settingsComponent
        Settings {
            location: core.storeUrl
            category: "Layouts"
        }
    }

    readonly property url runtimeUrl: StandardPaths.writableLocation(StandardPaths.GenericConfigLocation) + "/windowlayouts-runtimerc"

    Component {
        id: runtimeComponent
        Settings {
            location: core.runtimeUrl
            category: "Runtime"
        }
    }

    function writeOpenApps() {
        var seen = {};
        var apps = [];
        windowList().filter(isLayoutWindow).forEach(function (w) {
            var key = String(w.desktopFileName || w.resourceClass || "").toLowerCase();
            if (!key || seen[key]) {
                return;
            }
            seen[key] = true;
            apps.push({
                app: appId(w),
                wmClass: String(w.resourceClass || ""),
                icon: windowIconName(w),
                title: windowAppName(w)
            });
        });
        var s = runtimeComponent.createObject(core);
        s.setValue("openApps", JSON.stringify(apps));
        s.setValue("minSizes", JSON.stringify(collectMinSizes(s.value("minSizes", ""))));
        var areas = [];
        var screens = Workspace.screens;
        for (var i = 0; i < screens.length; ++i) {
            var a = screenArea(screens[i]);
            areas.push({ name: screens[i].name, w: a.width, h: a.height });
        }
        s.setValue("screenAreas", JSON.stringify(areas));
        s.sync();
        s.destroy();
    }

    function collectMinSizes(raw) {
        var known;
        try {
            known = raw ? JSON.parse(raw) : {};
        } catch (e) {
            known = {};
        }
        if (!known || typeof known !== "object" || Array.isArray(known)) {
            known = {};
        }
        var fresh = {};
        windowList().filter(isLayoutWindow).forEach(function (w) {
            var mw = Math.ceil(minExtent(w, true)), mh = Math.ceil(minExtent(w, false));
            [w.desktopFileName, w.resourceClass].forEach(function (k) {
                k = String(k || "").toLowerCase().replace(/\.desktop$/, "");
                if (!k) {
                    return;
                }
                var cur = fresh[k] || { w: 0, h: 0 };
                fresh[k] = { w: Math.max(cur.w, mw), h: Math.max(cur.h, mh) };
            });
        });
        for (var k in fresh) {
            known[k] = fresh[k];
        }
        return known;
    }

    property real lastApplyRequest: 0

    function onReconfigureRequest() {
        var s = runtimeComponent.createObject(core);
        var raw = s.value("applyRequest", "");
        s.destroy();
        var req;
        try {
            req = raw ? JSON.parse(raw) : null;
        } catch (e) {
            req = null;
        }
        if (!req || !req.id || !req.at || req.at <= lastApplyRequest || Date.now() - req.at > 10000) {
            return;
        }
        lastApplyRequest = req.at;
        var t = loadTemplates().filter(function (x) { return x.id === req.id; })[0];
        if (!t) {
            console.warn("windowlayouts: шаблон из настроек не найден: " + req.id);
            return;
        }
        console.log("windowlayouts: применяю из настроек «" + t.name + "»");
        if (overlay) {
            overlay.requestApply(t);
        } else {
            applyTemplate(t);
        }
    }

    Timer {
        id: openAppsTimer
        interval: 1000
        onTriggered: core.writeOpenApps()
    }

    function loadTemplates() {
        var s = settingsComponent.createObject(core);
        var raw = s.value("templates", "");
        s.destroy();
        if (!raw) {
            return [];
        }
        try {
            var data = JSON.parse(raw);
            return Array.isArray(data.templates) ? data.templates : [];
        } catch (e) {
            console.warn("windowlayouts: повреждён файл шаблонов: " + e);
            return [];
        }
    }

    function saveTemplates(list) {
        var s = settingsComponent.createObject(core);
        s.setValue("templates", JSON.stringify({ version: 1, templates: list }));
        s.sync();
        s.destroy();
    }

    function addTemplate(t) {
        var list = loadTemplates();
        list.push(t);
        saveTemplates(list);
    }

    function windowList() {
        var l = Workspace.stackingOrder;
        var out = [];
        for (var i = 0; i < l.length; ++i) {
            out.push(l[i]);
        }
        return out;
    }

    function onCurrentDesktop(w) {
        if (!w.onAllDesktops && w.desktops.indexOf(Workspace.currentDesktop) === -1) {
            return false;
        }
        var acts = w.activities;
        return !acts || acts.length === 0 || acts.indexOf(Workspace.currentActivity) !== -1;
    }

    function isLayoutWindow(w) {
        return w && !w.deleted && w.normalWindow && !w.skipTaskbar && !w.specialWindow;
    }

    function isVisibleLayoutWindow(w) {
        return isLayoutWindow(w) && !w.minimized && !w.fullScreen && onCurrentDesktop(w);
    }

    function rectOf(w) {
        var g = w.frameGeometry;
        return { x: g.x, y: g.y, w: g.width, h: g.height, r: g.x + g.width, b: g.y + g.height };
    }

    function screenArea(output) {
        return Workspace.clientArea(Workspace.MaximizeArea, output, Workspace.currentDesktop);
    }

    function fullArea(output) {
        return Workspace.clientArea(Workspace.FullScreenArea, output, Workspace.currentDesktop);
    }

    function screenAt(p) {
        return Workspace.screenAt(Qt.point(p.x, p.y)) || Workspace.activeScreen;
    }

    function cursorPos() {
        var p = Workspace.cursorPos;
        return Qt.point(p.x, p.y);
    }

    function topmostAt(x, y) {
        var list = windowList();
        for (var i = list.length - 1; i >= 0; --i) {
            var w = list[i];
            if (w.deleted || w.minimized || w.desktopWindow || !w.managed || !onCurrentDesktop(w)) {
                continue;
            }
            var g = w.frameGeometry;
            if (x >= g.x && x < g.x + g.width && y >= g.y && y < g.y + g.height) {
                return w;
            }
        }
        return null;
    }

    function appId(w) {
        return String(w.desktopFileName || "");
    }

    function sameApp(slot, w) {
        var keys = [String(w.desktopFileName || ""), String(w.resourceClass || ""), String(w.resourceName || "")]
            .filter(function (k) { return k.length > 0; })
            .map(function (k) { return k.toLowerCase(); });
        var wanted = [slot.app, slot.wmClass]
            .filter(function (k) { return k && k.length > 0; })
            .map(function (k) { return String(k).toLowerCase().replace(/\.desktop$/, ""); });
        for (var i = 0; i < wanted.length; ++i) {
            if (keys.indexOf(wanted[i]) !== -1) {
                return true;
            }
        }
        return false;
    }

    function prettyAppName(id) {
        var generic = ["org", "com", "net", "io", "app", "de", "desktop", "kde", "gnome"];
        var parts = String(id).split(".").filter(function (p) {
            return p.length > 0 && p.charAt(0) !== "_" && generic.indexOf(p.toLowerCase()) === -1;
        });
        var name = parts.length > 0 ? parts[parts.length - 1] : String(id);
        return name.replace(/[-_]+/g, " ").replace(/\b\w/g, function (c) { return c.toUpperCase(); });
    }

    Component {
        id: desktopFileComponent
        Settings {
            category: "Desktop Entry"
        }
    }

    property var desktopEntryCache: ({})

    function settingString(s, key) {
        var v = s.value(key, "");
        return Array.isArray(v) ? v.join(", ") : String(v || "");
    }

    function desktopEntry(id) {
        id = String(id || "").replace(/\.desktop$/, "");
        if (!id) {
            return null;
        }
        if (desktopEntryCache.hasOwnProperty(id)) {
            return desktopEntryCache[id];
        }
        var entry = null;
        var lang = Qt.locale().name;
        var dirs = StandardPaths.standardLocations(StandardPaths.GenericDataLocation);
        for (var i = 0; i < dirs.length && !entry; ++i) {
            var s = desktopFileComponent.createObject(core, { location: dirs[i] + "/applications/" + id + ".desktop" });
            var icon = settingString(s, "Icon");
            var name = settingString(s, "Name[" + lang + "]") || settingString(s, "Name[" + lang.split("_")[0] + "]")
                || settingString(s, "Name");
            s.destroy();
            if (icon || name) {
                entry = { name: name, icon: icon };
            }
        }
        desktopEntryCache[id] = entry;
        return entry;
    }

    function slotIcon(slot) {
        var entry = desktopEntry(slot.app);
        return (entry && entry.icon) || slot.icon || slot.app || "application-x-executable";
    }

    function windowAppName(w) {
        var entry = desktopEntry(w.desktopFileName);
        return entry && entry.name ? entry.name : prettyAppName(w.desktopFileName || w.resourceClass || w.caption);
    }

    function windowIconName(w) {
        var entry = desktopEntry(w.desktopFileName);
        return entry && entry.icon ? entry.icon : String(w.desktopFileName || w.resourceClass || "");
    }

    function markDirty() {
        core.edgesDirty = true;
    }

    function pushEdge(res, vertical, first, F, second, S, output) {
        var gap = vertical ? S.x - F.r : S.y - F.b;
        if (gap < -4 || gap > gapTolerance) {
            return;
        }
        var from = vertical ? Math.max(F.y, S.y) : Math.max(F.x, S.x);
        var to = vertical ? Math.min(F.b, S.b) : Math.min(F.r, S.r);
        if (to - from < minOverlap) {
            return;
        }
        var pos = (vertical ? F.r : F.b) + gap / 2;
        var full = fullArea(output);
        var lo = vertical ? full.x : full.y;
        var hi = vertical ? full.x + full.width : full.y + full.height;
        if (pos <= lo + 2 || pos >= hi - 2) {
            return;
        }
        res.push({
            vertical: vertical, pos: pos, half: Math.max(gap, 0) / 2,
            from: from, to: to, a: first, b: second, screen: output
        });
    }

    function computeEdges() {
        var ws = windowList().filter(isVisibleLayoutWindow);
        var res = [];
        for (var i = 0; i < ws.length; ++i) {
            for (var j = i + 1; j < ws.length; ++j) {
                var a = ws[i], b = ws[j];
                if (a.output !== b.output) {
                    continue;
                }
                var A = rectOf(a), B = rectOf(b);
                pushEdge(res, true, a, A, b, B, a.output);
                pushEdge(res, true, b, B, a, A, a.output);
                pushEdge(res, false, a, A, b, B, a.output);
                pushEdge(res, false, b, B, a, A, a.output);
            }
        }
        return res;
    }

    function edgeVisibleAt(e, along) {
        var off = e.half + 24;
        var p1 = e.vertical ? topmostAt(e.pos - off, along) : topmostAt(along, e.pos - off);
        var p2 = e.vertical ? topmostAt(e.pos + off, along) : topmostAt(along, e.pos + off);
        return p1 === e.a && p2 === e.b;
    }

    function edgeAt(p) {
        for (var i = 0; i < edges.length; ++i) {
            var e = edges[i];
            var across = e.vertical ? p.x : p.y;
            var along = e.vertical ? p.y : p.x;
            if (Math.abs(across - e.pos) <= e.half + hoverReach && along >= e.from && along <= e.to
                    && edgeVisibleAt(e, along)) {
                return e;
            }
        }
        return null;
    }

    function sameEdge(x, y) {
        return !!x && !!y && x.a === y.a && x.b === y.b && x.vertical === y.vertical;
    }

    function onCursorMoved() {
        if (!cursorSeen) {
            cursorSeen = true;
            console.log("windowlayouts: события курсора доходят");
        }
        if (popupOpen || moveResizeActive || drag) {
            return;
        }
        if (edgesDirty) {
            edges = computeEdges();
            edgesDirty = false;
        }
        var p = Workspace.cursorPos;
        if (handle && handle.containsGlobal(p)) {
            hideTimer.stop();
            return;
        }
        var e = edgeAt(p);
        if (e) {
            hideTimer.stop();
            if (!sameEdge(e, hoverEdge)) {
                hoverEdge = e;
                if (!sameEdge(e, shownEdge)) {
                    dwellTimer.restart();
                }
            }
        } else {
            hoverEdge = null;
            dwellTimer.stop();
            if (handle && handle.visible && !hideTimer.running) {
                hideTimer.start();
            }
        }
    }

    function showHandle() {
        var e = hoverEdge;
        if (!e || !handle || popupOpen || moveResizeActive || drag) {
            return;
        }
        var p = Workspace.cursorPos;
        var size = handle.handleSize;
        var along = e.vertical ? p.y : p.x;
        along = Math.max(e.from + 8, Math.min(e.to - size - 8, along - size / 2));
        shownEdge = e;
        handle.showAt(Qt.point(Math.round(e.vertical ? e.pos - size / 2 : along),
                               Math.round(e.vertical ? along : e.pos - size / 2)), e.vertical);
    }

    function hideHandle() {
        hideTimer.stop();
        dwellTimer.stop();
        if (drag) {
            return;
        }
        shownEdge = null;
        if (handle) {
            handle.hideHandle();
        }
        if (dropPreview) {
            dropPreview.hidePreview();
        }
    }

    function windowsAlongEdge(e) {
        var before = [], after = [];
        edges.forEach(function (x) {
            if (x.vertical === e.vertical && x.screen === e.screen && Math.abs(x.pos - e.pos) <= 2) {
                if (before.indexOf(x.a) === -1) before.push(x.a);
                if (after.indexOf(x.b) === -1) after.push(x.b);
            }
        });
        if (before.length === 0) {
            before = [e.a];
            after = [e.b];
        }
        return { before: before, after: after };
    }

    function beginDrag(startPos) {
        var e = shownEdge;
        if (!e || !handle) {
            return false;
        }
        var sides = windowsAlongEdge(e);
        var snap = function (w) {
            var g = w.frameGeometry;
            return { w: w, x: g.x, y: g.y, width: g.width, height: g.height,
                     min: Math.max(dragMinSize, Math.ceil(minExtent(w, e.vertical))) };
        };
        var all = sides.before.concat(sides.after);
        drag = {
            edge: e,
            start: startPos,
            before: sides.before.map(snap),
            after: sides.after.map(snap),
            tiled: all.every(function (w) { return !!w.tile; }),
            handleStart: Qt.point(handle.handlePos.x, handle.handlePos.y),
            full: fullArea(e.screen)
        };
        hideTimer.stop();
        dwellTimer.stop();
        return true;
    }

    function setTileEdge(tile, f, qtEdge, outSize) {
        var rg = tile.relativeGeometry;
        var cur = qtEdge === Qt.RightEdge ? rg.x + rg.width
                : qtEdge === Qt.LeftEdge ? rg.x
                : qtEdge === Qt.BottomEdge ? rg.y + rg.height
                : rg.y;
        if (Math.abs(cur - f) * outSize >= 0.5) {
            tile.resizeByPixels((f - cur) * outSize, qtEdge);
        }
    }

    function updateDrag() {
        if (!drag) {
            return;
        }
        var v = drag.edge.vertical;
        var p = Workspace.cursorPos;
        var d = v ? p.x - drag.start.x : p.y - drag.start.y;
        var lo = -Infinity, hi = Infinity;
        drag.before.forEach(function (s) { lo = Math.max(lo, Math.min(0, s.min - (v ? s.width : s.height))); });
        drag.after.forEach(function (s) { hi = Math.min(hi, Math.max(0, (v ? s.width : s.height) - s.min)); });
        d = Math.max(lo, Math.min(hi, d));

        if (drag.tiled) {
            var outSize = v ? drag.full.width : drag.full.height;
            var f = ((v ? drag.edge.pos - drag.full.x : drag.edge.pos - drag.full.y) + d) / outSize;
            var done = [];
            drag.before.forEach(function (s) {
                if (done.indexOf(s.w.tile) === -1) {
                    done.push(s.w.tile);
                    setTileEdge(s.w.tile, f, v ? Qt.RightEdge : Qt.BottomEdge, outSize);
                }
            });
            drag.after.forEach(function (s) {
                if (done.indexOf(s.w.tile) === -1) {
                    done.push(s.w.tile);
                    setTileEdge(s.w.tile, f, v ? Qt.LeftEdge : Qt.TopEdge, outSize);
                }
            });
        } else {
            drag.before.forEach(function (s) {
                s.w.frameGeometry = v ? Qt.rect(s.x, s.y, s.width + d, s.height)
                                      : Qt.rect(s.x, s.y, s.width, s.height + d);
            });
            drag.after.forEach(function (s) {
                s.w.frameGeometry = v ? Qt.rect(s.x + d, s.y, s.width - d, s.height)
                                      : Qt.rect(s.x, s.y + d, s.width, s.height - d);
            });
        }
        handle.moveTo(Qt.point(drag.handleStart.x + (v ? d : 0), drag.handleStart.y + (v ? 0 : d)));
    }

    function endDrag() {
        var old = drag ? drag.edge : null;
        drag = null;
        edges = computeEdges();
        edgesDirty = false;
        shownEdge = null;
        for (var i = 0; i < edges.length; ++i) {
            if (sameEdge(edges[i], old)) {
                shownEdge = edges[i];
                break;
            }
        }
        if (!shownEdge) {
            hideHandle();
        }
    }

    function groupForEdge(e) {
        var group = [e.a, e.b];
        var changed = true;
        while (changed) {
            changed = false;
            for (var i = 0; i < edges.length; ++i) {
                var x = edges[i];
                if (x.screen !== e.screen) {
                    continue;
                }
                var hasA = group.indexOf(x.a) !== -1, hasB = group.indexOf(x.b) !== -1;
                if (hasA !== hasB) {
                    group.push(hasA ? x.b : x.a);
                    changed = true;
                }
            }
        }
        group.sort(function (u, v) {
            var gu = u.frameGeometry, gv = v.frameGeometry;
            return gu.y - gv.y || gu.x - gv.x;
        });
        return group;
    }

    function round4(v) {
        return Math.round(v * 10000) / 10000;
    }

    function clampSlot(slot) {
        var x = Math.min(Math.max(slot.x, 0), 0.95), y = Math.min(Math.max(slot.y, 0), 0.95);
        slot.x = round4(x);
        slot.y = round4(y);
        slot.w = round4(Math.max(0.05, Math.min(slot.w, 1 - x)));
        slot.h = round4(Math.max(0.05, Math.min(slot.h, 1 - y)));
        return slot;
    }

    function slotFromWindow(w) {
        var area = screenArea(w.output);
        var g = w.tile ? w.tile.absoluteGeometry : w.frameGeometry;
        var id = appId(w);
        return clampSlot({
            app: id,
            wmClass: String(w.resourceClass || ""),
            icon: windowIconName(w),
            title: windowAppName(w),
            x: (g.x - area.x) / area.width,
            y: (g.y - area.y) / area.height,
            w: g.width / area.width,
            h: g.height / area.height
        });
    }

    function windowsForSave(output) {
        if (edgesDirty) {
            edges = computeEdges();
            edgesDirty = false;
        }
        var onScreen = function (w) {
            return isVisibleLayoutWindow(w) && w.output && w.output.name === output.name;
        };
        var group = [];
        edges.forEach(function (e) {
            [e.a, e.b].forEach(function (w) {
                if (onScreen(w) && group.indexOf(w) === -1) {
                    group.push(w);
                }
            });
        });
        if (group.length === 0) {
            group = windowList().filter(onScreen);
        }
        group.sort(function (u, v) {
            var gu = u.frameGeometry, gv = v.frameGeometry;
            return gu.y - gv.y || gu.x - gv.x;
        });
        return group;
    }

    function defaultName(group) {
        var names = [];
        group.forEach(function (w) {
            var n = windowAppName(w);
            if (names.indexOf(n) === -1) {
                names.push(n);
            }
        });
        return names.join(" + ");
    }

    function saveGroup(group, name) {
        var t = {
            id: "t" + Date.now(),
            name: name && name.trim().length > 0 ? name.trim() : defaultName(group),
            created: Date.now(),
            source: "divider",
            slots: group.map(slotFromWindow)
        };
        addTemplate(t);
        return t;
    }

    function minExtent(w, vertical) {
        var m = w.minSize;
        var f = w.frameGeometry, c = w.clientGeometry;
        var border = c ? Math.max(0, vertical ? f.width - c.width : f.height - c.height) : 0;
        return (m ? (vertical ? m.width : m.height) : 0) + border;
    }

    function windowRectFor(w, tile, fallback) {
        var r = fallback;
        if (tile) {
            var g = tile.absoluteGeometry, rg = tile.relativeGeometry, pad = tile.padding;
            var area = screenArea(screenAt(Qt.point(g.x + g.width / 2, g.y + g.height / 2)));
            var x1 = Math.max(g.x, area.x), y1 = Math.max(g.y, area.y);
            var x2 = Math.min(g.x + g.width, area.x + area.width);
            var y2 = Math.min(g.y + g.height, area.y + area.height);
            var ml = rg.x > 0 ? pad / 2 : pad;
            var mt = rg.y > 0 ? pad / 2 : pad;
            var mr = rg.x + rg.width < 1 ? pad / 2 : pad;
            var mb = rg.y + rg.height < 1 ? pad / 2 : pad;
            r = Qt.rect(x1 + ml, y1 + mt, x2 - x1 - ml - mr, y2 - y1 - mt - mb);
        }
        return Qt.rect(r.x, r.y, Math.max(r.width, minExtent(w, true)), Math.max(r.height, minExtent(w, false)));
    }

    function swapWindows(a, b) {
        var ga = rectOf(a), gb = rectOf(b);
        var tol = gapTolerance + 4;
        var vertical, aFirst;
        if (Math.abs(gb.x - ga.r) <= tol) {
            vertical = true; aFirst = true;
        } else if (Math.abs(ga.x - gb.r) <= tol) {
            vertical = true; aFirst = false;
        } else if (Math.abs(gb.y - ga.b) <= tol) {
            vertical = false; aFirst = true;
        } else if (Math.abs(ga.y - gb.b) <= tol) {
            vertical = false; aFirst = false;
        } else {
            var ra = Qt.rect(gb.x, gb.y, gb.w, gb.h), rb = Qt.rect(ga.x, ga.y, ga.w, ga.h);
            placeWindow(a, ra, null);
            placeWindow(b, rb, null);
            markDirty();
            return { a: windowRectFor(a, null, ra), b: windowRectFor(b, null, rb) };
        }
        var spot1 = aFirst ? ga : gb, spot2 = aFirst ? gb : ga;
        var win1 = aFirst ? b : a, win2 = aFirst ? a : b;
        var tile1 = (aFirst ? a : b).tile, tile2 = (aFirst ? b : a).tile;

        var start = vertical ? spot1.x : spot1.y;
        var finish = vertical ? spot2.r : spot2.b;
        var gap = vertical ? spot2.x - spot1.r : spot2.y - spot1.b;
        var boundary = vertical ? spot1.r : spot1.b;
        boundary = Math.max(boundary, start + minExtent(win1, vertical));
        boundary = Math.min(boundary, finish - gap - minExtent(win2, vertical));

        var r1 = vertical ? Qt.rect(start, spot1.y, boundary - start, spot1.h)
                          : Qt.rect(spot1.x, start, spot1.w, boundary - start);
        var r2 = vertical ? Qt.rect(boundary + gap, spot2.y, finish - boundary - gap, spot2.h)
                          : Qt.rect(spot2.x, boundary + gap, spot2.w, finish - boundary - gap);

        if (tile1 && tile2 && tile1 !== tile2) {
            tile1.manage(win1);
            tile2.manage(win2);
            if (boundary !== (vertical ? spot1.r : spot1.b)) {
                var full = fullArea(a.output);
                var outSize = vertical ? full.width : full.height;
                var f = (boundary + gap / 2 - (vertical ? full.x : full.y)) / outSize;
                setTileEdge(tile1, f, vertical ? Qt.RightEdge : Qt.BottomEdge, outSize);
                setTileEdge(tile2, f, vertical ? Qt.LeftEdge : Qt.TopEdge, outSize);
            }
        } else {
            placeWindow(win1, r1, null);
            placeWindow(win2, r2, null);
        }
        markDirty();
        var t1 = tile1 && tile2 && tile1 !== tile2 ? tile1 : null;
        var t2 = tile1 && tile2 && tile1 !== tile2 ? tile2 : null;
        var rect1 = windowRectFor(win1, t1, r1), rect2 = windowRectFor(win2, t2, r2);
        return aFirst ? { a: rect2, b: rect1 } : { a: rect1, b: rect2 };
    }

    function openMenu() {
        var e = shownEdge;
        if (!e || !overlay) {
            return;
        }
        var group = groupForEdge(e);
        var anchor = Qt.point(handle.handlePos.x + handle.handleSize / 2, handle.handlePos.y + handle.handleSize / 2);
        hideHandle();
        overlay.openMenu(e.screen, anchor, group, defaultName(group));
    }

    function slotRect(slot, area) {
        return Qt.rect(Math.round(area.x + slot.x * area.width),
                       Math.round(area.y + slot.y * area.height),
                       Math.round(slot.w * area.width),
                       Math.round(slot.h * area.height));
    }

    function sameRect(g, r, tolerance) {
        var t = tolerance === undefined ? 3 : tolerance;
        return Math.abs(g.x - r.x) <= t && Math.abs(g.y - r.y) <= t
            && Math.abs(g.width - r.width) <= t && Math.abs(g.height - r.height) <= t;
    }

    readonly property int tileSideBySide: 1
    readonly property int tileStacked: 2

    function layoutRoot(output) {
        return output ? Workspace.rootTile(output, Workspace.currentDesktop) : null;
    }

    function guillotine(items) {
        if (items.length === 1) {
            return { leaf: items[0].i };
        }
        var eps = 0.015;
        var dirs = [
            { dir: tileSideBySide, lo: "x", size: "w" },
            { dir: tileStacked, lo: "y", size: "h" }
        ];
        for (var d = 0; d < dirs.length; ++d) {
            var D = dirs[d];
            var cuts = items.map(function (it) { return it.r[D.lo]; })
                .sort(function (u, v) { return u - v; });
            for (var c = 0; c < cuts.length; ++c) {
                var cut = cuts[c];
                var before = items.filter(function (it) { return it.r[D.lo] + it.r[D.size] <= cut + eps; });
                var after = items.filter(function (it) { return it.r[D.lo] >= cut - eps; });
                if (before.length === 0 || after.length === 0 || before.length + after.length !== items.length) {
                    continue;
                }
                var a = guillotine(before), b = guillotine(after);
                if (!a || !b) {
                    return null;
                }
                var end = Math.max.apply(null, before.map(function (it) { return it.r[D.lo] + it.r[D.size]; }));
                var begin = Math.min.apply(null, after.map(function (it) { return it.r[D.lo]; }));
                return { dir: D.dir, cut: (end + begin) / 2, a: a, b: b };
            }
        }
        return null;
    }

    function childTiles(tile) {
        var kids = tile ? tile.tiles : null;
        var out = [];
        for (var i = 0; kids && i < kids.length; ++i) {
            out.push(kids[i]);
        }
        return out;
    }

    function removeChildTiles(root) {
        var order = [];
        var walk = function (t) {
            childTiles(t).forEach(walk);
            if (t !== root) {
                order.push(t);
            }
        };
        walk(root);
        order.forEach(function (t) {
            var ws = t.windows;
            for (var i = ws ? ws.length - 1 : -1; i >= 0; --i) {
                t.unmanage(ws[i]);
            }
        });
        order.forEach(function (t) {
            if (typeof t.remove === "function") {
                t.remove();
            }
        });
    }

    function buildTileTree(tile, node, out) {
        tile.padding = 0;
        if (node.leaf !== undefined) {
            out[node.leaf] = tile;
            return;
        }
        var parts = tile.split(node.dir);
        if (!parts || parts.length < 2 || !parts[0] || !parts[1]) {
            throw new Error("split failed");
        }
        var g = parts[0].relativeGeometry;
        parts[0].relativeGeometry = node.dir === tileSideBySide
            ? Qt.rect(g.x, g.y, node.cut - g.x, g.height)
            : Qt.rect(g.x, g.y, g.width, node.cut - g.y);
        buildTileTree(parts[0], node.a, out);
        buildTileTree(parts[1], node.b, out);
    }

    function tilesForTemplate(output, slots) {
        var root = layoutRoot(output);
        if (!root) {
            return null;
        }
        var area = screenArea(output);
        var full = fullArea(output);
        var items = slots.map(function (slot, i) {
            return { i: i, r: {
                x: (area.x - full.x + slot.x * area.width) / full.width,
                y: (area.y - full.y + slot.y * area.height) / full.height,
                w: slot.w * area.width / full.width,
                h: slot.h * area.height / full.height
            } };
        });
        var tree = guillotine(items);
        if (!tree) {
            return null;
        }
        var out = [];
        try {
            removeChildTiles(root);
            buildTileTree(root, tree, out);
        } catch (e) {
            console.warn("windowlayouts: не удалось построить плитки: " + e);
            return null;
        }
        return out;
    }

    function placeWindow(w, rect, slot, retry, tile) {
        if (w.minimized) {
            w.minimized = false;
        }
        if (!onCurrentDesktop(w)) {
            w.desktops = [Workspace.currentDesktop];
        }
        if (w.fullScreen) {
            w.fullScreen = false;
        }
        if (!retry && w.maximizeMode !== 0) {
            w.setMaximize(false, false);
            var later = delayedPlace.createObject(core, { target: w, targetRect: rect, slot: slot, tile: tile || null, interval: 250 });
            later.start();
            return;
        }
        if (tile) {
            if (w.tile === tile && retry) {
                tile.unmanage(w);
            }
            if (w.tile !== tile && !tile.manage(w)) {
                console.warn("windowlayouts: KWin не поставил " + windowAppName(w) + " в плитку");
                w.frameGeometry = Qt.rect(tile.absoluteGeometry.x, tile.absoluteGeometry.y,
                                          tile.absoluteGeometry.width, tile.absoluteGeometry.height);
            }
            return;
        }
        if (sameRect(w.frameGeometry, rect)) {
            return;
        }
        if (w.tile) {
            w.tile.unmanage(w);
        }
        w.frameGeometry = rect;
    }

    function allowAll() {
        return true;
    }

    function choiceFilter(chosen) {
        if (!chosen) {
            return allowAll;
        }
        var picked = [];
        chosen.forEach(function (w) {
            if (w && !w.deleted) {
                picked.push(w);
            }
        });
        return function (s, w) {
            var mine = chosen[s];
            if (mine && !mine.deleted) {
                return w === mine;
            }
            return picked.indexOf(w) === -1;
        };
    }

    function templateContext(t) {
        var output = screenAt(Workspace.cursorPos);
        var candidates = windowList().filter(isLayoutWindow).sort(function (u, v) {
            var cu = onCurrentDesktop(u) ? 1 : 0, cv = onCurrentDesktop(v) ? 1 : 0;
            return (cv - cu) || (v.stackingOrder - u.stackingOrder);
        });
        var slots = t.slots.map(function (slot) { return clampSlot(JSON.parse(JSON.stringify(slot))); });
        return { output: output, area: screenArea(output), candidates: candidates, slots: slots };
    }

    function windowChoices(t) {
        if (!t || !t.slots || t.slots.length === 0) {
            return [];
        }
        var c = templateContext(t);
        if (templateAlreadyApplied(c.output, c.area, c.slots, c.candidates, allowAll)) {
            return [];
        }
        var out = [];
        c.slots.forEach(function (slot, i) {
            var mine = c.candidates.filter(function (w) { return sameApp(slot, w); });
            if (mine.length === 0) {
                return;
            }
            var need = c.slots.filter(function (s) { return sameApp(s, mine[0]); }).length;
            if (mine.length > need) {
                out.push({ index: i, slot: slot, windows: mine });
            }
        });
        return out;
    }

    function templateAlreadyApplied(output, area, slots, candidates, allow) {
        var root = layoutRoot(output);
        var used = [];
        for (var s = 0; s < slots.length; ++s) {
            var rect = slotRect(slots[s], area);
            var found = null;
            for (var i = 0; i < candidates.length && !found; ++i) {
                var w = candidates[i];
                if (used.indexOf(w) !== -1 || !sameApp(slots[s], w) || !allow(s, w) || !isVisibleLayoutWindow(w)
                        || !w.output || w.output.name !== output.name || !w.tile || !tileInTree(w.tile, root)) {
                    continue;
                }
                if (sameRect(w.tile.absoluteGeometry, rect, 8)) {
                    found = w;
                }
            }
            if (!found) {
                return false;
            }
            used.push(found);
        }
        return true;
    }

    function adjustExistingLayout(output, area, slots, candidates, allow) {
        var root = layoutRoot(output);
        if (!root) {
            return null;
        }
        var full = fullArea(output);
        var pairs = [];
        var usedWindows = [], usedTiles = [];
        for (var s = 0; s < slots.length; ++s) {
            var found = null;
            for (var i = 0; i < candidates.length && !found; ++i) {
                var w = candidates[i];
                if (usedWindows.indexOf(w) !== -1 || !sameApp(slots[s], w) || !allow(s, w) || !isVisibleLayoutWindow(w)
                        || !w.output || w.output.name !== output.name || !w.tile
                        || usedTiles.indexOf(w.tile) !== -1 || !tileInTree(w.tile, root)) {
                    continue;
                }
                found = w;
            }
            if (!found) {
                return null;
            }
            usedWindows.push(found);
            usedTiles.push(found.tile);
            var rect = slotRect(slots[s], area);
            var g = found.frameGeometry;
            pairs.push({
                w: found, tile: found.tile, rect: rect,
                from: { x: g.x, y: g.y, w: g.width, h: g.height },
                l: (rect.x - full.x) / full.width,
                r: (rect.x + rect.width - full.x) / full.width,
                t: (rect.y - full.y) / full.height,
                b: (rect.y + rect.height - full.y) / full.height
            });
        }
        for (var pass = 0; pass < 3; ++pass) {
            pairs.forEach(function (p) {
                setTileEdge(p.tile, p.l, Qt.LeftEdge, full.width);
                setTileEdge(p.tile, p.r, Qt.RightEdge, full.width);
                setTileEdge(p.tile, p.t, Qt.TopEdge, full.height);
                setTileEdge(p.tile, p.b, Qt.BottomEdge, full.height);
            });
        }
        var ok = pairs.every(function (p) { return sameRect(p.tile.absoluteGeometry, p.rect, 8); });
        if (!ok) {
            return null;
        }
        return pairs.map(function (p) {
            var r = windowRectFor(p.w, p.tile, p.rect);
            return { w: p.w, from: p.from, to: { x: r.x, y: r.y, w: r.width, h: r.height } };
        });
    }

    function leafTiles(root) {
        var out = [];
        var walk = function (t) {
            var kids = childTiles(t);
            if (kids.length === 0) {
                out.push(t);
            } else {
                kids.forEach(walk);
            }
        };
        if (root) {
            walk(root);
        }
        return out;
    }

    function reuseTiles(output, area, slots) {
        var root = layoutRoot(output);
        if (!root || childTiles(root).length === 0) {
            return null;
        }
        var all = [];
        var walk = function (t) {
            all.push(t);
            childTiles(t).forEach(walk);
        };
        walk(root);
        var leaves = all.filter(function (t) { return childTiles(t).length === 0; });
        var splits = all.filter(function (t) { return childTiles(t).length > 0; });
        var ordered = leaves.concat(splits);

        var out = [];
        var nested = function (a, b) { return tileInTree(a, b) || tileInTree(b, a); };
        for (var s = 0; s < slots.length; ++s) {
            var rect = slotRect(slots[s], area);
            var found = null;
            for (var i = 0; i < ordered.length && !found; ++i) {
                var t = ordered[i];
                if (!sameRect(t.absoluteGeometry, rect, 8)) {
                    continue;
                }
                if (out.some(function (o) { return nested(o, t); })) {
                    continue;
                }
                found = t;
            }
            if (!found) {
                return null;
            }
            out.push(found);
        }
        out.forEach(function (t) {
            if (childTiles(t).length > 0) {
                removeChildTiles(t);
                t.padding = 0;
            }
        });
        return out;
    }

    function applyTemplate(t, chosen) {
        if (!t || !t.slots || t.slots.length === 0) {
            return [];
        }
        var c = templateContext(t);
        var output = c.output, area = c.area, candidates = c.candidates, slots = c.slots;
        var allow = choiceFilter(chosen);
        if (templateAlreadyApplied(output, area, slots, candidates, allow)) {
            console.log("windowlayouts: «" + t.name + "» уже применён на экране " + output.name + " — ничего не меняю");
            return [];
        }
        var tiles = reuseTiles(output, area, slots);
        var reused = !!tiles;
        if (!tiles) {
            var adjusted = adjustExistingLayout(output, area, slots, candidates, allow);
            if (adjusted) {
                console.log("windowlayouts: «" + t.name + "» — та же раскладка, сдвигаю границы плиток");
                raiseWindows(adjusted.map(function (m) { return m.w; }));
                markDirty();
                return adjusted;
            }
            tiles = tilesForTemplate(output, slots);
        }
        console.log("windowlayouts: применяю «" + t.name + "» на экран " + output.name
                    + (reused ? " (готовые плитки раскладки)" : tiles ? " (новая раскладка)" : " (без плиток: шаблон не раскладывается на деления)"));
        var used = [];
        var placed = [];
        var moves = [];
        var now = Date.now();
        pendingLaunches = pendingLaunches.filter(function (p) { return p.deadline > now; });

        slots.forEach(function (slot, index) {
            var rect = slotRect(slot, area);
            var tile = tiles ? tiles[index] : null;
            var w = null;
            if (tile) {
                var inTile = tile.windows;
                for (var k = 0; inTile && k < inTile.length && !w; ++k) {
                    if (used.indexOf(inTile[k]) === -1 && sameApp(slot, inTile[k]) && allow(index, inTile[k])) {
                        w = inTile[k];
                    }
                }
            }
            for (var i = 0; i < candidates.length && !w; ++i) {
                if (used.indexOf(candidates[i]) === -1 && sameApp(slot, candidates[i]) && allow(index, candidates[i])) {
                    w = candidates[i];
                    break;
                }
            }
            if (w) {
                used.push(w);
                if (isVisibleLayoutWindow(w)) {
                    var g = w.frameGeometry;
                    var target = windowRectFor(w, tile, rect);
                    moves.push({
                        w: w,
                        from: { x: g.x, y: g.y, w: g.width, h: g.height },
                        to: { x: target.x, y: target.y, w: target.width, h: target.height }
                    });
                }
                placeWindow(w, rect, slot, false, tile);
                placed.push(w);
                console.log("windowlayouts:   " + (slot.title || slot.app) + " → "
                            + (tile ? "плитка " + JSON.stringify(tile.absoluteGeometry) : "геометрия " + rect));
            } else if (slot.app) {
                pendingLaunches.push({ slot: slot, rect: rect, tile: tile, deadline: now + launchTimeoutMs });
                console.log("windowlayouts:   " + (slot.title || slot.app) + " → запускаю");
                launchApp(slot.app);
            } else {
                console.warn("windowlayouts: не знаю, как запустить " + (slot.title || slot.wmClass));
            }
        });
        raiseWindows(placed);
        markDirty();
        return moves;
    }

    function raiseWindows(list) {
        for (var i = list.length - 1; i >= 0; --i) {
            Workspace.raiseWindow(list[i]);
        }
        if (list.length > 0) {
            Workspace.activeWindow = list[0];
        }
    }

    function handleNewWindow(w) {
        trackWindow(w);
        markDirty();
        if (!isLayoutWindow(w) || pendingLaunches.length === 0) {
            return;
        }
        var now = Date.now();
        for (var i = 0; i < pendingLaunches.length; ++i) {
            var p = pendingLaunches[i];
            if (p.deadline > now && sameApp(p.slot, w)) {
                pendingLaunches.splice(i, 1);
                placeWindow(w, p.rect, p.slot, false, p.tile);
                raiseWindows([w]);
                var again = delayedPlace.createObject(core, { target: w, targetRect: p.rect, slot: p.slot, tile: p.tile || null, raise: true });
                again.start();
                return;
            }
        }
    }

    Component {
        id: delayedPlace
        Timer {
            property var target
            property rect targetRect
            property var slot
            property var tile: null
            property bool raise: false
            interval: 600
            onTriggered: {
                if (target && !target.deleted) {
                    core.placeWindow(target, targetRect, slot, true, tile);
                    if (raise) {
                        core.raiseWindows([target]);
                    }
                }
                destroy();
            }
        }
    }

    Component {
        id: startUnitCall
        DBusCall {
            service: "org.freedesktop.systemd1"
            path: "/org/freedesktop/systemd1"
            dbusInterface: "org.freedesktop.systemd1.Manager"
            method: "StartUnit"
        }
    }

    function systemdEscape(s) {
        var out = "";
        var bytes = unescape(encodeURIComponent(s));
        for (var i = 0; i < bytes.length; ++i) {
            var ch = bytes.charAt(i);
            if (/[A-Za-z0-9:_]/.test(ch) || (ch === "." && i > 0)) {
                out += ch;
            } else if (ch === "/") {
                out += "-";
            } else {
                var hex = bytes.charCodeAt(i).toString(16);
                out += "\\x" + (hex.length < 2 ? "0" + hex : hex);
            }
        }
        return out;
    }

    function startUnit(name) {
        var call = startUnitCall.createObject(core, { arguments: [name, "replace"] });
        call.finished.connect(function () { call.destroy(); });
        call.failed.connect(function () {
            console.warn("windowlayouts: systemd не запустил " + name);
            call.destroy();
        });
        call.call();
    }

    function launchApp(desktopId) {
        startUnit("windowlayouts-launch@" + systemdEscape(String(desktopId).replace(/\.desktop$/, "")) + ".service");
    }

    function openSettings() {
        launchApp("windowlayouts-settings");
    }

    function toggleSwitcher() {
        console.log("windowlayouts: хоткей переключателя, эффект " + (overlay ? (overlay.shown ? "открыт" : "закрыт") : "не загружен"));
        if (!overlay) {
            return;
        }
        if (overlay.open) {
            if (overlay.mode === "switcher") {
                overlay.selectNext();
            }
            return;
        }
        hideHandle();
        var output = screenAt(Workspace.cursorPos);
        var area = screenArea(output);
        var list = loadTemplates();
        console.log("windowlayouts: открываю переключатель на " + output.name + ", шаблонов: " + list.length);
        overlay.openSwitcher(output, area.width / area.height, list);
    }

    function trackWindow(w) {
        var key = String(w.internalId);
        if (trackedWindows[key]) {
            return;
        }
        trackedWindows[key] = windowWatcher.createObject(core, { target: w });
    }

    Component {
        id: windowWatcher
        Connections {
            ignoreUnknownSignals: true
            function onFrameGeometryChanged() { core.markDirty(); }
            function onMinimizedChanged() { core.markDirty(); }
            function onDesktopsChanged() { core.markDirty(); }
            function onOutputChanged() { core.markDirty(); }
            function onInteractiveMoveResizeStarted() { core.onMoveResizeStarted(target); }
            function onInteractiveMoveResizeStepped() { core.onMoveResizeStepped(target); }
            function onInteractiveMoveResizeFinished() { core.onMoveResizeFinished(target); }
        }
    }

    property var movingWindow: null
    property var dropTile: null
    readonly property int edgeZone: 20
    readonly property real cornerRatio: 0.25

    function tileInTree(tile, root) {
        for (var t = tile; t; t = t.parent) {
            if (t === root) {
                return true;
            }
        }
        return false;
    }

    function layoutInUse(root, except) {
        var used = false;
        var walk = function (t) {
            var ws = t.windows;
            for (var i = 0; ws && i < ws.length && !used; ++i) {
                if (ws[i] !== except) {
                    used = true;
                }
            }
            childTiles(t).forEach(walk);
        };
        if (root && childTiles(root).length > 0) {
            walk(root);
        }
        return used;
    }

    function edgeDropTarget(w, p) {
        var output = screenAt(p);
        var area = screenArea(output);
        var nearEdge = p.x <= area.x + edgeZone || p.x >= area.x + area.width - edgeZone;
        if (!nearEdge) {
            return null;
        }
        var root = layoutRoot(output);
        if (!layoutInUse(root, w)) {
            return null;
        }
        var tile = root.pick(p.x, p.y);
        if (!tile || tile.isLayout) {
            return null;
        }
        var corner = area.height * cornerRatio;
        var top = p.y <= area.y + corner;
        var bottom = p.y >= area.y + area.height - corner;

        var col = tile.parent;
        if (!top && !bottom && col && col !== root && col.layoutDirection === tileStacked
                && !tileHasWindows(col, w)) {
            var cg = col.absoluteGeometry;
            return { tile: col, half: null, merge: true, rect: Qt.rect(cg.x, cg.y, cg.width, cg.height) };
        }

        var g = tile.absoluteGeometry;
        var rect = Qt.rect(g.x, g.y, g.width, g.height);
        var fullHeight = g.y <= area.y + 2 && g.y + g.height >= area.y + area.height - 2;
        var half = null;
        if (fullHeight && top) {
            half = "top";
            rect = Qt.rect(g.x, g.y, g.width, g.height / 2);
        } else if (fullHeight && bottom) {
            half = "bottom";
            rect = Qt.rect(g.x, g.y + g.height / 2, g.width, g.height / 2);
        }
        return { tile: tile, half: half, rect: rect };
    }

    function tileHasWindows(tile, except) {
        var ws = tile.windows;
        for (var i = 0; ws && i < ws.length; ++i) {
            if (ws[i] !== except) {
                return true;
            }
        }
        var kids = childTiles(tile);
        for (var k = 0; k < kids.length; ++k) {
            if (tileHasWindows(kids[k], except)) {
                return true;
            }
        }
        return false;
    }

    function dropIntoTarget(w, target) {
        if (target.merge) {
            removeChildTiles(target.tile);
            target.tile.padding = 0;
            if (!target.tile.manage(w)) {
                console.warn("windowlayouts: не удалось слить колонку, ставлю в плитку под курсором");
                var p = cursorPos();
                var t = layoutRoot(screenAt(p)).pick(p.x, p.y);
                if (t && !t.isLayout) {
                    t.manage(w);
                    return [{ w: w, to: windowRectFor(w, t, null) }];
                }
                return [];
            }
            return [{ w: w, to: windowRectFor(w, target.tile, null) }];
        }
        if (!target.half) {
            if (w.tile !== target.tile) {
                target.tile.manage(w);
            }
            return [{ w: w, to: windowRectFor(w, target.tile, null) }];
        }
        var others = [];
        var ws = target.tile.windows;
        for (var i = 0; ws && i < ws.length; ++i) {
            if (ws[i] !== w) {
                others.push(ws[i]);
            }
        }
        var parts = target.tile.split(tileStacked);
        if (!parts || parts.length < 2) {
            target.tile.manage(w);
            return [{ w: w, to: windowRectFor(w, target.tile, null) }];
        }
        parts[0].padding = 0;
        parts[1].padding = 0;
        var mine = target.half === "top" ? parts[0] : parts[1];
        var other = target.half === "top" ? parts[1] : parts[0];
        mine.manage(w);
        others.forEach(function (o) { other.manage(o); });
        var moves = [{ w: w, to: windowRectFor(w, mine, null) }];
        others.forEach(function (o) { moves.push({ w: o, to: windowRectFor(o, other, null) }); });
        return moves;
    }

    property var savedEdgeTiling: undefined

    function suppressEdgeTiling(suppress) {
        if (suppress) {
            if (savedEdgeTiling === undefined) {
                savedEdgeTiling = Options.electricBorderTiling;
            }
            if (Options.electricBorderTiling) {
                Options.electricBorderTiling = false;
            }
        } else if (savedEdgeTiling !== undefined) {
            Options.electricBorderTiling = savedEdgeTiling;
            savedEdgeTiling = undefined;
        }
    }

    function layoutUsedAt(w, p) {
        return layoutInUse(layoutRoot(screenAt(p)), w);
    }

    function onMoveResizeStarted(w) {
        moveResizeActive = true;
        hideHandle();
        movingWindow = w && w.move ? w : null;
        dropTile = null;
        if (movingWindow) {
            suppressEdgeTiling(layoutUsedAt(movingWindow, cursorPos()));
        }
    }

    function onMoveResizeStepped(w) {
        if (!movingWindow || w !== movingWindow) {
            return;
        }
        var p = cursorPos();
        suppressEdgeTiling(layoutUsedAt(w, p));
        var target = edgeDropTarget(w, p);
        if (target && dropPreview) {
            dropPreview.showAt(target.rect);
        } else if (dropPreview) {
            dropPreview.hidePreview();
        }
        dropTile = target;
    }

    function onMoveResizeFinished(w) {
        moveResizeActive = false;
        markDirty();
        var moving = movingWindow;
        movingWindow = null;
        if (!moving || w !== moving) {
            return;
        }
        var target = moving.deleted ? null : edgeDropTarget(moving, cursorPos());
        dropTile = null;
        if (dropPreview) {
            dropPreview.hidePreview();
        }
        suppressEdgeTiling(false);
        if (target) {
            console.log("windowlayouts: " + windowAppName(moving) + " у края → "
                        + (target.merge ? "колонка целиком " : target.half ? "половина плитки (" + target.half + ") " : "плитка ")
                        + JSON.stringify(target.rect));
            var before = {};
            windowList().forEach(function (x) {
                if (isVisibleLayoutWindow(x)) {
                    var g = x.frameGeometry;
                    before[String(x.internalId)] = { x: g.x, y: g.y, w: g.width, h: g.height };
                }
            });
            var moves = dropIntoTarget(moving, target) || [];
            raiseWindows([moving]);
            if (overlay) {
                overlay.playMoves(moves.filter(function (m) {
                    return before[String(m.w.internalId)];
                }).map(function (m) {
                    return { w: m.w, from: before[String(m.w.internalId)],
                             to: { x: m.to.x, y: m.to.y, w: m.to.width, h: m.to.height } };
                }));
            }
        }
    }

    function closePopups() {
        if (overlay && overlay.shown) {
            overlay.close();
        }
    }

    Timer {
        id: dwellTimer
        interval: 250
        onTriggered: core.showHandle()
    }

    Timer {
        id: hideTimer
        interval: 450
        onTriggered: core.hideHandle()
    }

    Connections {
        target: Workspace
        function onCursorPosChanged() { core.onCursorMoved(); }
        function onWindowAdded(w) { core.handleNewWindow(w); openAppsTimer.restart(); }
        function onWindowRemoved(w) {
            openAppsTimer.restart();
            var key = String(w.internalId);
            var watcher = core.trackedWindows[key];
            if (watcher && watcher.destroy) {
                watcher.destroy();
            }
            delete core.trackedWindows[key];
            core.markDirty();
            core.hideHandle();
        }
        function onWindowActivated() { core.markDirty(); }
        function onCurrentDesktopChanged() { core.markDirty(); core.hideHandle(); core.closePopups(); }
        function onCurrentActivityChanged() { core.markDirty(); core.hideHandle(); core.closePopups(); }
        function onScreensChanged() { core.markDirty(); core.hideHandle(); core.closePopups(); openAppsTimer.restart(); }
    }

    ShortcutHandler {
        name: "WindowLayoutsSwitcher"
        text: "Шаблоны окон: показать переключатель"
        sequence: "Meta+Ctrl+L"
        onActivated: core.toggleSwitcher()
        Component.onCompleted: console.log("windowlayouts: хоткей зарегистрирован: " + sequence)
    }

    Loader { id: handleLoader }
    Loader { id: dropPreviewLoader }

    Component.onDestruction: {
        suppressEdgeTiling(false);
        if (overlay) {
            overlay.closeNow();
        }
        if (handle) {
            handle.hideHandle();
        }
        if (dropPreview) {
            dropPreview.hidePreview();
        }
    }

    property bool cursorSeen: false

    Component.onCompleted: {
        openAppsTimer.start();
        windowList().forEach(trackWindow);
        handleLoader.setSource(Qt.resolvedUrl("Handle.qml") + cacheBust, { core: core });
        dropPreviewLoader.setSource(Qt.resolvedUrl("DropPreview.qml") + cacheBust, {});
        console.log("windowlayouts: загружен (кнопка: " + (handle ? "да" : "нет") + ", эффект: " + (overlay ? "да" : "нет")
                    + ", быстрый тайлинг KWin: " + Options.electricBorderTiling + ")");
    }
}
