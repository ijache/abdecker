#!/bin/sh
# Downloads third-party test data into testdata/external (not committed).
#   - ZUGFeRD/corpus           (Apache-2.0) https://github.com/ZUGFeRD/corpus
#   - KoSIT xrechnung-testsuite (Apache-2.0) https://github.com/itplr-kosit/xrechnung-testsuite
#   - JSONTestSuite (MIT), only test_parsing   https://github.com/nst/JSONTestSuite
# and the official rule sets into testdata/rules (reference for the checker,
# source of data/codelists.txt via tools/gen-data.py):
#   - CEN EN 16931 validation artefacts (EUPL 1.2) https://github.com/ConnectingEurope/eInvoicing-EN16931
#   - KoSIT XRechnung schematron (Apache-2.0)       https://github.com/itplr-kosit/xrechnung-schematron
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/testdata/external"
TMP="$DEST/.download"
mkdir -p "$TMP"

# Prefer the Windows curl (uses the system certificate store); the curl shipped
# with Git Bash often lacks the CA bundle.
CURL=curl
[ -x /c/Windows/System32/curl.exe ] && CURL=/c/Windows/System32/curl.exe

KOSIT_URL="https://github.com/itplr-kosit/xrechnung-testsuite/releases/download/v2026-08-31/xrechnung-3.0.2-testsuite-2026-08-31.zip"
CORPUS_URL="https://codeload.github.com/ZUGFeRD/corpus/zip/refs/heads/master"
JSON_URL="https://codeload.github.com/nst/JSONTestSuite/zip/refs/heads/master"
EN_URL="https://github.com/ConnectingEurope/eInvoicing-EN16931/releases/download/validation-1.3.17"
XR_URL="https://github.com/itplr-kosit/xrechnung-schematron/releases/download/v2.6.0/xrechnung-3.0.2-schematron-2.6.0.zip"
RULES="$ROOT/testdata/rules"

"$CURL" -fsSL -o "$TMP/kosit.zip" "$KOSIT_URL"
"$CURL" -fsSL -o "$TMP/corpus.zip" "$CORPUS_URL"
"$CURL" -fsSL -o "$TMP/json.zip" "$JSON_URL"

rm -rf "$DEST/kosit" "$DEST/corpus"
# python's zipfile is used because unzip is not always available on Windows
# (python before python3: on Windows python3 may be the Store stub)
PY=$(command -v python || command -v python3)
(cd "$TMP" && "$PY" -I -m zipfile -e kosit.zip "$DEST/kosit")
(cd "$TMP" && "$PY" -I -m zipfile -e corpus.zip "$DEST/corpus")
# JSONTestSuite: only the test files (the repository has parsers with XML files)
rm -rf "$DEST/jsontestsuite"
(cd "$TMP" && "$PY" -I -m zipfile -e json.zip json)
mv "$TMP/json/JSONTestSuite-master/test_parsing" "$DEST/jsontestsuite"

"$CURL" -fsSL -o "$TMP/en-cii.zip" "$EN_URL/en16931-cii-1.3.17.zip"
"$CURL" -fsSL -o "$TMP/en-ubl.zip" "$EN_URL/en16931-ubl-1.3.17.zip"
"$CURL" -fsSL -o "$TMP/xr.zip" "$XR_URL"
rm -rf "$RULES"
(cd "$TMP" && "$PY" -I -m zipfile -e en-cii.zip "$RULES/en16931-cii")
(cd "$TMP" && "$PY" -I -m zipfile -e en-ubl.zip "$RULES/en16931-ubl")
(cd "$TMP" && "$PY" -I -m zipfile -e xr.zip "$RULES/xrechnung")
rm -rf "$TMP"
echo "test data in $DEST, rule sets in $RULES"
