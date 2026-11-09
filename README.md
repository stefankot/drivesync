# drivesync

Mała aplikacja paska menu dla macOS (z oknami ustawień i postępu). Trzy rzeczy:

1. **Kopia jednokierunkowa Mac → Dysk Google** (Biurko, Dokumenty, Pobrane, Obrazy…), tylko zmiany, bez skanowania całego dysku.
2. **Montowanie Dysku** w `~/GoogleDrive` (NFS, bez macFUSE i bez rozszerzeń jądra), domyślnie tylko do odczytu.
3. **Odciążanie dysku**: wybrane katalogi lądują wyłącznie na Dysku, a w ich miejscu zostaje dowiązanie, więc ścieżki dalej działają.

Silnik transferu to `rclone`. Ta aplikacja dokłada demon w Swifcie (FSEvents, kolejka, śledzenie przenosin, pilnowanie montowania).

## Instalacja

```bash
./install.sh
```

Skrypt zainstaluje rclone (Homebrew, jeśli go nie ma), zbuduje aplikację `DriveSync.app`, skopiuje ją do `~/Applications` i uruchomi. Na pasku menu pojawi się ikona chmurki. **Dalej wszystko robisz w oknach aplikacji, bez terminala.**

## Obsługa w aplikacji

Ikona chmurki na pasku menu (zmienia się: ✓ zsynchronizowane, ⟳ trwa wysyłanie, ! błąd, przekreślona = brak konta):

- **Synchronizuj teraz**, **Otwórz Dysk Google** (Finder), **Zamontuj / Odmontuj Dysk**
- **Odciąż katalog…**: wybierasz katalog, aplikacja pokazuje plan i prosi o potwierdzenie, potem wysyła, weryfikuje sumy MD5, kasuje lokalnie i zostawia dowiązanie. Okno postępu ma przycisk Anuluj (działa do kroku kasowania).
- **Odciążone katalogi**: lista z przyciskiem **Przywróć** (pobiera katalog z powrotem, sprawdzając miejsce na dysku).
- **Ustawienia…**: połączenie z kontem Google (otwiera przeglądarkę), lista folderów do kopiowania (dodaj/usuń, nazwa na Dysku), montowanie (tylko do odczytu, limit cache), **Uruchamiaj przy logowaniu**.

### Własny klucz OAuth (zalecane, największa różnica w szybkości)

Domyślny klucz rclone jest współdzielony i Google go dławi. W oknie łączenia konta rozwiń „Własny klucz OAuth” i wklej `client_id` / `client_secret`. Jak je zdobyć:

1. console.cloud.google.com → nowy projekt → *APIs & Services* → włącz **Google Drive API**
2. *OAuth consent screen* → External → dodaj siebie jako Test user (potem najlepiej „In production”, żeby token nie wygasał co 7 dni)
3. *Credentials* → Create credentials → **OAuth client ID** → typ *Desktop app*

### Uprawnienia macOS

Jeśli aplikacja zgłasza brak dostępu do Biurka/Dokumentów: *Ustawienia systemowe → Prywatność i ochrona → Pełny dostęp do dysku* → dodaj `~/Applications/DriveSync.app`. Po każdej przebudowie aplikacji system może poprosić o to ponownie.

### Terminal (opcjonalnie)

`install.sh` dodaje też polecenie `~/.local/bin/drivesync`: `status`, `doctor`, `sync`, `mount` / `unmount`, `offload [--yes] <katalog>`, `fetch <katalog>`. Config: `~/Library/Application Support/DriveSync/config.json`, logi: `~/Library/Logs/DriveSync/`. Odinstalowanie: `./uninstall.sh`.

## Jak to działa i co jest gwarantowane

**Nic na Dysku nie jest kasowane.** Używane jest wyłącznie `rclone copy` (z `--max-delete 0`), nigdy `sync`. Pliki, których nie masz lokalnie (np. duże archiwa), są bezpieczne. Skasowanie pliku lokalnie nie kasuje go na Dysku.

**Aktualizacje.** Zmieniony plik zastępuje wersję na Dysku (Dysk trzyma historię wersji). Z `skipIfNewerOnDrive: true` (domyślnie) plik, który na Dysku jest nowszy niż lokalny, nie jest nadpisywany.

**Przenosiny.** Demon zapamiętuje numer i-węzła wysłanych plików/katalogów. Gdy plik lub katalog zmieni miejsce lokalnie, na Dysku jest przenoszony po stronie serwera (`rclone moveto --immutable`), więc struktura się zachowuje i nic nie jest wysyłane drugi raz. Jeśli przeniesienie się nie uda, plik jest po prostu skopiowany na nowe miejsce (stary egzemplarz zostaje).

**Po restarcie** zdarzenia są odtwarzane z historii FSEvents od ostatniego checkpointu, bez pełnego skanu. Co `fullScanHours` (12 h) robiony jest pełny przegląd jako siatka bezpieczeństwa.

**Odciążanie (`offload`)**: wyślij → rclone porównuje sumy MD5 każdego pliku na Dysku → sprawdza, czy nic się nie zmieniło lokalnie w trakcie → dopiero wtedy kasuje lokalnie i zostawia dowiązanie do `~/GoogleDrive/...`. Bez `--yes` tylko pokazuje plan. Odmawia, gdy w katalogu są dowiązania symboliczne lub gdy kopia na Dysku się różni.

## Gdzie lądują pliki na Dysku

Domyślnie w `Mój dysk/Mac/<Biurko|Dokumenty|…>`. Żeby dopiąć folder do **istniejącego** folderu na Dysku (np. `~/Documents/Archiwum` ↔ `Archiwum`), dodaj wpis z `remote` zaczynającym się od `/`:

```json
{"local": "~/Documents/Archiwum", "remote": "/Archiwum"}
```

Uwaga: nie dodawaj folderu razem z jego folderem nadrzędnym (np. `~/Documents` i `~/Documents/Archiwum`) bez wykluczenia, bo trafi na Dysk dwa razy.

## Ograniczenia (uczciwie)

- Dowiązania z `offload` działają tylko, gdy Dysk jest zamontowany, czyli potrzebny jest internet (cache VFS do 4 GB przyspiesza ponowne odczyty). `offload` działa na katalogach, nie na pojedynczych plikach.
- Przeniesienie samego dowiązania lokalnie nie przenosi katalogu na Dysku.
- Synchronizacja jest jednokierunkowa: zmiany zrobione na Dysku nie wracają na Maca.
- Dokumenty Google (Docs/Sheets) widać w montowaniu jako wyeksportowane `.docx`/`.xlsx`.
- Zainstaluj tylko jedno narzędzie synchronizujące te same foldery: zamknij oficjalną aplikację Google Drive, jeśli też synchronizuje Biurko/Dokumenty.
- Wzorce wykluczeń ze znakiem `/` w środku (np. `a/b*`) działają w pełnych przeglądach, ale nie w szybkiej ścieżce zmian (tam obsługiwane są wzorce nazw i `nazwa/**`).
