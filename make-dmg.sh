#!/bin/bash
# Gera o instalador "Build Remoto.dmg" (app + atalho para Aplicativos + LEIA-ME) na Mesa.
set -euo pipefail
cd "$(dirname "$0")"

./make-app.sh >/dev/null
APP="$HOME/Applications/Build Remoto.app"
SAIDA="$HOME/Desktop/Build Remoto.dmg"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/Build Remoto"
ditto "$APP" "$TMP/Build Remoto/Build Remoto.app"
xattr -cr "$TMP/Build Remoto/Build Remoto.app"
codesign --force --deep --sign - "$TMP/Build Remoto/Build Remoto.app" >/dev/null 2>&1
ln -s /Applications "$TMP/Build Remoto/Applications"
cp LEIA-ME.txt "$TMP/Build Remoto/LEIA-ME — como abrir.txt"

rm -f "$SAIDA"
hdiutil create -volname "Build Remoto" -srcfolder "$TMP/Build Remoto" -ov -format UDZO -fs HFS+ "$SAIDA" >/dev/null
echo "✓ $SAIDA ($(du -h "$SAIDA" | cut -f1))"
