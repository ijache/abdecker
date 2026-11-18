# Rechnungsformat (JSON)

E-Rechnungen erstellen, ohne XML, BT-Nummern oder UNECE-Codes zu kennen: Man schreibt die
Rechnung als kleine JSON-Datei, abdecker macht daraus eine XRechnung oder eine
ZUGFeRD-/Factur-X-Rechnung (EN 16931, Syntax CII). Summen, Steueraufschlüsselung und
Pflichtangaben wie die Spezifikationskennung ergänzt abdecker selbst.

```json
{
  "number": "2026-0815",
  "issueDate": "{{today}}",
  "period": { "start": "2026-10-01", "end": "2026-10-31" },
  "dueDate": "2026-11-28",
  "seller": {
    "name": "Muster IT GmbH", "street": "Musterstraße 1", "postcode": "12345", "city": "Musterstadt",
    "vatId": "DE123456788",
    "iban": "DE02120300000000202051"
  },
  "buyer": { "name": "Kunde AG", "street": "Industriestraße 99", "postcode": "54321", "city": "Großstadt" },
  "lines": [
    { "name": "Softwareentwicklung", "quantity": 32.5, "unit": "hour", "price": 95.00, "vat": 19 }
  ]
}
```

Zu dieser Doku gehören:

- [Felder](fields.md): alle Felder mit Bedeutung, Standardwert und EN-16931-Begriff, dazu
  was welcher Fall verlangt
- [Ausgabe von `json`](output.md): die umgekehrte Richtung, eine vorhandene Rechnung als
  JSON, und wo sie vom Format abweicht
- [invoice.schema.json](invoice.schema.json): JSON-Schema für Editoren

## Schnellstart

1. Eine passende [Vorlage](#vorlagen) aus `templates/` kopieren und ausfüllen
2. Erstellen:

   ```sh
   abdecker create rechnung.json -o rechnung.xml
   ```

   Das Ergebnis ist eine CII-Datei. So wie sie ist, ist sie eine XRechnung (mit
   `"profile": "xrechnung"`) bzw. eine EN-16931-Rechnung zum Versand als XML

3. Für ZUGFeRD/Factur-X die XML-Datei in das PDF der Rechnung einbetten:

   ```sh
   abdecker embed rechnung.pdf rechnung.xml -o rechnung-zugferd.pdf
   ```

Dasselbe über den Server (`abdecker serve`):

```sh
curl --data-binary @rechnung.json -H "Content-Type: application/json" \
  "http://127.0.0.1:8080/create?nr=2026-0815" -o rechnung.xml
```

Die Antwort ist das XML. Meldungen der Prüfung stehen im Header `X-Abdecker-Messages`,
Fehler im Format selbst ergeben Status 422 mit einer JSON-Liste der Fehler.

## Vorlagen

Statt einer Datei mit allen Feldern gibt es je Fall eine vollständige Rechnung. Alle außer
`minimal` sind **streng**: Sie erfüllen XRechnung 3.0 samt den Peppol-Regeln, auch wenn sie als
EN 16931 (ZUGFeRD/Factur-X) erstellt werden. Wer eine davon kopiert, hat eine Rechnung, die
jeder Empfänger annimmt.

| Vorlage | Fall | Was sie zeigt |
| --- | --- | --- |
| [minimal](../../templates/minimal.json) | B2B, 19 %, kürzeste Form | Pflichtfelder für EN 16931; Rechnungsdatum `{{today}}`; nicht streng (keine Käuferreferenz, keine elektronischen Adressen) |
| [xrechnung](../../templates/xrechnung.json) | öffentlicher Auftraggeber | `"profile": "xrechnung"`, Leitweg-ID als `buyerReference` und als elektronische Adresse des Käufers |
| [reverse-charge](../../templates/reverse-charge.json) | Dienstleistung an ein Unternehmen im EU-Ausland | `"vatMode": "reverse-charge"`, `buyer.vatId`, `buyer.country`; kein `vat` an den Positionen |
| [small-business](../../templates/small-business.json) | Kleinunternehmer (§ 19 UStG) | `"vatMode": "small-business"`, Steuernummer statt USt-IdNr., `deliveryDate` statt `period` |
| [cash-discount](../../templates/cash-discount.json) | Skonto | `cashDiscount` zusätzlich zu `paymentTerms` |
| [correction](../../templates/correction.json) | Rechnungskorrektur | `"type": "correction"` mit **positiven** Beträgen, `precedingInvoice`; ohne IBAN: Verrechnung |

## Grundregeln

- **Reines JSON** in UTF-8 (BOM erlaubt): keine Kommentare, kein Komma nach dem letzten
  Element. Jede Vorlage funktioniert so, wie sie ist
- **Feldnamen** englisch in camelCase. Unbekannte und doppelte Felder sind Fehler, so fallen
  Tippfehler (`isueDate`) sofort auf
- **Zahlen** (Mengen, Preise, Sätze) als JSON-Zahl oder als String: `95.00` und `"95.00"`
  sind gleich. abdecker liest sie als Text, ohne Gleitkomma, und rechnet exakt. Punkt als
  Dezimaltrenner, kein Exponent, keine Tausenderpunkte
- **Datum** immer `JJJJ-MM-TT`, und es muss ein echtes Kalenderdatum sein
- **Was fehlt**, ist optional oder hat einen Standardwert:

  | Feld | Standard |
  | --- | --- |
  | `profile` | `"en16931"` (ZUGFeRD/Factur-X EN 16931) |
  | `type` | `"invoice"` (Rechnung, 380) |
  | `issueDate` | heute |
  | `currency` | `"EUR"` |
  | `seller.country`, `buyer.country` | `"DE"` |
  | `vatMode` | `"standard"` (Steuersatz je Position) |

### Was abdecker ergänzt

Das JSON enthält nur, was nur der Rechnungssteller wissen kann. abdecker ergänzt:

- Positionsnummern 1, 2, 3 …
- Positionsbetrag: Menge × Preis, auf zwei Nachkommastellen gerundet (kaufmännisch, ab 5
  weg von null)
- Steueraufschlüsselung je Steuersatz: Summe der Positionsbeträge, Steuer darauf gerundet
- Summen: Nettosumme, Steuer, Bruttosumme, Zahlbetrag. Wer `totals` mitschickt (etwa aus
  einer Warenwirtschaft), bekommt sie geprüft; weichen sie ab, entsteht keine Rechnung
- Zahlungsart: Überweisung (58), wenn `seller.iban` da ist; bei einer Korrektur ohne IBAN
  Verrechnung (97)
- Steuerkategorie je Position; bei Reverse Charge und Kleinunternehmern zusätzlich den
  Befreiungsgrund (Text, bei Reverse Charge auch den Code `VATEX-EU-AE`)
- Spezifikationskennung passend zum Profil und den Peppol-Geschäftsprozess
- Bei Skonto die Zeile `#SKONTO#TAGE=n#PROZENT=n.nn#`, die XRechnung verlangt

Beträge im XML haben zwei Nachkommastellen; Mengen, Preise und Sätze stehen dort so, wie sie
im JSON stehen.

## Platzhalter

In jedem String-Wert darf `{{name}}` stehen. abdecker ersetzt den Platzhalter beim Erstellen,
mehr nicht (keine Bedingungen, keine Schleifen). So wird eine Vorlage zur wiederkehrenden
Rechnung:

```json
{
  "number": "{{nr}}",
  "issueDate": "{{today}}",
  "period": { "start": "{{prevMonthStart}}", "end": "{{prevMonthEnd}}" },
  "dueDate": "{{today+14}}",
  "lines": [
    { "name": "Beratung", "quantity": "{{stunden}}", "unit": "hour", "price": 95.00, "vat": 19 }
  ]
}
```

Zahlen dürfen dafür als String stehen (`"quantity": "{{stunden}}"`), sie werden ohnehin als Text
gelesen.

**Eingebaut** (bezogen auf das heutige Datum):

| Platzhalter | Wert |
| --- | --- |
| `{{today}}` | heute |
| `{{today+N}}` | heute plus N Tage, z. B. `{{today+14}}` |
| `{{prevMonthStart}}` | erster Tag des Vormonats |
| `{{prevMonthEnd}}` | letzter Tag des Vormonats |

**Eigene Werte** gibt man beim Erstellen mit:

```sh
abdecker create rechnung.json --vars werte.json --var nr=2026-0815 -o rechnung.xml
```

- `--var name=wert` einzeln, beliebig oft
- `--vars datei.json` aus einem JSON-Objekt: Strings und Zahlen auf oberster Ebene, alles
  andere wird übergangen, z. B. `{ "nr": "2026-0815", "stunden": 7.5 }`
- Beim Server ist jeder Query-Parameter ein Wert: `POST /create?nr=2026-0815&stunden=7.5`
- Vorrang: `--var` vor `--vars` vor den eingebauten. Ein eigener Wert `today` ersetzt nur
  `{{today}}`, nicht `{{today+N}}`, die Vormonats-Platzhalter oder das Standard-Rechnungsdatum

Ein Platzhalter ohne Wert ist ein Fehler, mit Zeile und Spalte. Ersetzt wird im gelesenen
Wert, nicht im Rohtext: Anführungszeichen oder Backslashes in einem Wert können das JSON nicht
beschädigen.

## Prüfung und Fehlermeldungen

Erstellen läuft in zwei Stufen:

1. **Format lesen.** Fehler im JSON selbst verhindern die Rechnung. abdecker meldet alle auf
   einmal, nicht nur den ersten, jeweils mit Zeile, Spalte und Pfad des Felds:

   ```text
   [Error] JSON-FIELD: line 3, column 3: isueDate: unknown field
   [Error] JSON-VALUE: line 9, column 39: lines[1].quantity: "1,5" is not a number (digits with "." as decimal point)
   [Error] JSON-MISSING: line 9, column 5: lines[1].vat: required
   ```

   `create` endet dann mit Exit-Code 1 ohne Ausgabedatei, der Server antwortet mit 422

2. **Rechnung prüfen.** Das fertige XML durchläuft die Prüfung von abdecker (wie
   `abdecker check`): EN 16931 und, beim Profil `xrechnung`, die XRechnung- und
   Peppol-Regeln. Das XML wird auch mit Befunden geschrieben; `create` endet bei Fehlern mit
   Exit-Code 1 (mit `--fail-on warning` auch bei Warnungen). Der Server liefert das XML mit
   Status 200 und die Befunde im Header `X-Abdecker-Messages`

   ```text
   [Error] BR-DE-15: XRechnung: buyer reference (BT-10, Leitweg-ID) is missing.
   Saved as rechnung.xml
   Check: 1 error(s), 0 warning(s)
   ```

Die Codes der ersten Stufe:

| Code | Bedeutung |
| --- | --- |
| `JSON-SYNTAX` | kein gültiges JSON (Zeile und Spalte in der Meldung) |
| `JSON-TYPE` | falscher Typ, z. B. eine Zahl, wo ein String stehen muss |
| `JSON-FIELD` | unbekanntes Feld, oder ein Feld, das in diesem Fall nicht erlaubt ist (`vat` bei Reverse Charge) |
| `JSON-DUPLICATE` | Feld doppelt angegeben |
| `JSON-MISSING` | Pflichtfeld fehlt |
| `JSON-VALUE` | unzulässiger Wert: keine Zahl, kein Datum, unbekannter Wert bei `profile`, `type`, `vatMode` |
| `JSON-PLACEHOLDER` | Platzhalter ohne Wert oder `{{` ohne `}}` |
| `JSON-ATTACHMENT` | Anhang nicht lesbar, leer, doppelt oder Dateityp nicht erlaubt |
| `JSON-TOTALS` | mitgeschickte Summe weicht von der berechneten ab |
| `JSON-OPTION` | ungültige Option beim Aufruf (Variable ohne `name=`, ungültiges „heute“) |

## Editor-Unterstützung

[invoice.schema.json](invoice.schema.json) beschreibt das Format als JSON-Schema (Draft 7). Ein
Editor, der JSON-Schema kennt, vervollständigt damit Feldnamen und Werte, zeigt die
Erklärungen beim Überfahren an und markiert Tippfehler und fehlende Pflichtfelder.

In VS Code etwa in den Einstellungen (`settings.json`), für alle Dateien in einem Ordner
`rechnungen`:

```json
"json.schemas": [
  {
    "fileMatch": ["rechnungen/*.json"],
    "url": "./docs/invoice-json/invoice.schema.json"
  }
]
```

Ein Feld `"$schema"` in der Rechnung selbst geht nicht: abdecker lehnt es als unbekanntes Feld ab.

Das Schema kennt das Format und die wichtigsten Pflichtfelder je Profil und Fall. Es weiß
nicht alles: ob ein Datum im Kalender existiert, ob eine IBAN stimmt, ob die Summen passen.
Maßgeblich ist, was `abdecker create` meldet.

## In eigenen Programmen

Die Lib liest das Format mit `TAbdecker.InvoiceFromJson` in das Rechnungsmodell und schreibt
es mit `TAbdecker.WriteCII` als CII, samt Prüfung:

```pascal
var
  opt: TAbJsonOptions;
  inv: TEInvoice;
  msgs: TAbMessages;
  rep: TAbCheckReport;
  xml: TBytes;
begin
  opt := Default(TAbJsonOptions);  // Today = Systemdatum, keine Variablen, keine Dateien
  if TAbdecker.InvoiceFromJson(json, opt, inv, msgs) <> abOK then exit;  // Format-Fehler in msgs
  if TAbdecker.WriteCII(inv, xml, rep) <> abOK then exit;
  // xml ist die Rechnung; rep.Messages die Befunde der Prüfung, rep.Failed bei Fehlern
end;
```

`TAbJsonOptions` hat drei Felder: `Today` (`JJJJ-MM-TT` für `{{today}}` und das
Standard-Rechnungsdatum, leer = Systemdatum), `Vars` (Werte als `'name=wert'`, sie gehen den
eingebauten Platzhaltern vor) und `BaseDir` (Ordner für Anhänge mit `"file"`; leer = solche
Anhänge sind nicht erlaubt).
