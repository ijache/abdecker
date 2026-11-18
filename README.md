# abdecker

E-Rechnungen (XRechnung, ZUGFeRD, Factur-X) für Delphi und FPC – ohne Abhängigkeiten
außer der RTL.

- **Eine Library** für Delphi und FPC ohne weitere Abhängigkeiten (außer RTL)
- **Ein CLI-Tool**, dass alle Funktionen bequem über die Kommandozeile bereit stellt
- **Ein Webservice**, der alle Funktionen via REST-API bereit stellt.
- **Status:** erste Fassung (0.1). Getestet gegen über 300 Rechnungen aus öffentlichen
Testkorpora, auf Windows und Linux, mit Delphi und FPC.
## Funktionen:

- **Erkennen:** Format und Profil einer Rechnung (PDF oder XML), das XML aus einem
  ZUGFeRD-/Factur-X-PDF ziehen
- **Lesen:** CII, UBL (Rechnung und Gutschrift) und ZUGFeRD 1.0 in ein gemeinsames
  Rechnungsmodell
- **Prüfen:** Plausibilität nach EN 16931 und XRechnung 3.0, auf Wunsch mit Status je Regel
- **Anzeigen:** Rechnung als HTML-Seite, die Zahlung wie ein Überweisungsträger mit
  GiroCode für Banking-Apps
- **Erstellen:** Rechnung aus einem einfachen JSON-Format mit Vorlagen und Platzhaltern,
  als CII ([Doku und JSON-Schema](docs/invoice-json/README.md))
- **Einbetten:** CII- oder UBL-Rechnung in ein vorhandenes PDF (ergibt ZUGFeRD/Factur-X),
  XML wieder aus dem PDF entfernen
- **Anhänge:** an die XML-Rechnung hängen und herausholen (aus XML und PDF)
- **Weiterverarbeiten:** Rechnung als schlichtes JSON



## Aufbau

```text
source/     die Lib (ein uses abdecker reicht)
cli/        Kommandozeilen-Tool und HTTP-Dienst
data/       Prüfregeln, Codelisten, OpenAPI-Beschreibung (Quelle für generierten Code)
templates/  Vorlagen im JSON-Rechnungsformat
docs/       Doku des JSON-Rechnungsformats samt JSON-Schema
tests/      Testrunner, Referenztests und Referenzergebnisse
tools/      Testdaten laden, Code aus data/ generieren
```

## Bauen und testen

Windows mit Delphi 12: `build.bat`. Mit Free Pascal 3.2.2 (Linux, macOS, Windows 64 Bit
aus der Git Bash): `sh build-fpc.sh`. Beide legen `abdecker` und `abdeckertests` nach
`bin/`.

```text
sh tools/fetch-testdata.sh    (einmalig, ca. 150 MB)
bin/abdeckertests             (--update übernimmt neue Korpus-Ergebnisse als Referenz)
python tests/cli.py           (CLI-Referenz; --update übernimmt)
python tests/serve.py         (Server-Referenz; --update übernimmt)
python tests/schema.py        (JSON-Schema; mit dem Paket jsonschema auch die Vorlagen)
python tests/qr.py            (QR-Encoder gegen das Paket segno)
```

Die Referenzen gelten für alle Plattformen und beide Compiler. Die beiden Referenztests
prüfen mit `ABDECKER_EXE=<pfad>` auch einen Build an anderer Stelle.

Unter FPC setzt die Unit `abdecker` beim Start die Codepage des Programms auf UTF-8
(`DefaultSystemCodePage`, wie LazUTF8 in Lazarus-Programmen) und bindet unter Unix
`cwstring` ein.

## Beispiel

```pascal
uses abdecker;

var
  info: TEInvoiceInfo;
  msgs: TAbMessages;
begin
  if TAbdecker.Info('rechnung.pdf', info, msgs) = abOK then begin
    Writeln(TAbdecker.ProfileName(info.Profile), ' ', info.InvoiceNumber);
  end;
end;

var
  inv: TEInvoice;
begin
  if TAbdecker.Load('rechnung.xml', inv, msgs) = abOK then begin
    Writeln(inv.Seller.Name, ': ', inv.Totals.DuePayable.ToString, ' ', inv.Currency);
  end;
end;
```

```text
abdecker info rechnung.pdf [--json]
abdecker extract rechnung.pdf [-o rechnung.xml]
abdecker check rechnung.pdf [--json] [-v] [--fail-on warning]
abdecker embed brief.pdf rechnung.xml -o rechnung.pdf
abdecker attachments rechnung.xml [-o anhaenge]
abdecker attachments rechnung.pdf --index 2 -o stundenzettel.pdf
abdecker html rechnung.pdf --open [--lang en] [--payment]
abdecker json rechnung.pdf [-o rechnung.json]
abdecker create templates/minimal.json --var today=2026-11-14 -o rechnung.xml
abdecker serve [--port 8080]
curl --data-binary @rechnung.pdf http://127.0.0.1:8080/check
(Schnittstelle: http://127.0.0.1:8080/docs bzw. /openapi.json)
```

## abdecker serve als Windows-Dienst

`abdecker.exe` ist ein normales Konsolenprogramm, `sc create` allein reicht daher nicht.
Als Dienst läuft es über einen Wrapper wie [NSSM](https://nssm.cc) (als Administrator):

```text
nssm install abdecker C:\abdecker\abdecker.exe serve --port 8080
nssm set abdecker AppStdout C:\abdecker\serve.log
nssm start abdecker
```

Ohne Zusatzprogramm geht es mit der Aufgabenplanung (Start beim Hochfahren, PowerShell
als Administrator):

```powershell
$a = New-ScheduledTaskAction -Execute 'C:\abdecker\abdecker.exe' -Argument 'serve --port 8080 --quiet'
$s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0
Register-ScheduledTask abdecker -Action $a -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $s -User SYSTEM
Start-ScheduledTask abdecker
```

Der Server hört standardmäßig nur auf 127.0.0.1 und hat weder Anmeldung noch TLS. Wer ihn
im Netz braucht (`--host 0.0.0.0`), stellt ihn hinter einen Reverse-Proxy.

## Lizenz

[MIT](LICENSE), für alles in diesem Repository: Lib, Tool, `serve`, Rechnungsformat,
Vorlagen, JSON-Schema und Doku.

Was abdecker erzeugt (XML, PDF, HTML, JSON), gehört dir, ohne Lizenzpflichten. Das gilt
auch, wo Teile von abdecker darin stecken, etwa das CSS der HTML-Ausgabe oder der
Hinweis auf abdecker im XML.

`check` ersetzt keine amtliche Prüfung (z. B. den KoSIT-Validator): keine XSD-Validierung,
keine vollständige Schematron-Abdeckung.

## Unterstützen

abdecker ist kostenlos und bleibt es. Wer damit Geld verdient oder Gebühren spart, kann
etwas zurückgeben: [GitHub Sponsors](https://github.com/sponsors/ijache) oder
[Ko-fi](https://ko-fi.com/ingojache).

## Mitmachen

Fehlerberichte und Pull Requests sind willkommen; ob ein Pull Request angenommen wird,
entscheide ich nach eigenem Ermessen, ohne Zusage. Beiträge stehen wie alles hier unter
MIT. Rechnungsdateien als Beispiel bitte nur anonymisiert (keine echten Namen, Anschriften
oder IBANs).
