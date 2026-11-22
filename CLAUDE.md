# CLAUDE.md – Arbeitsregeln für MacExplorer

Die Funktionsbeschreibung steht in [SPEC.md](SPEC.md).

## Zusammenarbeit
- Der Nutzer programmiert nicht. Claude schreibt den gesamten Code, der Nutzer gibt Rückmeldung zu Aussehen und Verhalten.
- Mit dem Nutzer **auf Deutsch** sprechen: kurz, einfache Sprache, kein Fachjargon.
- Technische Entscheidungen selbst treffen und kurz auflisten. Nur zu Aussehen und Verhalten nachfragen.
- Meilenstein für Meilenstein bauen. Nach jedem Meilenstein:
  1. App bauen und starten,
  2. kurze deutsche Testliste geben (was klicken, was soll passieren),
  3. auf Rückmeldung warten.
- Nach jedem funktionierenden Meilenstein einen Git-Commit machen, damit man zurückspringen kann.

## Sicherheitsregeln (immer)
- Löschen = immer „in den Papierkorb“ (`FileManager.trashItem`), nie `removeItem` auf Nutzerdaten.
- Nie still überschreiben: bei Namenskonflikt „Ersetzen / Überspringen / Beide behalten“ fragen.
- Jede Dateioperation muss per Cmd+Z rückgängig gemacht werden können (UndoManager).
- Eigene Tests nur in `~/ExplorerTest` mit selbst erzeugten Dummy-Dateien. **Niemals** Dateioperationen auf den echten Ordnern des Nutzers ausführen.

## Technik
- Swift, AppKit (NSOutlineView/NSTableView) für Baum und Liste, SwiftUI für Einstellungen/kleine Teile.
- Kein App-Sandbox. Festplattenvollzugriff bei Bedarf erfragen.
- Design: Windows-Explorer-Aufbau, aber macOS-Look mit SF Symbols; keine Microsoft-Logos, -Icons oder -Namen.
- `xcode-select` zeigt auf die Command Line Tools. Darum beim Bauen immer
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` voranstellen (Systemeinstellung nicht ändern).
- Bauen (Projekt nutzt einen automatisch synchronisierten Quellordner `MacExplorer/` – neue .swift-Dateien einfach dort ablegen):
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MacExplorer.xcodeproj -target MacExplorer -configuration Debug SYMROOT="$PWD/build" OBJROOT="$PWD/build/obj" build`
- Starten: `open build/Debug/MacExplorer.app`
- Selbsttest (nur Debug-Build): `open -n build/Debug/MacExplorer.app --args -startPath ~/ExplorerTest -snapshotPath <scratchpad>/bild.png [-debugReveal YES]`
  speichert nach dem Start ein Bild des Fensters (Bildschirmaufnahme von außen ist nicht erlaubt).
