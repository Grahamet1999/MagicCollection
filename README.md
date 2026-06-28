# MTG Collection

A Windows desktop app for cataloguing a local Magic: The Gathering collection.
Look up cards from [Scryfall](https://scryfall.com), organise them into folders,
track quantities/foils/prices, and import or export in CSV (including a
Moxfield-compatible format).

© 2026 @oosshh — released under the [MIT License](LICENSE).

---

## Download & install (prebuilt app)

1. Go to the **[Releases page](https://github.com/Grahamet1999/MagicCollection/releases)**.
2. Under the latest release's **Assets**, download **`MTGApp.tar.xz`**.
3. **Extract it:**
   - **Windows 11:** right-click the file → **Extract All…** (or just double-click it), and choose a destination.
   - **Any Windows 10/11:** open a terminal where the file is and run:
     ```
     tar -xf MTGApp.tar.xz
     ```
4. Open the extracted **`MTGApp`** folder and run **`mtg_collection.exe`**.

> Keep all files together — run the `.exe` from inside the `MTGApp` folder; it
> needs the DLLs and `data\` folder next to it.

### Requirements
- **Windows 10 or 11 (64-bit).**
- **Microsoft Visual C++ Redistributable (x64).** Usually already installed; if
  the app won't start with a missing `VCRUNTIME140.dll` error, install it once
  from <https://aka.ms/vs/17/release/vc_redist.x64.exe>.
- **No database setup needed.** The app uses a local Microsoft SQL Server
  instance if one is available, and otherwise automatically falls back to a
  self-contained local file (`mtg_collection.db`). The title-bar chip shows
  which storage is active.

---

## Build from source

Requires the [Flutter SDK](https://docs.flutter.dev/get-started/install/windows)
(with Windows desktop support enabled).

```bash
git clone https://github.com/Grahamet1999/MagicCollection.git
cd MagicCollection
flutter pub get
flutter run -d windows        # run in debug
flutter build windows --release   # produce build\windows\x64\runner\Release
```

The runnable app is the entire `build\windows\x64\runner\Release\` folder.

---

## Features
- **Import** from Scryfall by set code + collector number, or by name search.
- **Rapid entry:** type set → Tab → number → Tab → quantity → Enter.
- **Bulk import** from CSV (flexible columns; folders supported).
- **Collection view** with search, folders, and sorting by name, set/number,
  **color**, price, quantity, or date added.
- **Folders:** a card can be split across folders (e.g. 1 here, 2 there); the
  "All cards" view shows the combined total.
- **Multi-select** for moving or deleting many cards at once.
- **Export** to a standard CSV (re-importable, folders included) or a
  **Moxfield**-compatible CSV.

---

## Storage details
- Preferred: local **SQL Server** over ODBC (Driver 18), database `MtgCollection`
  with Windows authentication. Connection settings live in
  [`lib/services/db_config.dart`](lib/services/db_config.dart).
- Fallback: embedded **SQLite** file in the app's support directory.
- The two stores are independent. To move data between machines, use
  **Export to CSV** and then **Import from CSV**.
