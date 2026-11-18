"""CLI reference test: runs bin/abdecker with fixed inputs from the test corpus
and compares stdout, stderr, exit code and written files with
tests/golden/cli.txt.

    python tests/cli.py            compare (exit code 1 on differences)
    python tests/cli.py --update   accept the current output as reference

Needs the built tool (build.bat) and the test data (tools/fetch-testdata.sh).
Output files go to a temporary folder, shown as $OUT.

Normalized so the reference is stable:
- operating system error texts (locale dependent) -> <os message>
- PDF output (contains the current time) -> size and version only
- long or binary output (more than 40 lines or a line over 300 characters,
  e.g. HTML) -> size and SHA-256
Not covered: the console guard for PDF (stdout is always a pipe here), --open.
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# ABDECKER_EXE: another build to test (e.g. the FPC one); the default is bin/abdecker(.exe)
EXE = os.environ.get('ABDECKER_EXE') or os.path.join(ROOT, 'bin', 'abdecker.exe' if os.name == 'nt' else 'abdecker')
GOLDEN = os.path.join(ROOT, 'tests', 'golden', 'cli.txt')
ACTUAL = os.path.join(ROOT, 'tests', 'golden', 'cli.actual.txt')
OUT = '$OUT'  # replaced by a temporary folder at run time
MAX_LINES = 40
MAX_WIDTH = 300

C = 'testdata/external/corpus/corpus-master'
FX = C + '/XML-Rechnung/FX/EN16931_Einfach.pdf'               # Factur-X PDF
CII = C + '/XML-Rechnung/CII/XRECHNUNG_Einfach.cii.xml'       # valid XRechnung
CII_EN = C + '/XML-Rechnung/CII/EN16931_Einfach.cii.xml'      # CII for embed
TEIL = C + '/XML-Rechnung/CII/EN16931_1_Teilrechnung.cii.xml'  # extra-check warning
UBL = C + '/XML-Rechnung/UBL/EN16931_Gutschrift.ubl.xml'          # Peppol BIS
UBL_XR = C + '/XML-Rechnung/UBL/XRECHNUNG_Einfach.ubl.xml'          # XRechnung UBL
UBL_LOST = 'testdata/external/kosit/instances/extension/05.01a-INVOICE_ubl.xml'  # content outside EN 16931
PLAIN = C + '/unstructured/RE-E-974-Hetzner_2016-01-19_R0005532486.pdf'  # no invoice
EICAR = C + '/other/eicar.cii.xml'                            # check errors
UNKNOWN = C + '/fatturaPA/eigor/valid/A10-Licenses.xml'       # unknown XML format
BROKEN = C + '/fatturaPA/eigor/valid/con-ritenuta-acconto-e-cassa-previdenziale.xml'
TEXT = C + '/LICENSE'                                          # neither PDF nor XML
MISSING = 'tests/does-not-exist.pdf'
ELEKTRON = C + '/XML-Rechnung/CII/XRECHNUNG_Elektron.cii.xml'   # BG-24: PNG and PDF
INTARSYS = C + '/ZUGFeRDv2/correct/intarsys/EN16931/zugferd_2p0_EN16931_Betriebskostenabrechnung.pdf'
TPL = 'templates'                                              # invoices in the own JSON format
CR = 'tests/create'                                            # inputs for create

# (name, arguments, standard input file or None, files to create before the run)
CASES = [
    # general
    ('no arguments', [], None, []),
    ('help', ['help'], None, []),
    ('--help', ['--help'], None, []),
    ('help create', ['help', 'create'], None, []),
    ('help serve', ['help', 'serve'], None, []),
    ('create -h', ['create', '-h'], None, []),
    ('help unknown command', ['help', 'frobnicate'], None, []),
    ('help two commands', ['help', 'info', 'check'], None, []),
    ('unknown command -h', ['frobnicate', '-h'], None, []),
    ('version', ['version'], None, []),
    ('unknown command', ['frobnicate'], None, []),
    ('unknown option', ['info', FX, '--frob'], None, []),
    ('-o without file', ['extract', FX, '-o'], None, []),
    ('--lang without value', ['html', FX, '--lang'], None, []),
    ('--lang invalid', ['html', FX, '--lang', 'fr'], None, []),
    ('--fail-on without value', ['check', CII, '--fail-on'], None, []),
    ('--fail-on invalid', ['check', CII, '--fail-on', 'info'], None, []),

    # info
    ('info PDF', ['info', FX], None, []),
    ('info UBL --json', ['info', UBL, '--json'], None, []),
    ('info PDF --json', ['info', FX, '--json'], None, []),
    ('info stdin', ['info', '-'], CII, []),
    ('info no invoice', ['info', PLAIN], None, []),
    ('info no invoice --json', ['info', PLAIN, '--json'], None, []),
    ('info unknown XML', ['info', UNKNOWN], None, []),
    ('info broken XML', ['info', BROKEN], None, []),
    ('info neither PDF nor XML', ['info', TEXT], None, []),
    ('info missing file', ['info', MISSING], None, []),
    ('info without input', ['info'], None, []),
    ('info two inputs', ['info', FX, CII], None, []),

    # extract
    ('extract to stdout', ['extract', FX], None, []),
    ('extract -o', ['extract', FX, '-o', OUT + '/extract.xml'], None, []),
    ('extract -o existing', ['extract', FX, '-o', OUT + '/exists.xml'], None, ['exists.xml']),
    ('extract -o existing -f', ['extract', FX, '-o', OUT + '/exists.xml', '-f'], None, ['exists.xml']),
    ('extract -o -', ['extract', FX, '-o', '-'], None, []),
    ('extract stdin', ['extract', '-'], FX, []),
    ('extract no invoice', ['extract', PLAIN], None, []),
    ('extract from XML', ['extract', CII], None, []),
    ('extract missing file', ['extract', MISSING], None, []),

    # check
    ('check valid XRechnung', ['check', CII], None, []),
    ('check PDF', ['check', FX], None, []),
    ('check errors', ['check', EICAR], None, []),
    ('check errors --json', ['check', EICAR, '--json'], None, []),
    ('check -v', ['check', CII, '-v'], None, []),
    ('check errors --verbose', ['check', EICAR, '--verbose'], None, []),
    ('check errors --json -v', ['check', EICAR, '--json', '-v'], None, []),
    ('check EN 16931 -v (R120 as extra check)', ['check', TEIL, '-v'], None, []),
    ('help check', ['help', 'check'], None, []),
    ('check extra-check warning', ['check', TEIL], None, []),
    ('check warning --fail-on warning', ['check', TEIL, '--fail-on', 'warning'], None, []),
    ('check warning --fail-on warning --json', ['check', TEIL, '--fail-on', 'warning', '--json'], None, []),
    ('check warning --fail-on error', ['check', TEIL, '--fail-on', 'error'], None, []),
    ('check valid --fail-on warning', ['check', CII, '--fail-on', 'warning'], None, []),
    ('check stdin', ['check', '-'], CII, []),
    ('check no invoice', ['check', PLAIN], None, []),
    ('check no invoice --json', ['check', PLAIN, '--json'], None, []),
    ('check missing file', ['check', MISSING], None, []),

    # embed
    ('embed to stdout', ['embed', PLAIN, CII_EN], None, []),
    ('embed -o', ['embed', PLAIN, CII_EN, '-o', OUT + '/embed.pdf'], None, []),
    ('embed -o existing', ['embed', PLAIN, CII_EN, '-o', OUT + '/exists.pdf'], None, ['exists.pdf']),
    ('embed XML from stdin', ['embed', PLAIN, '-', '-o', OUT + '/embed-stdin.pdf'], CII_EN, []),
    ('embed both stdin', ['embed', '-', '-'], CII_EN, []),
    ('embed UBL (Peppol)', ['embed', PLAIN, UBL, '-o', OUT + '/embed-ubl.pdf'], None, []),
    ('embed UBL (XRechnung)', ['embed', PLAIN, UBL_XR, '-o', OUT + '/embed-ubl-xr.pdf'], None, []),
    ('embed UBL with content outside EN 16931', ['embed', PLAIN, UBL_LOST, '-o', OUT + '/embed-ubl-lost.pdf'], None, []),
    ('embed into ZUGFeRD PDF', ['embed', FX, CII_EN, '-o', OUT + '/embed-twice.pdf'], None, []),
    ('embed one input', ['embed', PLAIN], None, []),

    # strip
    ('strip to stdout', ['strip', FX], None, []),
    ('strip -o', ['strip', FX, '-o', OUT + '/strip.pdf'], None, []),
    ('strip no invoice', ['strip', PLAIN, '-o', OUT + '/strip-plain.pdf'], None, []),
    ('strip stdin', ['strip', '-', '-o', OUT + '/strip-stdin.pdf'], FX, []),
    ('strip XML', ['strip', CII], None, []),

    # attach
    ('attach to stdout', ['attach', CII, PLAIN], None, []),
    ('attach -o', ['attach', CII, PLAIN, '-o', OUT + '/attach.xml'], None, []),
    ('attach invoice from stdin', ['attach', '-', PLAIN, '-o', OUT + '/attach-stdin.xml'], CII, []),
    ('attach file from stdin', ['attach', CII, '-'], PLAIN, []),
    ('attach unsupported type', ['attach', CII, TEXT], None, []),
    ('attach to PDF', ['attach', FX, PLAIN], None, []),
    ('attach without file', ['attach', CII], None, []),

    # attachments
    ('attachments PDF', ['attachments', INTARSYS], None, []),
    ('attachments XML with BG-24', ['attachments', ELEKTRON], None, []),
    ('attachments --json', ['attachments', INTARSYS, '--json'], None, []),
    ('attachments PDF without invoice', ['attachments', PLAIN], None, []),
    ('attachments unknown XML', ['attachments', UNKNOWN], None, []),
    ('attachments -o', ['attachments', INTARSYS, '-o', OUT], None, []),
    ('attachments -o existing', ['attachments', ELEKTRON, '-o', OUT], None, ['Aufmass.png']),
    ('attachments -o existing -f', ['attachments', ELEKTRON, '-o', OUT, '-f'], None, ['Aufmass.png']),
    ('attachments -o -', ['attachments', ELEKTRON, '-o', '-'], None, []),
    ('attachments stdin', ['attachments', '-'], ELEKTRON, []),
    ('attachments without input', ['attachments'], None, []),
    ('attachments --index -o file', ['attachments', ELEKTRON, '--index', '2', '-o', OUT + '/two.pdf'], None, []),
    ('attachments --index PDF', ['attachments', INTARSYS, '--index', '1', '-o', OUT + '/one.bin'], None, []),
    ('attachments --index no content', ['attachments', INTARSYS, '--index', '3', '-o', OUT + '/three.pdf'], None, []),
    ('attachments --index to stdout', ['attachments', ELEKTRON, '--index', '1'], None, []),
    ('attachments --index -o -', ['attachments', ELEKTRON, '--index', '1', '-o', '-'], None, []),
    ('attachments --index -o existing', ['attachments', ELEKTRON, '--index', '1', '-o', OUT + '/a.png'],
     None, ['a.png']),
    ('attachments --index -o existing -f', ['attachments', ELEKTRON, '--index', '1', '-o', OUT + '/a.png', '-f'],
     None, ['a.png']),
    ('attachments --index too high', ['attachments', ELEKTRON, '--index', '9'], None, []),
    ('attachments --index 0', ['attachments', ELEKTRON, '--index', '0'], None, []),
    ('attachments --index --json', ['attachments', ELEKTRON, '--index', '1', '--json'], None, []),
    ('attachments --index no invoice', ['attachments', UNKNOWN, '--index', '1'], None, []),

    # html
    ('html to stdout', ['html', FX], None, []),
    ('html -o', ['html', FX, '-o', OUT + '/page.html'], None, []),
    ('html --lang en --no-check', ['html', TEIL, '--lang', 'en', '--no-check', '-o', OUT + '/page-en.html'], None, []),
    ('html with check findings', ['html', TEIL, '-o', OUT + '/page-teil.html'], None, []),
    ('html stdin', ['html', '-'], CII, []),
    ('html --payment', ['html', CII, '--payment', '-o', OUT + '/pay.html'], None, []),
    ('html --payment --lang en --no-check', ['html', CII, '--payment', '--lang', 'en', '--no-check'], None, []),
    ('html no invoice', ['html', PLAIN], None, []),

    # json
    ('json to stdout', ['json', CII], None, []),
    ('json with attachments', ['json', ELEKTRON], None, []),
    ('json -o', ['json', FX, '-o', OUT + '/invoice.json'], None, []),
    ('json -o existing', ['json', FX, '-o', OUT + '/exists.json'], None, ['exists.json']),
    ('json stdin', ['json', '-'], UBL, []),
    ('json no invoice', ['json', PLAIN], None, []),
    ('json without input', ['json'], None, []),

    # create
    ('create to stdout', ['create', TPL + '/xrechnung.json'], None, []),
    ('create -o', ['create', TPL + '/cash-discount.json', '-o', OUT + '/create.xml'], None, []),
    ('create -o existing', ['create', TPL + '/cash-discount.json', '-o', OUT + '/exists.xml'], None, ['exists.xml']),
    ('create --var today', ['create', TPL + '/minimal.json', '--var', 'today=2026-11-14', '-o', OUT + '/minimal.xml'],
     None, []),
    ('create stdin', ['create', '-', '-o', OUT + '/create-stdin.xml'], TPL + '/reverse-charge.json', []),
    ('create --vars and --var', ['create', CR + '/placeholders.json', '--vars', CR + '/vars.json',
                                 '--var', 'nr=2026-1000', '--var', 'today=2026-11-14', '-o', OUT + '/vars.xml'], None, []),
    ('create missing variable', ['create', CR + '/placeholders.json', '--var', 'today=2026-11-14'], None, []),
    ('create --var without =', ['create', TPL + '/minimal.json', '--var', 'today'], None, []),
    ('create --vars not JSON', ['create', TPL + '/minimal.json', '--vars', TEXT], None, []),
    ('create format errors', ['create', CR + '/format-errors.json', '-o', OUT + '/format.xml'], None, []),
    ('create check errors', ['create', CR + '/check-errors.json', '-o', OUT + '/check.xml'], None, []),
    ('create attachment file', ['create', CR + '/with-file.json', '-o', OUT + '/with-file.xml'], None, []),
    ('create without input', ['create'], None, []),

    # serve: only the argument errors (the server itself: tests/serve.py)
    ('serve with input', ['serve', FX], None, []),
    ('serve --port 0', ['serve', '--port', '0'], None, []),
    ('serve --port not a number', ['serve', '--port', 'x'], None, []),
    ('serve --workers without value', ['serve', '--workers'], None, []),
    ('serve --host invalid', ['serve', '--host', 'example.org', '--port', '1'], None, []),
]


def summary(data):
    """Text as is if short; otherwise size and hash (PDF: size and version)."""
    if data.startswith(b'%PDF-'):
        return ['<PDF %d bytes, %s>' % (len(data), data[:8].decode('ascii', 'replace'))]
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        text = None
    if text is None or '\0' in text:
        return ['<binary %d bytes, sha256 %s>' % (len(data), hashlib.sha256(data).hexdigest()[:16])]
    lines = text.replace('\r\n', '\n').split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    if len(lines) > MAX_LINES or any(len(l) > MAX_WIDTH for l in lines):
        data = data.replace(b'\r\n', b'\n')  # the same on every platform
        return ['<text %d lines, %d bytes, sha256 %s>' % (len(lines), len(data), hashlib.sha256(data).hexdigest()[:16])]
    return lines


def normalize(lines, out_dir):
    json_dir = out_dir.replace('\\', '\\\\')  # as it appears inside JSON strings
    res = []
    for l in lines:
        l = l.replace(json_dir, OUT).replace(out_dir, OUT)
        l = l.replace(OUT + '\\\\', OUT + '/').replace(OUT + '\\', OUT + '/')  # separator as on Unix
        res.append(re.sub(r'(cannot be (read|written): ).*', r'\1<os message>', l))
    return res


def run_case(out_dir, name, args, stdin_file, create):
    for f in os.listdir(out_dir):
        os.remove(os.path.join(out_dir, f))
    args = [a.replace(OUT, out_dir) for a in args]
    for f in create:
        with open(os.path.join(out_dir, f), 'w') as h:
            h.write('existing\n')
    before = {f: os.path.getmtime(os.path.join(out_dir, f)) for f in os.listdir(out_dir)}
    stdin = open(os.path.join(ROOT, stdin_file), 'rb') if stdin_file else subprocess.DEVNULL
    try:
        p = subprocess.run([EXE] + args, cwd=ROOT, stdin=stdin, capture_output=True, timeout=60)
    finally:
        if stdin_file:
            stdin.close()
    cmd = '$ abdecker ' + ' '.join(args) + (' < ' + stdin_file if stdin_file else '')
    res = ['== ' + name] + normalize([cmd], out_dir) + ['exit: %d' % p.returncode]
    if p.stdout:
        res += ['stdout:'] + ['  ' + l for l in normalize(summary(p.stdout), out_dir)]
    if p.stderr:
        res += ['stderr:'] + ['  ' + l for l in normalize(summary(p.stderr), out_dir)]
    for f in sorted(os.listdir(out_dir)):
        path = os.path.join(out_dir, f)
        if f in before and os.path.getmtime(path) == before[f]:
            continue
        with open(path, 'rb') as h:
            res += ['file %s/%s:' % (OUT, f)] + ['  ' + l for l in summary(h.read())]
    return res


def main():
    update = '--update' in sys.argv[1:]
    if not os.path.isfile(EXE):
        sys.exit('missing %s - run build.bat first' % EXE)
    if not os.path.isdir(os.path.join(ROOT, C)):
        sys.exit('missing test data - run tools/fetch-testdata.sh first')
    lines = []
    out_dir = tempfile.mkdtemp(prefix='abdecker-cli-')
    try:
        for case in CASES:
            lines += run_case(out_dir, *case)
    finally:
        shutil.rmtree(out_dir, ignore_errors=True)
    text = '\n'.join(lines) + '\n'
    if update:
        with open(GOLDEN, 'w', encoding='utf-8', newline='\n') as h:
            h.write(text)
        print('%d cases, reference updated: %s' % (len(CASES), GOLDEN))
        return
    golden = open(GOLDEN, encoding='utf-8').read() if os.path.isfile(GOLDEN) else ''
    if text == golden:
        if os.path.isfile(ACTUAL):
            os.remove(ACTUAL)
        print('%d cases, all match the reference' % len(CASES))
        return
    with open(ACTUAL, 'w', encoding='utf-8', newline='\n') as h:
        h.write(text)
    import difflib
    diff = list(difflib.unified_diff(golden.splitlines(), text.splitlines(), 'cli.txt', 'cli.actual.txt',
                                     lineterm='', n=1))
    print('\n'.join(diff[:200]))
    print('%d cases, DIFFERENCES to the reference (see %s; --update accepts)' % (len(CASES), ACTUAL))
    sys.exit(1)


if __name__ == '__main__':
    main()
