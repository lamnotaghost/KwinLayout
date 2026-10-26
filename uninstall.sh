#!/usr/bin/env bash
set -uo pipefail

ID=windowlayouts
DATA="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"

qdbus6 org.kde.KWin /Effects org.kde.kwin.Effects.unloadEffect "$ID" >/dev/null
kwriteconfig6 --file kwinrc --group Plugins --key "${ID}Enabled" --delete
kpackagetool6 --type=KWin/Effect --remove "$ID"
rm -f "$DATA/applications/windowlayouts-settings.desktop" \
      "$CONFIG/systemd/user/windowlayouts-launch@.service"
rm -rf "$DATA/windowlayouts"
systemctl --user daemon-reload

echo "Удалено. Шаблоны сохранены в $CONFIG/windowlayoutsrc — удалите файл вручную, если не нужны."
