# MFExplorer – Spezifikation

Ein nativer macOS-Dateimanager im Stil des Windows-Explorers. Ziel: Umsteigern von Windows den Mac leichter machen.

**Wichtigstes Ziel:** Dateien und Ordner per Drag & Drop zwischen zwei Orten verschieben muss mühelos sein. Darum navigieren Seitenleiste und Hauptansicht unabhängig voneinander.

Aussehen: Aufbau und Verhalten wie der Windows-Explorer, aber im macOS-Look mit SF Symbols. Keine Microsoft-Logos, -Icons oder -Produktnamen.

---

## Sicherheitsregeln (gelten immer)

- Löschen heißt immer „in den Papierkorb legen“, nie endgültig löschen.
- Nie still überschreiben: Bei Namenskonflikten fragen – „Ersetzen / Überspringen / Beide behalten“.
- Jede Dateioperation lässt sich mit Cmd+Z rückgängig machen.

---

## 1. Fensteraufbau
- Seitenleiste links (Breite verstellbar, ausblendbar)
- Adressleiste und Befehlsleiste oben
- Hauptansicht in der Mitte
- Optionaler Vorschaubereich rechts
- Statusleiste unten: Anzahl Elemente, Anzahl und Größe der ausgewählten Elemente

## 2. Seitenleiste
- Bereiche: Favoriten (Ordner per Hineinziehen anheften), Benutzerordner, Schreibtisch, Dokumente, Downloads, iCloud Drive, alle Laufwerke inkl. externer.
- Aufklappbarer Baum mit Pfeilen; zeigt Ordner UND Dateien (Einstellung: Dateien im Baum ausblenden).
- Unabhängig von der Hauptansicht: Auf-/Zuklappen oder Scrollen in der Seitenleiste ändert nie die Hauptansicht; Navigieren in der Hauptansicht klappt den Baum nie zu und verschiebt ihn nicht.
- Einfachklick wählt aus; Doppelklick oder Enter öffnet den Ordner in der Hauptansicht.
- Schaltfläche „Im Baum zeigen“ deckt den aktuellen Ordner in der Seitenleiste auf.
- Einträge im Baum sind ziehbar und Ablageziele. Beim Ziehen über einen Ordner klappt er nach kurzer Verzögerung auf.

## 3. Hauptansicht (Detailansicht)
- Spalten: Name, Änderungsdatum, Typ, Größe.
- Spalten in der Breite verstellbar und per Ziehen umsortierbar; Klick auf Spaltenkopf sortiert; Rechtsklick auf Spaltenkopf blendet weitere Spalten ein/aus (z. B. Erstellungsdatum).
- Doppelklick öffnet einen Ordner bzw. eine Datei mit dem Standardprogramm.

## 4. Adressleiste
- Zurück, Vor, Nach oben, Aktualisieren.
- Pfad als Brotkrumen mit klickbaren Teilen; Klick auf freie Fläche → Pfad tippen oder einfügen, Enter springt hin.

## 5. Befehlsleiste
- Grundfunktionen: Neuer Ordner, Ausschneiden, Kopieren, Einfügen, Umbenennen, Löschen.
- Zusätzlich: Alles auswählen, Sortieren, Ansicht, Pfad kopieren, Als ZIP komprimieren, Entpacken, Versteckte Dateien zeigen, Im Terminal öffnen, Eigenschaften/Informationen, Teilen, Tags, Rückgängig.
- Dieselben Aktionen im Rechtsklick-Menü.

## 6. Auswahl
- Klick, Cmd+Klick (umschalten), Shift+Klick (Bereich), Cmd+A.
- Auswahlrechteck: auf freie Fläche klicken und ein Rechteck aufziehen.

## 7. Drag & Drop
- Zwischen Hauptansicht und Seitenleiste, innerhalb beider und von/zu anderen Apps (Finder, Schreibtisch, Mail).
- Gleiches Laufwerk = verschieben, anderes Laufwerk = kopieren; Option erzwingt Kopieren, Cmd erzwingt Verschieben.
- Deutliche Hervorhebung des Ablageziels.
- Fortschrittsfenster bei großen Vorgängen.

## 8. Vorschau
- Vorschaubereich, über die Befehlsleiste ein-/ausschaltbar.
- Leertaste öffnet Quick Look für Dateien und Ordner (bei Ordnern: Anzahl Elemente, Gesamtgröße, Daten).

## 9. Tastenkürzel
- Mac-Standard (Cmd+C/X/V/Z) plus Windows-Gewohnheiten:
  - F2 = Umbenennen
  - Enter = Öffnen
  - Rückschritt-Taste (⌫) = in den Papierkorb (Rückfrage abschaltbar)
  - Alt+Pfeil hoch oder Cmd+Pfeil hoch = eine Ebene nach oben

## 10. Später (M4)
- Tabs, Suche, Symbolansicht, Einstellungen (inkl. optionaler Windows-Strg-Kürzel).

---

## Technik
- Swift, native macOS-App, gebaut mit `xcodebuild`.
- AppKit für Baum und Dateiliste (NSOutlineView / NSTableView); SwiftUI für Einstellungen und kleinere Teile.
- Kein App-Store-Sandbox; bei Bedarf nach „Festplattenvollzugriff“ fragen.
