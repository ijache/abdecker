# Ausgabe von `json`

Die umgekehrte Richtung zum [Rechnungsformat](README.md): `abdecker json` (Server:
`POST /json`) gibt eine vorhandene E-Rechnung als JSON aus, ob XRechnung, ZUGFeRD/Factur-X
oder UBL, als PDF oder XML. Gedacht zum Weiterverarbeiten: Import in die Buchhaltung, Skripte,
Tabellen.

```sh
abdecker json rechnung.pdf -o rechnung.json
```

Die Ausgabe ist eine **reduzierte, flache Sicht**, nicht das ganze Rechnungsmodell. Wo ein Feld
dasselbe bedeutet wie im Rechnungsformat, heißt es auch so. Dazu kommt, was zum Weiterverarbeiten
nötig ist und das Format nicht kennt: Positionsbeträge, Steueraufschlüsselung, Zu- und
Abschläge, Anzahlungen.

Die Ausgabe ist **keine Eingabe für `create`**. Viele Felder passen, aber nicht alle (siehe
Spalte „wie `create`“), und eine fremde Rechnung kann mehr enthalten, als das Format ausdrücken
kann.

## Aufbau

```json
{
  "file": "rechnung.pdf",
  "result": "ok",
  "syntax": "cii",
  "profile": "en16931",
  "xrechnungVersion": "",
  "invoice": { ... },
  "messages": []
}
```

| Feld | Bedeutung |
| --- | --- |
| `file` | die gelesene Datei, wie angegeben |
| `result` | `ok`, sonst warum nicht: `no-invoice`, `unknown-format`, `file-error`, `broken-pdf`, `broken-xml`, `encrypted`, `unsupported`, `invalid-data`, `internal-error` |
| `syntax` | `cii`, `ubl-invoice`, `ubl-creditnote`, `zugferd1` |
| `profile` | `minimum`, `basicwl`, `basic`, `comfort`, `en16931`, `extended`, `xrechnung`, `peppol` |
| `xrechnungVersion` | z. B. `3.0` bei `xrechnung`, sonst leer |
| `invoice` | die Rechnung, siehe unten; `{}`, wenn `result` nicht `ok` ist |
| `messages` | Meldungen beim Lesen, je `{ "severity", "code", "origin", "text" }`; `severity` ist `info`, `warning` oder `error` |

Die Ausgabe enthält **keine Prüfung**; dafür gibt es `abdecker check --json`.

## Die Rechnung (`invoice`)

Leere Felder fehlen. Beträge, Mengen und Sätze sind JSON-Zahlen, genau so geschrieben wie in der
Rechnung (`95.00` bleibt `95.00`); wer sie exakt braucht, liest sie als Text. Elemente einer
Liste bleiben immer erhalten, notfalls als `{}`, damit die Positionen zur Rechnung passen.

Spalte **wie `create`**: ✓ = dieselbe Bedeutung und Schreibweise wie im Rechnungsformat;
≈ = gleiche Bedeutung, aber Abweichungen (siehe Anmerkung); leer = nur in der Ausgabe.

| Feld | Bedeutung | BT/BG | wie `create` |
| --- | --- | --- | --- |
| `typeCode` | Rechnungsart als Code: 380 Rechnung, 381 Korrektur, 384, 389 … | BT-3 | ≈ statt `type` |
| `number` | Rechnungsnummer | BT-1 | ✓ |
| `issueDate` | Rechnungsdatum | BT-2 | ✓ |
| `dueDate` | Fälligkeitsdatum | BT-9 | ✓ |
| `currency` | Währung | BT-5 | ✓ |
| `buyerReference` | Käuferreferenz | BT-10 | ✓ |
| `orderReference` | Bestellnummer | BT-13 | ✓ |
| `period.start`, `period.end` | Leistungszeitraum | BG-14 | ✓ |
| `deliveryDate` | Lieferdatum | BT-72 | ✓ |
| `precedingInvoice.number`, `.issueDate` | korrigierte Rechnung (die erste, falls mehrere) | BG-3 | ✓ |
| `note` | Freitext; mehrere Bemerkungen durch Zeilenumbruch getrennt | BT-22 | ✓ |
| `paymentTerms` | Zahlungsbedingungen, vollständig | BT-20 | ≈ enthält auch die Skonto-Zeilen |
| `seller` | Verkäufer, siehe unten | BG-4 | ✓ |
| `buyer` | Käufer, siehe unten | BG-7 | ✓ |
| `paymentMeans` | Zahlungsart als Code: 58 Überweisung, 59 Lastschrift, 97 Verrechnung … | BT-81 | |
| `lines` | Positionen, siehe unten | BG-25 | ✓ |
| `allowancesCharges` | Zu- und Abschläge auf Rechnungsebene, siehe unten | BG-20, BG-21 | |
| `vat` | Steueraufschlüsselung, siehe unten | BG-23 | |
| `totals` | Summen, siehe unten | BG-22 | ✓ |
| `attachments` | Anhänge, nur die Angaben, ohne Inhalt | BG-24 | ≈ andere Felder |

Anmerkungen:

- **`typeCode`** ist der Code selbst, `create` kennt nur `"type": "invoice"` (380) und
  `"correction"` (381)
- **`paymentTerms`** ist der Text, wie er in der Rechnung steht. Eine von `create` erzeugte
  Rechnung mit `cashDiscount` hat hier zusätzlich die Zeile `#SKONTO#TAGE=…#PROZENT=…#`;
  `cashDiscount` selbst gibt es in der Ausgabe nicht
- Kein `vatMode`: Die Ausgabe nennt die Steuerkategorie je Position und in `vat`
- Kein `profile` in `invoice`: Es steht oben neben `syntax` und kennt alle Profile

### `seller` und `buyer`

Dieselben Felder wie im Rechnungsformat (✓), dazu:

| Feld | Bedeutung | BT/BG | wie `create` |
| --- | --- | --- | --- |
| `line3` | dritte Zeile der Anschrift | BT-162, BT-163 | |
| `country` | Land, nur wenn es in der Rechnung steht (kein Standardwert) | BT-40, BT-55 | ✓ |
| `id` | erste Kennung der Partei | BT-29, BT-46 | ✓ beim Verkäufer, beim Käufer nur in der Ausgabe |
| `electronicAddress` | immer als Objekt `{ "scheme", "id" }`, auch für E-Mail (`"scheme": "EM"`) | BT-34, BT-49 | ≈ `create` erlaubt für E-Mail auch einen String |
| `iban`, `bic`, `accountName` | beim Verkäufer: das erste Konto für die Überweisung | BT-84 bis BT-86 | ✓ |

### `lines`

| Feld | Bedeutung | BT/BG | wie `create` |
| --- | --- | --- | --- |
| `name` | Bezeichnung | BT-153 | ✓ |
| `description` | Beschreibung | BT-154 | ✓ |
| `itemNumber` | Artikelnummer des Verkäufers | BT-155 | ✓ |
| `quantity` | Menge | BT-129 | ✓ |
| `unit` | Einheit als UNECE-Code (`HUR`, `H87` …) | BT-130 | ≈ `create` kennt auch Namen wie `"hour"`; Codes nimmt es ebenso |
| `price` | Nettopreis je `baseQuantity` | BT-146 | ✓ wenn `baseQuantity` fehlt oder 1 ist |
| `baseQuantity` | Menge, auf die sich der Preis bezieht (z. B. Preis je 100 Stück) | BT-149 | |
| `net` | Positionsbetrag netto | BT-131 | |
| `vat` | Steuersatz in Prozent, bei jeder Kategorie (auch 0) | BT-152 | ≈ in `create` nur bei `"vatMode": "standard"` |
| `vatCategory` | Steuerkategorie: S Standard, AE Reverse Charge, E steuerfrei, K innergemeinschaftliche Lieferung, Z, G, O, L, M | BT-151 | |

### `allowancesCharges`

Zu- und Abschläge auf die ganze Rechnung (das Format kennt sie nicht).

| Feld | Bedeutung | BT/BG |
| --- | --- | --- |
| `charge` | `true` = Zuschlag, `false` = Abschlag | |
| `amount` | Betrag netto | BT-92, BT-99 |
| `reason` | Grund | BT-97, BT-104 |
| `vat` | Steuersatz in Prozent | BT-96, BT-103 |
| `vatCategory` | Steuerkategorie | BT-95, BT-102 |

### `vat`

Die Steueraufschlüsselung, eine Zeile je Kategorie und Satz. Nicht verwechseln mit `lines[].vat`
und `totals.vat`, die je eine Zahl sind.

| Feld | Bedeutung | BT/BG |
| --- | --- | --- |
| `category` | Steuerkategorie wie bei `lines[].vatCategory` | BT-118 |
| `rate` | Steuersatz in Prozent | BT-119 |
| `net` | Bemessungsgrundlage | BT-116 |
| `vat` | Steuerbetrag | BT-117 |
| `exemptionReason` | Befreiungsgrund als Text | BT-120 |

### `totals`

| Feld | Bedeutung | BT/BG | wie `create` |
| --- | --- | --- | --- |
| `net` | Nettosumme (nach Zu- und Abschlägen) | BT-109 | ✓ |
| `vat` | Umsatzsteuer | BT-110 | ✓ |
| `gross` | Bruttosumme | BT-112 | ✓ |
| `prepaid` | bereits gezahlt (Anzahlungen) | BT-113 | |
| `rounding` | Rundungsbetrag | BT-114 | |
| `due` | Zahlbetrag | BT-115 | ✓ |

### `attachments`

Die Anhänge der Rechnung (BG-24), ohne Inhalt. Die Dateien selbst speichert
`abdecker attachments rechnung.pdf -o ordner`.

| Feld | Bedeutung | BT/BG | wie `create` |
| --- | --- | --- | --- |
| `id` | Kennung des Anhangs | BT-122 | |
| `name` | Dateiname | BT-125 | ✓ |
| `description` | Beschreibung | BT-123 | ✓ |
| `mimeType` | Dateityp, z. B. `application/pdf` | BT-125 | |
| `uri` | Verweis auf ein externes Dokument statt eingebetteter Datei | BT-124 | |
| `size` | Größe in Bytes, wenn eingebettet | | |

## Beispiel

Die Vorlage [cash-discount](../../templates/cash-discount.json), erstellt und wieder gelesen
(gekürzt):

```json
{
  "file": "cash-discount.xml",
  "result": "ok",
  "syntax": "cii",
  "profile": "en16931",
  "xrechnungVersion": "",
  "invoice": {
    "typeCode": "380",
    "number": "2026-0817",
    "issueDate": "2026-11-14",
    "dueDate": "2026-12-14",
    "currency": "EUR",
    "buyerReference": "KST-4711",
    "orderReference": "PO-2026-1234",
    "period": { "start": "2026-10-01", "end": "2026-10-31" },
    "paymentTerms": "Zahlbar innerhalb von 30 Tagen, bei Zahlung innerhalb von 10 Tagen 2 % Skonto.\n#SKONTO#TAGE=10#PROZENT=2.00#\n",
    "seller": {
      "name": "Muster IT GmbH",
      "country": "DE",
      "vatId": "DE123456788",
      "electronicAddress": { "scheme": "EM", "id": "rechnung@muster-it.de" },
      "iban": "DE02120300000000202051"
    },
    "buyer": { "name": "Kunde AG", "country": "DE" },
    "paymentMeans": "58",
    "lines": [
      { "name": "Softwareentwicklung", "quantity": 32.5, "unit": "HUR", "price": 95.00, "net": 3087.50, "vat": 19, "vatCategory": "S" },
      { "name": "Lizenz Werkzeug XY", "quantity": 3, "unit": "H87", "price": 49.90, "net": 149.70, "vat": 19, "vatCategory": "S" }
    ],
    "vat": [
      { "category": "S", "rate": 19, "net": 3237.20, "vat": 615.07 }
    ],
    "totals": { "net": 3237.20, "vat": 615.07, "gross": 3852.27, "due": 3852.27 }
  },
  "messages": []
}
```

Die echte Ausgabe schreibt jedes Feld in eine eigene Zeile.
