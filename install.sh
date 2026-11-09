#!/bin/bash
# Instalacja DriveSync: buduje aplikację paska menu, kopiuje do ~/Applications i uruchamia.
# Nic nie robi na Dysku Google ani w Twoich plikach. Konto połączysz w oknie aplikacji.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v rclone >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/rclone ]; then
  echo "▸ rclone: brak, instaluję przez Homebrew…"
  brew install rclone
fi

echo "▸ budowanie aplikacji"
APP_SRC="$(./make-app.sh build | tail -1)"

echo "▸ instalacja do ~/Applications"
mkdir -p "$HOME/Applications" "$HOME/.local/bin"
# zamknij działającą instancję, jeśli jest
[ -f "$HOME/Library/Application Support/DriveSync/drivesync.pid" ] && \
  kill -TERM "$(cat "$HOME/Library/Application Support/DriveSync/drivesync.pid")" 2>/dev/null && sleep 3 || true
rm -rf "$HOME/Applications/DriveSync.app"
cp -R "$APP_SRC" "$HOME/Applications/DriveSync.app"
ln -sf "$HOME/Applications/DriveSync.app/Contents/MacOS/drivesync" "$HOME/.local/bin/drivesync"

open "$HOME/Applications/DriveSync.app"
cat <<MSG

✓ Gotowe. Ikona chmurki pojawiła się na pasku menu (u góry ekranu).
  Kliknij ją → „Połącz z Google Drive…”, wybierz foldery i zaznacz „Uruchamiaj przy logowaniu”.

Jeśli macOS zgłasza brak dostępu do Biurka/Dokumentów: Ustawienia systemowe →
Prywatność i ochrona → Pełny dostęp do dysku → dodaj ~/Applications/DriveSync.app
(po każdej przebudowie aplikacji system może poprosić o to ponownie).
MSG
