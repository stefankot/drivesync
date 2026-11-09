#!/bin/bash
# Zamyka aplikację i usuwa autostart. Nie rusza plików na Dysku, ustawień ani lokalnych danych.
# Jeśli odciążyłeś katalogi (dowiązania do ~/GoogleDrive), najpierw przywróć je w aplikacji (Odciążone → Przywróć).
[ -f "$HOME/Library/Application Support/DriveSync/drivesync.pid" ] && \
  kill -TERM "$(cat "$HOME/Library/Application Support/DriveSync/drivesync.pid")" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/pl.drivesync.app.plist" "$HOME/.local/bin/drivesync"
rm -rf "$HOME/Applications/DriveSync.app"
echo "Usunięto aplikację i autostart. Ustawienia zostają w ~/Library/Application Support/DriveSync."
