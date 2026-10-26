#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ID=windowlayouts
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
SETTINGS="$DATA/windowlayouts/windowlayouts_settings.py"

if kpackagetool6 --type=KWin/Script --show "$ID" >/dev/null 2>&1; then
    echo "→ Удаляю старую версию (KWin-скрипт)"
    qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.unloadScript "$ID" >/dev/null || true
    kpackagetool6 --type=KWin/Script --remove "$ID" >/dev/null
fi

echo "→ Эффект KWin"
if kpackagetool6 --type=KWin/Effect --show "$ID" >/dev/null 2>&1; then
    kpackagetool6 --type=KWin/Effect --upgrade "$DIR/kwin-effect"
else
    kpackagetool6 --type=KWin/Effect --install "$DIR/kwin-effect"
fi

echo "→ Окно настроек"
install -Dm755 "$DIR/settings/windowlayouts_settings.py" "$SETTINGS"
install -dm755 "$DATA/applications"
sed "s|@SETTINGS@|$SETTINGS|" "$DIR/windowlayouts-settings.desktop" \
    > "$DATA/applications/windowlayouts-settings.desktop"

echo "→ Запуск приложений из шаблонов (systemd --user)"
install -Dm644 "$DIR/systemd/windowlayouts-launch@.service" \
    "$CONFIG/systemd/user/windowlayouts-launch@.service"
systemctl --user daemon-reload

echo "→ Включаю эффект"
kwriteconfig6 --file kwinrc --group Plugins --key "${ID}Enabled" true
qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.unloadEffect "$ID" >/dev/null 2>&1 || true
qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.loadEffect "$ID" >/dev/null

echo
echo "Готово. Переключатель шаблонов: Meta+Ctrl+L (можно изменить в «Шаблоны окон»)."
