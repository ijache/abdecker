@echo off
rem Example calls of abdecker, one per command, using the test corpus.
rem build.bat copies this file next to abdecker.exe into bin\; run it there.
rem The test data is fetched by tools\fetch-testdata.sh.
rem Output files go to bin\examples-out\ (overwritten on every run).
setlocal
cd /d "%~dp0"
if not exist examples-out mkdir examples-out
prompt $G$S
echo on

.\abdecker.exe version
.\abdecker.exe help

@rem --- info: ZUGFeRD/Factur-X PDF, then UBL XML as JSON
.\abdecker.exe info ..\testdata\external\corpus\corpus-master\XML-Rechnung\FX\EN16931_Einfach.pdf
.\abdecker.exe info ..\testdata\external\corpus\corpus-master\XML-Rechnung\UBL\EN16931_Gutschrift.ubl.xml --json

@rem --- extract: embedded XML from a PDF into a file
.\abdecker.exe extract ..\testdata\external\corpus\corpus-master\XML-Rechnung\FX\EN16931_Einfach.pdf -o examples-out\EN16931_Einfach.xml -f

@rem --- check: valid XRechnung (exit code 0), then an invoice with errors (exit code 1)
@rem     eicar.cii.xml only carries the harmless EICAR test string as attachment
.\abdecker.exe check ..\testdata\external\corpus\corpus-master\XML-Rechnung\CII\XRECHNUNG_Einfach.cii.xml
.\abdecker.exe check ..\testdata\external\corpus\corpus-master\other\eicar.cii.xml

@rem --- check --fail-on warning: a ZUGFeRD invoice whose line 4 does not add up;
@rem     the warning comes from an extra check (not an official EN 16931 rule), exit code 1
.\abdecker.exe check ..\testdata\external\corpus\corpus-master\XML-Rechnung\CII\EN16931_1_Teilrechnung.cii.xml --fail-on warning

@rem --- embed: CII invoice into a plain PDF
.\abdecker.exe embed ..\testdata\external\corpus\corpus-master\unstructured\RE-E-974-Hetzner_2016-01-19_R0005532486.pdf ..\testdata\external\corpus\corpus-master\XML-Rechnung\CII\EN16931_Einfach.cii.xml -o examples-out\hetzner-zugferd.pdf -f

@rem --- embed UBL: converted to CII first (Peppol BIS is embedded as EN 16931)
.\abdecker.exe embed ..\testdata\external\corpus\corpus-master\unstructured\RE-E-974-Hetzner_2016-01-19_R0005532486.pdf ..\testdata\external\corpus\corpus-master\XML-Rechnung\UBL\XRECHNUNG_Einfach.ubl.xml -o examples-out\hetzner-xrechnung-ubl.pdf -f

@rem --- strip: remove the invoice XML again
.\abdecker.exe strip examples-out\hetzner-zugferd.pdf -o examples-out\hetzner-stripped.pdf -f

@rem --- attach: add a PDF to the invoice XML as attachment
.\abdecker.exe attach ..\testdata\external\corpus\corpus-master\XML-Rechnung\CII\XRECHNUNG_Einfach.cii.xml ..\testdata\external\corpus\corpus-master\unstructured\RE-E-974-Hetzner_2016-01-19_R0005532486.pdf -o examples-out\XRECHNUNG_Einfach-attached.xml -f

@rem --- attachments: list the files that come with an invoice, then save them
.\abdecker.exe attachments ..\testdata\external\corpus\corpus-master\ZUGFeRDv2\correct\intarsys\EN16931\zugferd_2p0_EN16931_Betriebskostenabrechnung.pdf
.\abdecker.exe attachments ..\testdata\external\corpus\corpus-master\XML-Rechnung\CII\XRECHNUNG_Elektron.cii.xml -o examples-out\attachments -f
.\abdecker.exe attachments ..\testdata\external\corpus\corpus-master\XML-Rechnung\CII\XRECHNUNG_Elektron.cii.xml --index 1 -o examples-out\attachment-1.png -f

@rem --- html: invoice as HTML page (English); add --open to show it in the browser
.\abdecker.exe html ..\testdata\external\corpus\corpus-master\XML-Rechnung\FX\EN16931_Einfach.pdf -o examples-out\EN16931_Einfach.html --lang en -f

@rem --- json: the invoice as JSON for further processing (a reduced, flat view)
.\abdecker.exe json ..\testdata\external\corpus\corpus-master\XML-Rechnung\FX\EN16931_Einfach.pdf
.\abdecker.exe json ..\testdata\external\corpus\corpus-master\XML-Rechnung\UBL\EN16931_Gutschrift.ubl.xml -o examples-out\EN16931_Gutschrift.json -f

@rem --- create: invoice from the own JSON format (templates\), then into a PDF;
@rem     placeholders like {{today}} come from --var or --vars
.\abdecker.exe create ..\templates\xrechnung.json -o examples-out\xrechnung.xml -f
.\abdecker.exe create ..\templates\minimal.json --var today=2026-11-14 -o examples-out\minimal.xml -f
.\abdecker.exe embed ..\testdata\external\corpus\corpus-master\unstructured\RE-E-974-Hetzner_2016-01-19_R0005532486.pdf examples-out\minimal.xml -o examples-out\minimal-zugferd.pdf -f

@rem --- standard input: extract to stdout, piped into check
.\abdecker.exe extract ..\testdata\external\corpus\corpus-master\XML-Rechnung\FX\EN16931_Einfach.pdf | .\abdecker.exe check -

@rem --- serve: REST/JSON server (blocks until Ctrl+C, therefore not run here)
@rem     .\abdecker.exe serve --port 8080
@rem     curl --data-binary @..\testdata\external\corpus\corpus-master\XML-Rechnung\FX\EN16931_Einfach.pdf http://127.0.0.1:8080/check
@rem     curl -F pdf=@brief.pdf -F xml=@rechnung.xml -o rechnung.pdf http://127.0.0.1:8080/embed
@rem     curl --data-binary @..\testdata\external\corpus\corpus-master\XML-Rechnung\FX\EN16931_Einfach.pdf http://127.0.0.1:8080/json
@rem     curl --data-binary @..\templates\minimal.json "http://127.0.0.1:8080/create?today=2026-11-14"
@rem     interface description: http://127.0.0.1:8080/docs (Swagger UI), /openapi.json
