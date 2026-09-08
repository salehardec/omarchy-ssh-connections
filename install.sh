#!/bin/bash
# Установка плагина в пользовательский каталог omarchy.
# Имя папки берётся из "id" в manifest.json (папка должна совпадать с id).
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ID="$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$SRC/manifest.json" | head -1)"
[ -n "$PLUGIN_ID" ] || { echo "Не удалось прочитать id из manifest.json" >&2; exit 1; }

DST="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
mkdir -p "$DST"

# Личные файлы (folderNames.json/overrides.json) при обновлении не затираем.
for f in manifest.json Panel.qml Connections.js LICENSE README.md; do
  [ -f "$SRC/$f" ] && install -m 644 "$SRC/$f" "$DST/$f"
done
[ -f "$SRC/folderNames.json" ] && [ ! -f "$DST/folderNames.json" ] \
  && install -m 644 "$SRC/folderNames.json" "$DST/folderNames.json"

echo "Установлено в $DST (id: $PLUGIN_ID)"
echo "Добавьте виджет в shell.json: { \"id\": \"$PLUGIN_ID\" } в bar.layout.center"
echo "Затем: omarchy restart shell"
