#!/usr/bin/env python3

import json
import os
import subprocess
import sys
import time

import dbus
from PyQt6.QtCore import (
    QFileSystemWatcher, QKeyCombination, QLibraryInfo, QLocale, QMimeData, QPoint, QRectF, QSettings,
    QSize, Qt, QTimer, QTranslator, pyqtSignal,
)
from PyQt6.QtGui import QColor, QDrag, QIcon, QKeySequence, QPainter, QPainterPath, QPalette, QPen, QPixmap
from PyQt6.QtNetwork import QLocalServer, QLocalSocket
from PyQt6.QtWidgets import (
    QAbstractItemView, QApplication, QButtonGroup, QCheckBox, QDialog, QDialogButtonBox,
    QFormLayout, QFrame, QGroupBox, QHBoxLayout, QInputDialog, QKeySequenceEdit, QLabel,
    QLineEdit, QListWidget, QListWidgetItem, QMessageBox, QPushButton, QSlider, QTabWidget,
    QToolButton, QVBoxLayout, QWidget,
)

STORE_PATH = os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "windowlayoutsrc")
STORE_KEY = "Layouts/templates"
SCRIPT_ID = "windowlayouts"
SHORTCUT_ACTION = ["kwin", "WindowLayoutsSwitcher", "KWin", "Шаблоны окон: показать переключатель"]
DEFAULT_SHORTCUT = "Meta+Ctrl+L"
INSTANCE_NAME = "windowlayouts-settings"
FALLBACK_ICON = "application-x-executable"


class TemplateStore:

    @staticmethod
    def load():
        settings = QSettings(STORE_PATH, QSettings.Format.IniFormat)
        raw = settings.value(STORE_KEY, "")
        if not raw:
            return []
        try:
            data = json.loads(raw)
        except ValueError:
            return []
        templates = data.get("templates") if isinstance(data, dict) else None
        return templates if isinstance(templates, list) else []

    @staticmethod
    def save(templates):
        settings = QSettings(STORE_PATH, QSettings.Format.IniFormat)
        settings.setValue(STORE_KEY, json.dumps({"version": 1, "templates": templates}, ensure_ascii=False))
        settings.sync()


def _data_dirs():
    home = os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share")
    system = os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share"
    dirs = [home] + [d for d in system.split(":") if d]
    seen, result = set(), []
    for d in dirs:
        if d not in seen:
            seen.add(d)
            result.append(d)
    return result


def _parse_desktop_file(path):
    entry, in_main = {}, False
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if line.startswith("["):
                    in_main = line == "[Desktop Entry]"
                    continue
                if in_main and "=" in line and not line.startswith("#"):
                    key, value = line.split("=", 1)
                    entry[key.strip()] = value.strip()
    except OSError:
        return None
    return entry


class AppCatalog:

    def __init__(self):
        self.apps = {}
        lang = (os.environ.get("LANG") or "ru_RU").split(".")[0]
        name_keys = ["Name[%s]" % lang, "Name[%s]" % lang.split("_")[0], "Name"]
        for base in _data_dirs():
            root = os.path.join(base, "applications")
            if not os.path.isdir(root):
                continue
            for dirpath, _dirs, files in os.walk(root):
                for fn in files:
                    if not fn.endswith(".desktop"):
                        continue
                    path = os.path.join(dirpath, fn)
                    app_id = os.path.relpath(path, root)[:-len(".desktop")].replace("/", "-")
                    if app_id in self.apps:
                        continue
                    e = _parse_desktop_file(path)
                    if e is None:
                        continue
                    if e.get("Type") != "Application" or e.get("Hidden") == "true":
                        self.apps[app_id] = None
                        continue
                    name = next((e[k] for k in name_keys if e.get(k)), app_id)
                    self.apps[app_id] = {
                        "id": app_id,
                        "name": name,
                        "icon": e.get("Icon", ""),
                        "wmClass": e.get("StartupWMClass", ""),
                        "visible": e.get("NoDisplay") != "true",
                    }
        self.apps = {k: v for k, v in self.apps.items() if v}

    def visible_apps(self):
        return sorted((a for a in self.apps.values() if a["visible"]), key=lambda a: a["name"].lower())

    def get(self, app_id):
        return self.apps.get(app_id or "")


def icon_for(name):
    if not name:
        return QIcon.fromTheme(FALLBACK_ICON)
    if os.path.isabs(name):
        return QIcon(name)
    icon = QIcon.fromTheme(name)
    return icon if not icon.isNull() else QIcon.fromTheme(FALLBACK_ICON)


def slot_icon(slot, catalog):
    app = catalog.get(slot.get("app"))
    return icon_for((app and app["icon"]) or slot.get("icon") or slot.get("app"))


def slot_title(slot, catalog):
    app = catalog.get(slot.get("app"))
    return (app and app["name"]) or slot.get("title") or slot.get("app") or "?"


def clamp_slot(slot):
    x = min(max(slot.get("x", 0), 0), 0.95)
    y = min(max(slot.get("y", 0), 0), 0.95)
    return x, y, max(0.05, min(slot.get("w", 1), 1 - x)), max(0.05, min(slot.get("h", 1), 1 - y))


def render_preview(slots, catalog, size, palette, icons=True):
    w, h = size.width(), size.height()
    pix = QPixmap(w, h)
    pix.fill(Qt.GlobalColor.transparent)
    p = QPainter(pix)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    text = palette.color(QPalette.ColorRole.Text)
    bg = QColor(text)
    bg.setAlphaF(0.08)
    frame = QColor(text)
    frame.setAlphaF(0.35)
    p.setPen(Qt.PenStyle.NoPen)
    p.setBrush(bg)
    p.drawRoundedRect(QRectF(0, 0, w, h), 4, 4)
    for slot in slots:
        sx, sy, sw, sh = clamp_slot(slot)
        r = QRectF(sx * w + 1.5, sy * h + 1.5, max(3, sw * w - 3), max(3, sh * h - 3))
        path = QPainterPath()
        path.addRoundedRect(r, 3, 3)
        p.fillPath(path, palette.color(QPalette.ColorRole.Base))
        p.setPen(frame)
        p.drawPath(path)
        side = int(min(32, r.width() - 6, r.height() - 6))
        if icons and side >= 8:
            icon = slot_icon(slot, catalog).pixmap(side, side)
            p.drawPixmap(int(r.center().x() - side / 2), int(r.center().y() - side / 2), icon)
    p.end()
    return pix


RUNTIME_PATH = os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"), "windowlayouts-runtimerc")


def load_open_apps(catalog):
    settings = QSettings(RUNTIME_PATH, QSettings.Format.IniFormat)
    try:
        raw = json.loads(settings.value("Runtime/openApps", "") or "[]")
    except ValueError:
        raw = []
    by_wmclass = {}
    for a in catalog.apps.values():
        if a["wmClass"]:
            by_wmclass.setdefault(a["wmClass"].lower(), a)
        by_wmclass.setdefault(a["id"].lower(), a)
    result, seen = [], set()
    for item in raw if isinstance(raw, list) else []:
        app = catalog.get(item.get("app")) or by_wmclass.get((item.get("wmClass") or "").lower())
        entry = dict(app) if app else {
            "id": item.get("app", ""),
            "name": item.get("title") or item.get("wmClass") or "?",
            "icon": item.get("icon", ""),
            "wmClass": item.get("wmClass", ""),
        }
        key = (entry["id"] or entry["wmClass"]).lower()
        if key and key not in seen:
            seen.add(key)
            result.append(entry)
    return sorted(result, key=lambda a: a["name"].lower())


PRESETS = [
    ("cols2", "Две колонки", lambda r: [(0, 0, r, 1), (r, 0, 1 - r, 1)], 0.5),
    ("rows2", "Две строки", lambda r: [(0, 0, 1, r), (0, r, 1, 1 - r)], 0.5),
    ("cols3", "Три колонки", lambda r: [(0, 0, 1 / 3, 1), (1 / 3, 0, 1 / 3, 1), (2 / 3, 0, 1 / 3, 1)], None),
    ("main-left", "Большое окно слева, два справа",
     lambda r: [(0, 0, r, 1), (r, 0, 1 - r, 0.5), (r, 0.5, 1 - r, 0.5)], 0.6),
    ("main-right", "Два слева, большое окно справа",
     lambda r: [(0, 0, 1 - r, 0.5), (0, 0.5, 1 - r, 0.5), (1 - r, 0, r, 1)], 0.6),
    ("grid4", "Четыре части", lambda r: [(0, 0, 0.5, 0.5), (0.5, 0, 0.5, 0.5),
                                         (0, 0.5, 0.5, 0.5), (0.5, 0.5, 0.5, 0.5)], None),
]
KEEP_PRESET = "keep"


class AppPicker(QFrame):
    picked = pyqtSignal(dict)

    def __init__(self, catalog, parent=None):
        super().__init__(parent, Qt.WindowType.Popup)
        self.setFrameShape(QFrame.Shape.StyledPanel)
        self.search = QLineEdit()
        self.search.setPlaceholderText("Поиск приложения…")
        self.search.setClearButtonEnabled(True)
        self.tabs = QTabWidget()
        self.open_list = self._make_list(load_open_apps(catalog))
        self.all_list = self._make_list(catalog.visible_apps())
        self.tabs.addTab(self.open_list, "Открытые")
        self.tabs.addTab(self.all_list, "Все приложения")
        if self.open_list.count() == 0:
            self.tabs.setCurrentIndex(1)
        layout = QVBoxLayout(self)
        layout.addWidget(self.search)
        layout.addWidget(self.tabs)
        self.search.textChanged.connect(self._filter)
        self.search.returnPressed.connect(self._pick_first)
        self.resize(340, 440)

    def _make_list(self, apps):
        lst = QListWidget()
        lst.setIconSize(QSize(24, 24))
        for app in apps:
            item = QListWidgetItem(icon_for(app["icon"]), app["name"])
            item.setData(Qt.ItemDataRole.UserRole, app)
            lst.addItem(item)
        lst.itemActivated.connect(self._pick)
        lst.itemClicked.connect(self._pick)
        return lst

    def _filter(self, text):
        text = text.strip().lower()
        found = {}
        for lst in (self.open_list, self.all_list):
            found[lst] = 0
            for i in range(lst.count()):
                item = lst.item(i)
                hidden = bool(text) and text not in item.text().lower()
                item.setHidden(hidden)
                found[lst] += 0 if hidden else 1
        if text and self.tabs.currentWidget() is self.open_list and found[self.open_list] == 0 \
                and found[self.all_list] > 0:
            self.tabs.setCurrentWidget(self.all_list)

    def _pick_first(self):
        lst = self.tabs.currentWidget()
        for i in range(lst.count()):
            if not lst.item(i).isHidden():
                self._pick(lst.item(i))
                return

    def _pick(self, item):
        self.picked.emit(item.data(Qt.ItemDataRole.UserRole))
        self.close()

    def popup_at(self, pos):
        screen = QApplication.screenAt(pos) or QApplication.primaryScreen()
        area = screen.availableGeometry()
        x = min(max(pos.x(), area.left()), area.right() - self.width())
        y = min(max(pos.y(), area.top()), area.bottom() - self.height())
        self.move(x, y)
        self.show()
        self.search.setFocus()


def scheme_pixmap(geometry, size, palette):
    return render_preview([{"x": x, "y": y, "w": w, "h": h} for x, y, w, h in geometry],
                          None, size, palette, icons=False)


class SchemeStrip(QWidget):
    changed = pyqtSignal(str)

    def __init__(self, schemes, parent=None):
        super().__init__(parent)
        self.group = QButtonGroup(self)
        self.group.setExclusive(True)
        layout = QHBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(6)
        for pid, title, geometry in schemes:
            btn = QToolButton()
            btn.setCheckable(True)
            btn.setIcon(QIcon(scheme_pixmap(geometry, QSize(80, 45), self.palette())))
            btn.setIconSize(QSize(80, 45))
            btn.setToolTip(title)
            btn.setProperty("pid", pid)
            btn.setAutoRaise(True)
            self.group.addButton(btn)
            layout.addWidget(btn)
        layout.addStretch(1)
        self.group.buttonClicked.connect(lambda b: self.changed.emit(b.property("pid")))

    def select(self, pid):
        for b in self.group.buttons():
            if b.property("pid") == pid:
                b.setChecked(True)

    def current(self):
        b = self.group.checkedButton()
        return b.property("pid") if b else None


SLOT_MIME = "application/x-windowlayouts-slot"


class SlotCanvas(QWidget):
    changed = pyqtSignal()

    def __init__(self, catalog, parent=None):
        super().__init__(parent)
        self.catalog = catalog
        self.geometry_list = []
        self.apps = []
        self.hover = -1
        self.press_pos = None
        self.press_index = -1
        self.drop_index = -1
        self.setMouseTracking(True)
        self.setAcceptDrops(True)
        self.setMinimumSize(480, 270)

    def set_geometry(self, geometry):
        self.geometry_list = geometry
        self.apps = (self.apps + [None] * len(geometry))[:len(geometry)]
        self.update()

    def area(self):
        w = self.width()
        h = min(self.height(), int(w * 9 / 16))
        w = int(h * 16 / 9)
        return QRectF((self.width() - w) / 2, (self.height() - h) / 2, w, h)

    def slot_rect(self, i):
        a = self.area()
        x, y, w, h = self.geometry_list[i]
        return QRectF(a.x() + x * a.width() + 3, a.y() + y * a.height() + 3,
                      w * a.width() - 6, h * a.height() - 6)

    def close_rect(self, i):
        r = self.slot_rect(i)
        return QRectF(r.right() - 26, r.top() + 6, 20, 20)

    def index_at(self, pos):
        for i in range(len(self.geometry_list)):
            if self.slot_rect(i).contains(pos):
                return i
        return -1

    def paintEvent(self, _event):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        pal = self.palette()
        text = pal.color(QPalette.ColorRole.Text)
        hl = pal.color(QPalette.ColorRole.Highlight)
        bg = QColor(text)
        bg.setAlphaF(0.06)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(bg)
        p.drawRoundedRect(self.area(), 8, 8)
        for i in range(len(self.geometry_list)):
            r = self.slot_rect(i)
            app = self.apps[i]
            active = i in (self.hover, self.drop_index)
            fill = QColor(pal.color(QPalette.ColorRole.Base))
            border = QColor(text)
            border.setAlphaF(0.25)
            if active:
                fill = QColor(hl)
                fill.setAlphaF(0.18)
                border = QColor(hl)
            path = QPainterPath()
            path.addRoundedRect(r, 6, 6)
            p.fillPath(path, fill)
            pen = QPen(border, 2 if active else 1)
            if not app:
                pen.setStyle(Qt.PenStyle.DashLine)
            p.setPen(pen)
            p.drawPath(path)
            side = int(min(48, r.width() / 2, r.height() / 2))
            label = app["name"] if app else "Выбрать приложение"
            icon = icon_for(app["icon"]) if app else QIcon.fromTheme("list-add")
            p.drawPixmap(int(r.center().x() - side / 2), int(r.center().y() - side / 2 - 10),
                         icon.pixmap(side, side))
            color = QColor(text)
            color.setAlphaF(1.0 if app else 0.6)
            p.setPen(color)
            text_rect = QRectF(r.x() + 6, r.center().y() + side / 2 - 4, r.width() - 12, 22)
            p.drawText(text_rect, Qt.AlignmentFlag.AlignHCenter | Qt.AlignmentFlag.AlignTop,
                       p.fontMetrics().elidedText(label, Qt.TextElideMode.ElideRight, int(text_rect.width())))
            if app and i == self.hover:
                c = self.close_rect(i)
                p.setPen(Qt.PenStyle.NoPen)
                p.setBrush(pal.color(QPalette.ColorRole.Window))
                p.drawEllipse(c)
                p.drawPixmap(c.adjusted(2, 2, -2, -2).toRect(),
                             QIcon.fromTheme("window-close").pixmap(16, 16))
        p.end()

    def mouseMoveEvent(self, event):
        pos = event.position()
        if self.press_pos is not None and self.press_index >= 0 and self.apps[self.press_index] \
                and (pos - self.press_pos).manhattanLength() > QApplication.startDragDistance():
            index = self.press_index
            self.press_pos = None
            drag = QDrag(self)
            mime = QMimeData()
            mime.setData(SLOT_MIME, str(index).encode())
            drag.setMimeData(mime)
            drag.setPixmap(icon_for(self.apps[index]["icon"]).pixmap(48, 48))
            drag.exec(Qt.DropAction.MoveAction)
            return
        hover = self.index_at(pos)
        if hover != self.hover:
            self.hover = hover
            self.setCursor(Qt.CursorShape.PointingHandCursor if hover >= 0 else Qt.CursorShape.ArrowCursor)
            self.update()

    def leaveEvent(self, _event):
        self.hover = -1
        self.update()

    def mousePressEvent(self, event):
        i = self.index_at(event.position())
        if i < 0:
            return
        if event.button() == Qt.MouseButton.RightButton:
            self.clear(i)
            return
        self.press_pos = event.position()
        self.press_index = i

    def mouseReleaseEvent(self, event):
        if self.press_pos is None or event.button() != Qt.MouseButton.LeftButton:
            self.press_pos = None
            return
        i = self.press_index
        self.press_pos = None
        if i < 0 or self.index_at(event.position()) != i:
            return
        if self.apps[i] and self.close_rect(i).contains(event.position()):
            self.clear(i)
            return
        self.open_picker(i)

    def open_picker(self, i):
        picker = AppPicker(self.catalog, self)
        picker.picked.connect(lambda app, i=i: self.set_app(i, app))
        r = self.slot_rect(i)
        picker.popup_at(self.mapToGlobal(QPoint(int(r.left() + 12), int(r.top() + 12))))

    def set_app(self, i, app):
        self.apps[i] = app
        self.update()
        self.changed.emit()

    def clear(self, i):
        if self.apps[i]:
            self.apps[i] = None
            self.update()
            self.changed.emit()

    def dragEnterEvent(self, event):
        if event.mimeData().hasFormat(SLOT_MIME):
            event.acceptProposedAction()

    def dragMoveEvent(self, event):
        if not event.mimeData().hasFormat(SLOT_MIME):
            return
        target = self.index_at(event.position())
        if target != self.drop_index:
            self.drop_index = target
            self.update()
        event.acceptProposedAction()

    def dragLeaveEvent(self, _event):
        self.drop_index = -1
        self.update()

    def dropEvent(self, event):
        source = int(bytes(event.mimeData().data(SLOT_MIME)).decode())
        target = self.index_at(event.position())
        self.drop_index = -1
        if target >= 0 and target != source:
            self.apps[source], self.apps[target] = self.apps[target], self.apps[source]
            self.changed.emit()
        self.update()
        event.acceptProposedAction()


class TemplateEditor(QDialog):
    def __init__(self, catalog, template=None, parent=None):
        super().__init__(parent)
        self.catalog = catalog
        self.template = json.loads(json.dumps(template)) if template else None
        self.setWindowTitle("Изменить шаблон" if template else "Новый шаблон")

        self.name_edit = QLineEdit(self.template["name"] if self.template else "")
        self.name_edit.setPlaceholderText("Например: Работа")

        schemes = []
        if self.template:
            schemes.append((KEEP_PRESET, "Как сохранено",
                            [(s["x"], s["y"], s["w"], s["h"]) for s in self.template["slots"]]))
        for pid, title, fn, default in PRESETS:
            schemes.append((pid, title, fn(default if default is not None else 0.5)))
        self.schemes = SchemeStrip(schemes)

        self.ratio = QSlider(Qt.Orientation.Horizontal)
        self.ratio.setRange(20, 80)
        self.ratio_label = QLabel()
        self.ratio_row_label = QLabel("Пропорция:")

        self.canvas = SlotCanvas(catalog)
        hint = QLabel("Нажмите на часть, чтобы выбрать приложение. Перетащите приложение на другую часть, "
                      "чтобы поменять их местами; правый клик или крестик — очистить.")
        hint.setWordWrap(True)
        hint.setEnabled(False)

        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)

        form = QFormLayout()
        form.addRow("Название:", self.name_edit)
        form.addRow("Схема:", self.schemes)
        ratio_row = QHBoxLayout()
        ratio_row.addWidget(self.ratio, 1)
        ratio_row.addWidget(self.ratio_label)
        form.addRow(self.ratio_row_label, ratio_row)

        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(self.canvas, 1)
        layout.addWidget(hint)
        layout.addWidget(buttons)

        self.schemes.changed.connect(self._preset_changed)
        self.ratio.valueChanged.connect(self._ratio_changed)
        if self.template:
            self.canvas.apps = [self._app_from_slot(s) for s in self.template["slots"]]
        self.schemes.select(KEEP_PRESET if self.template else PRESETS[0][0])
        self._preset_changed()
        self.resize(820, 680)

    def _app_from_slot(self, slot):
        app = self.catalog.get(slot.get("app"))
        if app:
            return dict(app)
        if not slot.get("app") and not slot.get("wmClass"):
            return None
        return {"id": slot.get("app", ""), "name": slot.get("title") or slot.get("app") or "?",
                "icon": slot.get("icon", ""), "wmClass": slot.get("wmClass", "")}

    def _preset(self):
        pid = self.schemes.current()
        return next((p for p in PRESETS if p[0] == pid), None)

    def _geometry(self):
        preset = self._preset()
        if preset is None:
            return [(s["x"], s["y"], s["w"], s["h"]) for s in self.template["slots"]]
        _pid, _title, fn, default = preset
        return fn(self.ratio.value() / 100 if default is not None else 0.5)

    def _preset_changed(self, _pid=None):
        preset = self._preset()
        has_ratio = preset is not None and preset[3] is not None
        self.ratio.setVisible(has_ratio)
        self.ratio_label.setVisible(has_ratio)
        self.ratio_row_label.setVisible(has_ratio)
        if has_ratio:
            self.ratio.blockSignals(True)
            self.ratio.setValue(int(preset[3] * 100))
            self.ratio.blockSignals(False)
        self._ratio_changed()

    def _ratio_changed(self, *_):
        self.ratio_label.setText("%d / %d" % (self.ratio.value(), 100 - self.ratio.value()))
        self.canvas.set_geometry(self._geometry())

    def _slots(self):
        slots = []
        for app, (x, y, w, h) in zip(self.canvas.apps, self._geometry()):
            app = app or {}
            slots.append({
                "app": app.get("id", ""),
                "wmClass": app.get("wmClass") or app.get("id", ""),
                "icon": app.get("icon", ""),
                "title": app.get("name", ""),
                "x": round(x, 4), "y": round(y, 4), "w": round(w, 4), "h": round(h, 4),
            })
        return slots

    def accept(self):
        missing = [i + 1 for i, a in enumerate(self.canvas.apps) if not a]
        if missing:
            QMessageBox.warning(self, "Шаблон", "Выберите приложение для части %s." %
                                ", ".join(str(m) for m in missing))
            return
        super().accept()

    def result_template(self):
        slots = self._slots()
        name = self.name_edit.text().strip()
        if not name:
            names = []
            for s in slots:
                if s["title"] not in names:
                    names.append(s["title"])
            name = " + ".join(names)
        t = self.template or {"id": "t%d" % int(time.time() * 1000), "created": int(time.time() * 1000),
                              "source": "settings"}
        t["name"] = name
        t["slots"] = slots
        return t


class KWinBridge:

    def __init__(self):
        self.bus = dbus.SessionBus()

    def _accel(self):
        obj = self.bus.get_object("org.kde.kglobalaccel", "/kglobalaccel")
        return dbus.Interface(obj, "org.kde.KGlobalAccel")

    def shortcut(self):
        try:
            keys = self._accel().shortcut(dbus.Array(SHORTCUT_ACTION, signature="s"))
        except dbus.DBusException:
            return None
        if not keys or not int(keys[0]):
            return QKeySequence()
        return QKeySequence(QKeyCombination.fromCombined(int(keys[0])))

    def set_shortcut(self, seq):
        keys = [seq[0].toCombined()] if seq.count() > 0 else []
        self._accel().setForeignShortcut(dbus.Array(SHORTCUT_ACTION, signature="s"),
                                         dbus.Array(keys, signature="i"))

    def _effects(self):
        obj = self.bus.get_object("org.kde.KWin", "/Effects")
        return dbus.Interface(obj, "org.kde.kwin.Effects")

    def script_enabled(self):
        try:
            out = subprocess.run(["kreadconfig6", "--file", "kwinrc", "--group", "Plugins",
                                  "--key", SCRIPT_ID + "Enabled", "--default", "false"],
                                 capture_output=True, text=True, check=False).stdout.strip()
        except OSError:
            return False
        return out == "true"

    def apply_template(self, template_id):
        settings = QSettings(RUNTIME_PATH, QSettings.Format.IniFormat)
        settings.setValue("Runtime/applyRequest",
                          json.dumps({"id": template_id, "at": int(time.time() * 1000)}))
        settings.sync()
        self._effects().reconfigureEffect(SCRIPT_ID)

    def set_script_enabled(self, enabled):
        subprocess.run(["kwriteconfig6", "--file", "kwinrc", "--group", "Plugins",
                        "--key", SCRIPT_ID + "Enabled", "true" if enabled else "false"], check=False)
        effects = self._effects()
        if enabled:
            effects.loadEffect(SCRIPT_ID)
        else:
            effects.unloadEffect(SCRIPT_ID)


class MainWindow(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Шаблоны окон")
        self.setWindowIcon(QIcon.fromTheme("view-split-left-right"))
        self.catalog = AppCatalog()
        self.kwin = KWinBridge()
        self.templates = []
        self._ignore_watch_until = 0.0

        self.list = QListWidget()
        self.list.setIconSize(QSize(128, 72))
        self.list.setSpacing(4)
        self.list.setDragDropMode(QAbstractItemView.DragDropMode.InternalMove)
        self.list.model().rowsMoved.connect(self._rows_moved)
        self.list.itemDoubleClicked.connect(lambda _item: self.edit_template())
        self.list.currentRowChanged.connect(self._update_buttons)

        self.btn_apply = QPushButton(QIcon.fromTheme("dialog-ok-apply"), "Применить")
        self.btn_apply.setToolTip("Применить шаблон к монитору, на котором сейчас курсор")
        self.btn_apply.clicked.connect(self.apply_template)
        self.btn_new = QPushButton(QIcon.fromTheme("list-add"), "Создать…")
        self.btn_edit = QPushButton(QIcon.fromTheme("document-edit"), "Изменить…")
        self.btn_rename = QPushButton(QIcon.fromTheme("edit-rename"), "Переименовать")
        self.btn_delete = QPushButton(QIcon.fromTheme("edit-delete"), "Удалить")
        self.btn_up = QPushButton(QIcon.fromTheme("go-up"), "")
        self.btn_down = QPushButton(QIcon.fromTheme("go-down"), "")
        self.btn_up.setToolTip("Выше")
        self.btn_down.setToolTip("Ниже")
        self.btn_new.clicked.connect(self.new_template)
        self.btn_edit.clicked.connect(self.edit_template)
        self.btn_rename.clicked.connect(self.rename_template)
        self.btn_delete.clicked.connect(self.delete_template)
        self.btn_up.clicked.connect(lambda: self.move_template(-1))
        self.btn_down.clicked.connect(lambda: self.move_template(1))

        buttons = QVBoxLayout()
        buttons.addWidget(self.btn_apply)
        buttons.addSpacing(8)
        for b in (self.btn_new, self.btn_edit, self.btn_rename, self.btn_delete):
            buttons.addWidget(b)
        updown = QHBoxLayout()
        updown.addWidget(self.btn_up)
        updown.addWidget(self.btn_down)
        buttons.addLayout(updown)
        buttons.addStretch(1)

        hint = QLabel("Чтобы сохранить текущее расположение, поставьте окна рядом, наведите курсор "
                      "на границу между ними и нажмите на появившуюся кнопку.")
        hint.setWordWrap(True)
        hint.setEnabled(False)

        templates_box = QGroupBox("Шаблоны")
        tl = QVBoxLayout(templates_box)
        row = QHBoxLayout()
        row.addWidget(self.list, 1)
        row.addLayout(buttons)
        tl.addLayout(row)
        tl.addWidget(hint)

        self.enabled_check = QCheckBox("Включить шаблоны окон (эффект KWin)")
        self.enabled_check.setChecked(self.kwin.script_enabled())
        self.enabled_check.toggled.connect(self._toggle_script)

        self.shortcut_edit = QKeySequenceEdit()
        current = self.kwin.shortcut()
        if current is not None:
            self.shortcut_edit.setKeySequence(current)
        self.shortcut_edit.editingFinished.connect(self._shortcut_changed)
        btn_default = QPushButton(QIcon.fromTheme("edit-undo"), "По умолчанию")
        btn_default.clicked.connect(self._shortcut_default)
        btn_clear = QPushButton(QIcon.fromTheme("edit-clear"), "")
        btn_clear.setToolTip("Без горячей клавиши")
        btn_clear.clicked.connect(self._shortcut_clear)

        behaviour = QGroupBox("Поведение")
        bl = QFormLayout(behaviour)
        bl.addRow(self.enabled_check)
        srow = QHBoxLayout()
        srow.addWidget(self.shortcut_edit, 1)
        srow.addWidget(btn_clear)
        srow.addWidget(btn_default)
        bl.addRow("Показать переключатель:", srow)
        if current is None:
            self.shortcut_edit.setEnabled(False)
            bl.addRow(QLabel("Эффект ещё не регистрировал хоткей — включите его."))

        layout = QVBoxLayout(self)
        layout.addWidget(templates_box, 1)
        layout.addWidget(behaviour)

        self.watcher = QFileSystemWatcher(self)
        self.watcher.fileChanged.connect(self._file_changed)
        self.watcher.directoryChanged.connect(self._file_changed)
        self.watcher.addPath(os.path.dirname(STORE_PATH))
        if os.path.exists(STORE_PATH):
            self.watcher.addPath(STORE_PATH)
        self._reload_timer = QTimer(self, singleShot=True, interval=300, timeout=self.reload)

        self.reload()
        self.resize(640, 560)


    def reload(self):
        row = self.list.currentRow()
        self.templates = TemplateStore.load()
        self.list.blockSignals(True)
        self.list.clear()
        for t in self.templates:
            item = QListWidgetItem(QIcon(render_preview(t.get("slots", []), self.catalog,
                                                        QSize(128, 72), self.palette())),
                                   self._describe(t))
            item.setData(Qt.ItemDataRole.UserRole, id(t))
            self.list.addItem(item)
        self.list.blockSignals(False)
        if self.templates:
            self.list.setCurrentRow(min(max(row, 0), len(self.templates) - 1))
        self._update_buttons()
        if os.path.exists(STORE_PATH) and STORE_PATH not in self.watcher.files():
            self.watcher.addPath(STORE_PATH)

    def _describe(self, t):
        apps = []
        for s in t.get("slots", []):
            title = slot_title(s, self.catalog)
            if title not in apps:
                apps.append(title)
        return "%s\n%s" % (t.get("name", "Без названия"), ", ".join(apps))

    def save(self):
        self._ignore_watch_until = time.time() + 1.0
        TemplateStore.save(self.templates)
        self.reload()

    def _file_changed(self, _path):
        if time.time() > self._ignore_watch_until:
            self._reload_timer.start()

    def _rows_moved(self, *_):
        by_key = {id(t): t for t in self.templates}
        reordered = [by_key[self.list.item(i).data(Qt.ItemDataRole.UserRole)] for i in range(self.list.count())]
        if len(reordered) == len(self.templates):
            self.templates = reordered
            self.save()

    def _update_buttons(self, *_):
        row = self.list.currentRow()
        has = 0 <= row < len(self.templates)
        for b in (self.btn_apply, self.btn_edit, self.btn_rename, self.btn_delete):
            b.setEnabled(has)
        self.btn_up.setEnabled(has and row > 0)
        self.btn_down.setEnabled(has and row < len(self.templates) - 1)


    def apply_template(self):
        row = self.list.currentRow()
        if not 0 <= row < len(self.templates):
            return
        if not self.kwin.script_enabled():
            QMessageBox.information(self, "Шаблоны окон", "Сначала включите эффект «Шаблоны окон».")
            return
        try:
            self.kwin.apply_template(self.templates[row]["id"])
        except dbus.DBusException as e:
            QMessageBox.warning(self, "Шаблоны окон", "Не удалось применить шаблон:\n%s" % e)

    def new_template(self):
        dlg = TemplateEditor(self.catalog, None, self)
        if dlg.exec() == QDialog.DialogCode.Accepted:
            self.templates.append(dlg.result_template())
            self.save()
            self.list.setCurrentRow(len(self.templates) - 1)

    def edit_template(self):
        row = self.list.currentRow()
        if not 0 <= row < len(self.templates):
            return
        dlg = TemplateEditor(self.catalog, self.templates[row], self)
        if dlg.exec() == QDialog.DialogCode.Accepted:
            self.templates[row] = dlg.result_template()
            self.save()

    def rename_template(self):
        row = self.list.currentRow()
        if not 0 <= row < len(self.templates):
            return
        name, ok = QInputDialog.getText(self, "Переименовать шаблон", "Название:",
                                        text=self.templates[row].get("name", ""))
        if ok and name.strip():
            self.templates[row]["name"] = name.strip()
            self.save()

    def delete_template(self):
        row = self.list.currentRow()
        if not 0 <= row < len(self.templates):
            return
        name = self.templates[row].get("name", "")
        if QMessageBox.question(self, "Удалить шаблон", "Удалить шаблон «%s»?" % name) == QMessageBox.StandardButton.Yes:
            del self.templates[row]
            self.save()

    def move_template(self, delta):
        row = self.list.currentRow()
        new = row + delta
        if 0 <= row < len(self.templates) and 0 <= new < len(self.templates):
            self.templates[row], self.templates[new] = self.templates[new], self.templates[row]
            self.save()
            self.list.setCurrentRow(new)


    def _toggle_script(self, enabled):
        try:
            self.kwin.set_script_enabled(enabled)
        except dbus.DBusException as e:
            QMessageBox.warning(self, "KWin", "Не удалось переключить эффект:\n%s" % e)

    def _apply_shortcut(self, seq):
        try:
            self.kwin.set_shortcut(seq)
        except dbus.DBusException as e:
            QMessageBox.warning(self, "Горячая клавиша", "Не удалось назначить:\n%s" % e)
        current = self.kwin.shortcut()
        self.shortcut_edit.setKeySequence(current if current is not None else QKeySequence())

    def _shortcut_changed(self):
        seq = self.shortcut_edit.keySequence()
        if seq.count() > 1:
            seq = QKeySequence(seq[0])
        self._apply_shortcut(seq)

    def _shortcut_default(self):
        self._apply_shortcut(QKeySequence(DEFAULT_SHORTCUT))

    def _shortcut_clear(self):
        self._apply_shortcut(QKeySequence())


def main():
    app = QApplication(sys.argv)
    translator = QTranslator(app)
    if translator.load(QLocale.system(), "qtbase", "_", QLibraryInfo.path(QLibraryInfo.LibraryPath.TranslationsPath)):
        app.installTranslator(translator)
    app.setApplicationName("windowlayouts-settings")
    app.setApplicationDisplayName("Шаблоны окон")
    app.setDesktopFileName("windowlayouts-settings")

    probe = QLocalSocket()
    probe.connectToServer(INSTANCE_NAME)
    if probe.waitForConnected(300):
        probe.write(b"raise")
        probe.waitForBytesWritten(300)
        return 0
    QLocalServer.removeServer(INSTANCE_NAME)
    server = QLocalServer()
    server.listen(INSTANCE_NAME)

    window = MainWindow()

    def raise_window():
        conn = server.nextPendingConnection()
        if conn:
            conn.close()
        window.show()
        window.raise_()
        window.activateWindow()

    server.newConnection.connect(raise_window)
    window.show()
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
