# CLAUDE.md – Arbeitsregeln für MFExplorer

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
- Bauen (Projekt nutzt einen automatisch synchronisierten Quellordner `MFExplorer/` – neue .swift-Dateien einfach dort ablegen):
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MFExplorer.xcodeproj -target MFExplorer -configuration Debug SYMROOT="$PWD/build" OBJROOT="$PWD/build/obj" -clonedSourcePackagesDirPath "$PWD/build/SourcePackages" build`
- Starten: `open build/Debug/MFExplorer.app`
- Selbsttest (nur Debug-Build): `open -n build/Debug/MFExplorer.app --args -startPath ~/ExplorerTest -snapshotPath <scratchpad>/bild.png [-debugReveal YES]`
  speichert nach dem Start ein Bild des Fensters (Bildschirmaufnahme von außen ist nicht erlaubt).
  Weitere Test-Argumente: `-debugSelect <Name>`, `-debugSearch <Text>`, `-debugSettings YES`, `-debugSnapDelay <Sek.>`, `-defaultViewMode large`, `-showPreviewPane YES`.
  Inhalte, die macOS in einem eigenen Prozess zeichnet (Bild-/HTML-Vorschau), erscheinen auf diesen Bildern leer.
- Selbsttest der Dateioperationen (nur Debug-Build, arbeitet nur in `~/ExplorerTest/_selftest`):
  `open -n build/Debug/MFExplorer.app --args -selfTest <scratchpad>/selftest.log`
- Such-Test (wartet bis die Suche fertig ist, schreibt Treffer + Fundstelle): `open -n build/Debug/MFExplorer.app --args -startPath ~/ExplorerTest/Inhaltstest -searchContent YES -searchTestWord Umsatz -searchTest <scratchpad>/search.log`
- Leertasten-Test (Ordner-Info-Fenster ↔ Schnellansicht): `open -n build/Debug/MFExplorer.app --args -startPath ~/ExplorerTest -spaceTest <scratchpad>/spacetest.log`
- Tab-Test (öffnet 3 Tabs, schließt einen, prüft dass die App weiterläuft): `open -n build/Debug/MFExplorer.app --args -tabTest <scratchpad>/tabtest.log`
- Absturzprotokolle: `~/Library/Logs/DiagnosticReports/MFExplorer-*.ips`. QLPreviewView nie selbst `close()` aufrufen (schließt sich mit dem Fenster). – schreibt PASS/FAIL ins Protokoll und beendet sich. Nach Änderungen an `FileOperations.swift` immer laufen lassen.

## Aufbau des Codes
- `FileOperations.swift`: alle Änderungen am Dateisystem (Kopieren/Verschieben mit Konfliktdialog und Fortschritt, Papierkorb, Umbenennen, ZIP, Tags), Undo, Zwischenablage, Drag-&-Drop-Regeln.
- `MainWindowController.swift`: Fenster, Navigation, alle Befehle und Kontextmenüs.
- `FileListViewController.swift`: Detailansicht (Auswahlrechteck, Umbenennen, Drag & Drop).
- `SidebarViewController.swift`: Baum (unabhängig von der Hauptansicht).
- `Bars.swift`: Adress- (mit Suchfeld), Befehls- und Statusleiste. `PropertiesWindow.swift`: Eigenschaften-Fenster.
- `IconView.swift`: Symbolansicht mit Vorschaubildern. `Preview.swift`: Vorschaubereich und Schnellansicht. `SettingsWindow.swift`: Einstellungen.
- Tabs sind native macOS-Fenster-Tabs (jeder Tab = ein `MainWindowController`).
- `ContentSearch.swift`: Inhaltssuche über den Spotlight-Index (NSMetadataQuery) und die Zeile für die Spalte „Fundstelle“.
- Gleichnamige Ordner werden beim Kopieren/Verschieben zusammengeführt (`FileOps.plan`), danach Hinweis.

## Updates und Veröffentlichung (Sparkle)
- Sparkle 2 kommt als Swift-Paket (`build/SourcePackages`). Feed: `appcast.xml` im Repo (über raw.githubusercontent.com). Öffentlicher Schlüssel in `Config/Info.plist`, der private liegt im Schlüsselbund unter dem Konto `mfexplorer`.
- In Debug-Builds startet der Updater nicht (keine Update-Dialoge bei Tests).
- Neue Version veröffentlichen, nur mit ausdrücklichem OK des Nutzers: `Tools/release.sh <Version> <notizen.md>`. Das Skript erhöht die Build-Nummer, baut, unterschreibt, erstellt das GitHub-Release und ergänzt danach `appcast.xml`.
- Git-Absender in diesem Repo: `PhilippKom <72168776+PhilippKom@users.noreply.github.com>`. Niemals die private E-Mail-Adresse verwenden.

- Gesammelte, noch nicht veröffentlichte Änderungen stehen in `CHANGELOG.md` unter „Unveröffentlicht“. Beim Release daraus die Notizen machen (nur Neuerungen, keine Installationsanleitung – sie erscheinen im Update-Fenster der App) und den Abschnitt in die neue Version umbenennen.
