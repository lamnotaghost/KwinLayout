#!/usr/bin/env python3

import json
import os
import subprocess
import sys
import time

import dbus
from PyQt6.QtCore import QFileSystemWatcher, QKeyCombination, QRectF, QSettings, QSize, Qt, QTimer
from PyQt6.QtGui import QColor, QIcon, QKeySequence, QPainter, QPainterPath, QPalette, QPixmap
from PyQt6.QtNetwork import QLocalServer, QLocalSocket
from PyQt6.QtWidgets import (
    QAbstractItemView, QApplication, QCheckBox, QComboBox, QCompleter, QDialog,
    QDialogButtonBox, QFormLayout, QGroupBox, QHBoxLayout, QInputDialog, QKeySequenceEdit,
    QLabel, QLineEdit, QListWidget, QListWidgetItem, QMessageBox, QPushButton, QSlider,
    QVBoxLayout, QWidget,
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


def render_preview(slots, catalog, size, palette):
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
        if side >= 8:
            icon = slot_icon(slot, catalog).pixmap(side, side)
            p.drawPixmap(int(r.center().x() - side / 2), int(r.center().y() - side / 2), icon)
    p.end()
    return pix


class PreviewWidget(QWidget):
    def __init__(self, catalog, parent=None):
        super().__init__(parent)
        self.catalog = catalog
        self.slots = []
        self.setMinimumSize(320, 180)

    def set_slots(self, slots):
        self.slots = slots
        self.update()

    def paintEvent(self, _event):
        w = self.width()
        h = min(self.height(), int(w * 9 / 16))
        w = int(h * 16 / 9)
        pix = render_preview(self.slots, self.catalog, QSize(w, h), self.palette())
        p = QPainter(self)
        p.drawPixmap((self.width() - w) // 2, (self.height() - h) // 2, pix)


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


class AppCombo(QComboBox):

    def __init__(self, catalog, parent=None):
        super().__init__(parent)
        self.setEditable(True)
        self.setInsertPolicy(QComboBox.InsertPolicy.NoInsert)
        self.setMinimumWidth(280)
        self.addItem(QIcon.fromTheme("list-add"), "— выберите приложение —", "")
        for app in catalog.visible_apps():
            self.addItem(icon_for(app["icon"]), app["name"], app["id"])
        completer = QCompleter(self.model(), self)
        completer.setFilterMode(Qt.MatchFlag.MatchContains)
        completer.setCaseSensitivity(Qt.CaseSensitivity.CaseInsensitive)
        completer.setCompletionMode(QCompleter.CompletionMode.PopupCompletion)
        self.setCompleter(completer)
        self.lineEdit().setPlaceholderText("Начните вводить название…")

    def set_app(self, app_id, fallback_title=""):
        i = self.findData(app_id)
        if i < 0 and app_id:
            self.addItem(QIcon.fromTheme(FALLBACK_ICON), fallback_title or app_id, app_id)
            i = self.count() - 1
        self.setCurrentIndex(max(0, i))

    def app_id(self):
        i = self.findText(self.currentText(), Qt.MatchFlag.MatchFixedString)
        return self.itemData(i) if i >= 0 else ""


class TemplateEditor(QDialog):
    def __init__(self, catalog, template=None, parent=None):
        super().__init__(parent)
        self.catalog = catalog
        self.template = json.loads(json.dumps(template)) if template else None
        self.setWindowTitle("Изменить шаблон" if template else "Новый шаблон")
        self.combos = []

        self.name_edit = QLineEdit(self.template["name"] if self.template else "")
        self.name_edit.setPlaceholderText("Например: Работа")

        self.preset_combo = QComboBox()
        if self.template:
            self.preset_combo.addItem("Как сохранено (%d окна)" % len(self.template["slots"]), KEEP_PRESET)
        for pid, title, _fn, _r in PRESETS:
            self.preset_combo.addItem(title, pid)

        self.ratio = QSlider(Qt.Orientation.Horizontal)
        self.ratio.setRange(20, 80)
        self.ratio_label = QLabel()

        self.preview = PreviewWidget(catalog)
        self.slots_box = QGroupBox("Приложения")
        self.slots_form = QFormLayout(self.slots_box)

        buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Save | QDialogButtonBox.StandardButton.Cancel)
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)

        form = QFormLayout()
        form.addRow("Название:", self.name_edit)
        form.addRow("Схема:", self.preset_combo)
        ratio_row = QHBoxLayout()
        ratio_row.addWidget(self.ratio, 1)
        ratio_row.addWidget(self.ratio_label)
        self.ratio_row_label = QLabel("Пропорция:")
        form.addRow(self.ratio_row_label, ratio_row)

        layout = QVBoxLayout(self)
        layout.addLayout(form)
        layout.addWidget(self.preview, 1)
        layout.addWidget(self.slots_box)
        layout.addWidget(buttons)

        self.preset_combo.currentIndexChanged.connect(self._preset_changed)
        self.ratio.valueChanged.connect(self._update_preview)
        self._preset_changed()
        if self.template:
            for combo, slot in zip(self.combos, self.template["slots"]):
                combo.set_app(slot.get("app", ""), slot.get("title", ""))
        self._update_preview()
        self.resize(560, 640)

    def _preset(self):
        pid = self.preset_combo.currentData()
        return next((p for p in PRESETS if p[0] == pid), None)

    def _geometry(self):
        preset = self._preset()
        if preset is None:
            return [(s["x"], s["y"], s["w"], s["h"]) for s in self.template["slots"]]
        _pid, _title, fn, default = preset
        return fn(self.ratio.value() / 100 if default is not None else 0.5)

    def _preset_changed(self):
        preset = self._preset()
        has_ratio = preset is not None and preset[3] is not None
        self.ratio.setVisible(has_ratio)
        self.ratio_label.setVisible(has_ratio)
        self.ratio_row_label.setVisible(has_ratio)
        if has_ratio:
            self.ratio.blockSignals(True)
            self.ratio.setValue(int(preset[3] * 100))
            self.ratio.blockSignals(False)

        chosen = [c.app_id() for c in self.combos]
        while self.slots_form.rowCount():
            self.slots_form.removeRow(0)
        self.combos = []
        for i in range(len(self._geometry())):
            combo = AppCombo(self.catalog)
            if i < len(chosen) and chosen[i]:
                combo.set_app(chosen[i])
            combo.currentIndexChanged.connect(self._update_preview)
            combo.lineEdit().editingFinished.connect(self._update_preview)
            self.slots_form.addRow("Окно %d:" % (i + 1), combo)
            self.combos.append(combo)
        self._update_preview()

    def _slots(self):
        slots = []
        for i, (combo, (x, y, w, h)) in enumerate(zip(self.combos, self._geometry())):
            app_id = combo.app_id()
            app = self.catalog.get(app_id)
            old = self.template["slots"][i] if self.template and i < len(self.template["slots"]) else {}
            same_app = old.get("app") == app_id
            slots.append({
                "app": app_id,
                "wmClass": (app and app["wmClass"]) or (old.get("wmClass", "") if same_app else "") or app_id,
                "icon": (app and app["icon"]) or (old.get("icon", "") if same_app else ""),
                "title": (app and app["name"]) or (old.get("title", "") if same_app else app_id),
                "x": round(x, 4), "y": round(y, 4), "w": round(w, 4), "h": round(h, 4),
            })
        return slots

    def _update_preview(self, *_):
        self.ratio_label.setText("%d / %d" % (self.ratio.value(), 100 - self.ratio.value()))
        self.preview.set_slots(self._slots())

    def accept(self):
        slots = self._slots()
        missing = [i + 1 for i, s in enumerate(slots) if not s["app"]]
        if missing:
            QMessageBox.warning(self, "Шаблон", "Выберите приложение для окна %s." %
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
        for b in (self.btn_edit, self.btn_rename, self.btn_delete):
            b.setEnabled(has)
        self.btn_up.setEnabled(has and row > 0)
        self.btn_down.setEnabled(has and row < len(self.templates) - 1)


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
