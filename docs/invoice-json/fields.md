# Rechnungsformat: Felder

Alle Felder des [Rechnungsformats](README.md). In der Spalte **BT/BG** steht der Begriff aus
EN 16931, der europäischen Norm für E-Rechnungen; er hilft beim Abgleich mit anderen
Programmen und mit den Meldungen der Prüfung. **Pflicht** heißt: Ohne das Feld entsteht
keine Rechnung (Format-Fehler) oder die Prüfung meldet einen Fehler.

Überblick:

```text
profile  type  number  issueDate  currency  buyerReference  orderReference
period { start, end }  deliveryDate  precedingInvoice { number, issueDate }  note
dueDate  paymentTerms  cashDiscount { days, percent }
seller { name, street, line2, postcode, city, country, vatId, taxNumber, id, legalInfo,
         contact { name, phone, email }, electronicAddress, iban, bic, accountName }
buyer { name, street, line2, postcode, city, country, vatId, electronicAddress }
vatMode
lines [ { name, description, itemNumber, quantity, unit, price, vat } ]
attachments [ { file | name + content, description } ]
totals { net, vat, gross, due }
```

## Rechnung

| Feld | Bedeutung | BT/BG | Pflicht / Standard |
| --- | --- | --- | --- |
| `profile` | `"en16931"`: ZUGFeRD/Factur-X EN 16931, reicht für B2B. `"xrechnung"`: XRechnung 3.0, für öffentliche Auftraggeber oder wenn der Kunde sie verlangt | BT-24 | Standard `"en16931"` |
| `type` | `"invoice"`: Rechnung (380). `"correction"`: Rechnungskorrektur (381), Beträge positiv | BT-3 | Standard `"invoice"` |
| `number` | Rechnungsnummer, fortlaufend und einmalig | BT-1 | Pflicht |
| `issueDate` | Rechnungsdatum | BT-2 | Standard: heute |
| `currency` | Währung, ISO 4217 | BT-5 | Standard `"EUR"` |
| `buyerReference` | Käuferreferenz; bei Behörden die Leitweg-ID | BT-10 | Pflicht bei `xrechnung` |
| `orderReference` | Bestellnummer des Kunden | BT-13 | |
| `period.start`, `period.end` | Leistungszeitraum | BG-14 | `period` oder `deliveryDate`, siehe unten |
| `deliveryDate` | Liefer- bzw. Leistungsdatum | BT-72 | |
| `precedingInvoice.number` | Nummer der korrigierten Rechnung | BT-25 | Pflicht im Objekt |
| `precedingInvoice.issueDate` | Datum der korrigierten Rechnung | BT-26 | |
| `note` | Freitext zur Rechnung | BT-22 | |

Zeitpunkt der Leistung: Weder EN 16931 noch XRechnung prüfen ihn, aber § 14 UStG verlangt ihn
auf jeder Rechnung. Also `period` für einen Zeitraum oder `deliveryDate` für einen Tag angeben.

## Zahlung

| Feld | Bedeutung | BT/BG | Pflicht / Standard |
| --- | --- | --- | --- |
| `dueDate` | Fälligkeitsdatum | BT-9 | `dueDate` oder `paymentTerms` (EN 16931, BR-CO-25) |
| `paymentTerms` | Zahlungsbedingungen als Text | BT-20 | |
| `cashDiscount.days` | Skontofrist in Tagen (ganze Zahl ab 1) | in BT-20 | Pflicht im Objekt |
| `cashDiscount.percent` | Skontosatz in Prozent | in BT-20 | Pflicht im Objekt |
| `seller.iban` | Konto für die Überweisung | BT-84 | Pflicht, außer bei einer Korrektur, die verrechnet wird |
| `seller.bic` | BIC | BT-86 | nur mit `iban` |
| `seller.accountName` | Kontoinhaber | BT-85 | nur mit `iban` |

Gezahlt wird per **Überweisung** (Zahlungsart 58) auf `seller.iban`. Eine **Korrektur** ohne
`seller.iban` wird **verrechnet** (Zahlungsart 97, ohne Bankverbindung); wie, steht in
`paymentTerms`, z. B. „Wir verrechnen den Betrag mit der Rechnung 2026-0815.“ Eine Erstattung
per Überweisung an den Kunden kennt das Format nicht.

Aus `cashDiscount` schreibt abdecker an das Ende von `paymentTerms` die Zeile, die XRechnung für
Skonto vorschreibt, z. B. `#SKONTO#TAGE=10#PROZENT=2.00#`. Den Satz für Menschen („bei Zahlung
innerhalb von 10 Tagen 2 % Skonto“) schreibt man selbst in `paymentTerms`.

## Verkäufer (`seller`)

Wer die Rechnung stellt (BG-4). Pflicht.

| Feld | Bedeutung | BT/BG | Pflicht / Standard |
| --- | --- | --- | --- |
| `name` | Name bzw. Firma | BT-27 | Pflicht |
| `street` | Straße und Hausnummer | BT-35 | Pflicht nach § 14 UStG |
| `line2` | Zusatzzeile der Anschrift | BT-36 | |
| `postcode` | Postleitzahl | BT-38 | Pflicht bei `xrechnung`, nach § 14 UStG immer |
| `city` | Ort | BT-37 | Pflicht bei `xrechnung`, nach § 14 UStG immer |
| `country` | Land, ISO 3166-1 (zwei Buchstaben) | BT-40 | Standard `"DE"` |
| `vatId` | Umsatzsteuer-Identifikationsnummer | BT-31 | `vatId` oder `taxNumber` |
| `taxNumber` | Steuernummer | BT-32 | `vatId` oder `taxNumber` |
| `id` | Kennung des Verkäufers, z. B. die Lieferantennummer beim Kunden | BT-29 | |
| `legalInfo` | Rechtliche Angaben: Geschäftsführer, Registergericht, HRB | BT-33 | für GmbH und AG, siehe unten |
| `contact.name` | Ansprechpartner | BT-41 | Pflicht bei `xrechnung` |
| `contact.phone` | Telefon | BT-42 | Pflicht bei `xrechnung` |
| `contact.email` | E-Mail | BT-43 | Pflicht bei `xrechnung` |
| `electronicAddress` | Elektronische Adresse, siehe unten | BT-34 | Pflicht bei `xrechnung` |
| `iban`, `bic`, `accountName` | siehe [Zahlung](#zahlung) | BT-84 bis BT-86 | |

**Nur Steuernummer:** EN 16931 verlangt eine Kennung des Verkäufers (BT-29), eine
Registernummer (BT-30) oder die USt-IdNr. (BT-31); die Steuernummer allein zählt nicht.
Fehlen `vatId` und `id`, schreibt abdecker die Steuernummer deshalb zusätzlich als Kennung
(BT-29). Das ist zulässig und üblich, etwa bei Kleinunternehmern.

**`legalInfo`:** GmbH und AG müssen Geschäftsführer bzw. Vorstand, Registergericht und
Registernummer auf Geschäftsbriefen nennen (§ 35a GmbHG, § 80 AktG), Rechnungen zählen dazu.

## Käufer (`buyer`)

Wer die Rechnung bekommt (BG-7). Pflicht.

| Feld | Bedeutung | BT/BG | Pflicht / Standard |
| --- | --- | --- | --- |
| `name` | Name bzw. Firma | BT-44 | Pflicht |
| `street` | Straße und Hausnummer | BT-50 | Pflicht nach § 14 UStG |
| `line2` | Zusatzzeile der Anschrift | BT-51 | |
| `postcode` | Postleitzahl | BT-53 | Pflicht bei `xrechnung`, nach § 14 UStG immer |
| `city` | Ort | BT-52 | Pflicht bei `xrechnung`, nach § 14 UStG immer |
| `country` | Land, ISO 3166-1 (zwei Buchstaben) | BT-55 | Standard `"DE"` |
| `vatId` | Umsatzsteuer-Identifikationsnummer | BT-48 | Pflicht bei Reverse Charge |
| `electronicAddress` | Elektronische Adresse, siehe unten | BT-49 | Pflicht bei `xrechnung` |

## Elektronische Adressen

`seller.electronicAddress` und `buyer.electronicAddress` sagen, wohin E-Rechnungen gehen
(Peppol und XRechnung verlangen beide). Zwei Schreibweisen:

```json
"electronicAddress": "rechnung@muster-it.de"
"electronicAddress": { "scheme": "0204", "id": "04011000-12345-03" }
```

Ein String ist eine E-Mail-Adresse (Schema `EM`). Sonst `scheme` (EAS-Code) und `id`, beide
Pflicht. Häufige Schemata: `0204` Leitweg-ID (Behörden), `9930` deutsche USt-IdNr., `0088` GLN.

## Steuer (`vatMode`)

Die Steuer gilt für die ganze Rechnung:

| `vatMode` | Fall | Was abdecker schreibt | `lines[].vat` |
| --- | --- | --- | --- |
| `"standard"` (Standard) | normale Umsatzsteuer | Kategorie S mit dem Satz jeder Position; je Satz eine Zeile der Steueraufschlüsselung | Pflicht |
| `"reverse-charge"` | Steuerschuldnerschaft des Leistungsempfängers (§ 13b UStG, Dienstleistung an ein Unternehmen im EU-Ausland) | Kategorie AE, 0 %, Befreiungsgrund „Steuerschuldnerschaft des Leistungsempfängers“, Code `VATEX-EU-AE` | nicht erlaubt |
| `"small-business"` | Kleinunternehmer (§ 19 UStG) | Kategorie E, 0 %, Befreiungsgrund „Kleinunternehmer gemäß § 19 UStG“ | nicht erlaubt |

Bei Reverse Charge braucht der Käufer eine USt-IdNr. (`buyer.vatId`), meist auch ein anderes
Land (`buyer.country`). Gemischte Sätze (19 % und 7 %) gehen mit `"standard"`: Jede Position
hat ihren eigenen Satz.

## Positionen (`lines`)

Mindestens eine (BG-25). Die Nummern 1, 2, 3 … vergibt abdecker.

| Feld | Bedeutung | BT/BG | Pflicht / Standard |
| --- | --- | --- | --- |
| `name` | Bezeichnung der Leistung oder Ware | BT-153 | Pflicht |
| `description` | Beschreibung | BT-154 | |
| `itemNumber` | Artikelnummer des Verkäufers | BT-155 | |
| `quantity` | Menge | BT-129 | Pflicht |
| `unit` | Einheit, siehe unten | BT-130 | Pflicht |
| `price` | Nettopreis je Einheit | BT-146 | Pflicht |
| `vat` | Umsatzsteuersatz in Prozent, z. B. `19` oder `7` | BT-152 | Pflicht bei `"vatMode": "standard"`, sonst nicht erlaubt |

`vat` hat bewusst keinen Standardwert: 7 % sollen nicht versehentlich zu 19 % werden.

Den Positionsbetrag (Menge × Preis, BT-131) rechnet abdecker, auf zwei Nachkommastellen
gerundet.

### Einheiten

| `unit` | Bedeutung | UNECE-Code |
| --- | --- | --- |
| `"hour"` | Stunde | HUR |
| `"day"` | Tag | DAY |
| `"month"` | Monat | MON |
| `"piece"` | Stück | H87 |
| `"lump"` | pauschal | LS |
| `"km"` | Kilometer | KMT |

Jeder andere Wert geht unverändert als UNECE-Code (Empfehlung 20) in die Rechnung, z. B.
`"MTR"` (Meter), `"KGM"` (Kilogramm), `"LTR"` (Liter).

## Anhänge (`attachments`)

Dateien, die mit der Rechnung reisen (BG-24), z. B. ein Stundennachweis. Erlaubt sind PDF,
PNG, JPEG, CSV, XLSX und ODS; erkannt wird der Typ an der Endung. Je Anhang eine von zwei
Formen:

```json
"attachments": [
  { "file": "stundennachweis-2026-10.pdf", "description": "Stundennachweis Oktober 2026" },
  { "name": "lieferschein.pdf", "content": "JVBERi0xLjQK...", "description": "Lieferschein" }
]
```

| Feld | Bedeutung | BT/BG |
| --- | --- | --- |
| `file` | Pfad der Datei, relativ zur JSON-Datei (bei Eingabe über die Standardeingabe: zum aktuellen Ordner). Nur auf der Kommandozeile | BT-125 |
| `name` | Dateiname mit Endung, zusammen mit `content` | BT-125 |
| `content` | Inhalt, base64. So beim Server, wo `file` nicht geht | BT-125 |
| `description` | Beschreibung | BT-123 |

Leere Dateien und zwei Anhänge mit demselben Namen sind Fehler. Anhänge stecken im XML; ins
PDF bettet `abdecker embed` nur das XML ein, die Anhänge reisen darin mit.

## Summen (`totals`)

Optional. abdecker rechnet alle Summen selbst. Wer sie mitschickt, bekommt sie geprüft: Weicht
eine ab, entsteht keine Rechnung (`JSON-TOTALS`). Gedacht für Programme, die selbst rechnen und
sicher sein wollen, dass beide dasselbe meinen.

| Feld | Bedeutung | BT/BG |
| --- | --- | --- |
| `net` | Nettosumme: Summe der Positionsbeträge | BT-109 |
| `vat` | Umsatzsteuer: Summe der Steuer je Satz | BT-110 |
| `gross` | Bruttosumme | BT-112 |
| `due` | Zahlbetrag | BT-115 |

## Was welcher Fall verlangt

Drei Stellen reden mit: **EN 16931**, die europäische Norm (Pflichtfelder und Rechenregeln,
gilt für jede E-Rechnung, auch für ZUGFeRD/Factur-X); **XRechnung**, die deutsche Ausprägung
mit zusätzlichen Regeln (Pflicht bei öffentlichen Auftraggebern, sonst nur, wenn der Kunde
sie verlangt); und **§ 14 UStG**, das Steuerrecht. Was § 14 UStG verlangt (vollständige
Anschriften, Zeitpunkt der Leistung), prüft keine Software, es entscheidet aber über den
Vorsteuerabzug des Kunden.

Immer, also schon für die kürzeste Rechnung ([minimal](../../templates/minimal.json)):

- `number`, `seller`, `buyer` und mindestens eine Position mit `name`, `quantity`, `unit`,
  `price` und (bei `"standard"`) `vat`
- `seller.name` und `buyer.name`, dazu die Anschriften (`street`, `postcode`, `city`)
- `seller.vatId` oder `seller.taxNumber`
- `seller.iban` (Überweisung) oder `"type": "correction"` (Verrechnung)
- `dueDate` oder `paymentTerms`
- `period` oder `deliveryDate`

Zusätzlich je nach Fall:

| Fall | Was dazukommt |
| --- | --- |
| XRechnung (`"profile": "xrechnung"`) | `buyerReference` (bei Behörden die Leitweg-ID), `seller.contact` mit Name, Telefon und E-Mail, `seller.electronicAddress`, `buyer.electronicAddress`; eine IBAN mit falscher Prüfziffer gibt eine Warnung |
| Reverse Charge | `"vatMode": "reverse-charge"`, `buyer.vatId`, kein `vat` an den Positionen |
| Kleinunternehmer | `"vatMode": "small-business"`, kein `vat` an den Positionen |
| Rechnungskorrektur | `"type": "correction"`, `precedingInvoice` mit Nummer und Datum der korrigierten Rechnung |
| GmbH, AG | `seller.legalInfo` |

Die Vorlagen außer `minimal` erfüllen auch die XRechnung-Regeln; wer eine davon nimmt, hat
alles beisammen.
