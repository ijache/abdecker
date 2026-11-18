"""Server reference test: starts "abdecker serve" on a free port and compares
the answers with tests/golden/serve.txt.

    python tests/serve.py            compare (exit code 1 on differences)
    python tests/serve.py --update   accept the current output as reference

Part 1, routes: real HTTP requests with files from the test corpus; status,
content type, the relevant headers and the body (summarized like tests/cli.py).
Part 2, the server itself (2 workers, queue 2, timeout 2 s): slow client
-> 408, queue full -> 503, expired in the queue -> 503, exception -> 500 and
the worker survives, missing Content-Length / chunked -> 411, too large -> 413,
"Expect: 100-continue", malformed request -> 400.

Needs the built tool (build.bat) and the test data (tools/fetch-testdata.sh).
"""
import http.client
import os
import socket
import subprocess
import sys
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cli import (ROOT, EXE, C, FX, CII, CII_EN, TEIL, UBL, PLAIN, EICAR, UNKNOWN, TEXT, ELEKTRON,  # noqa: E402
                 INTARSYS, TPL, CR, summary)

GOLDEN = os.path.join(ROOT, 'tests', 'golden', 'serve.txt')
ACTUAL = os.path.join(ROOT, 'tests', 'golden', 'serve.actual.txt')
SHOWN_HEADERS = ['Allow', 'Content-Disposition', 'Content-Security-Policy', 'Retry-After', 'X-Abdecker-Messages']
TIMEOUT = 2  # --timeout of the test server, seconds


def free_port():
    s = socket.socket()
    s.bind(('127.0.0.1', 0))
    port = s.getsockname()[1]
    s.close()
    return port


def read_file(rel):
    with open(os.path.join(ROOT, rel), 'rb') as h:
        return h.read()


def multipart(fields):
    """fields: list of (name, filename, bytes) -> (content type, body)"""
    b = uuid.uuid4().hex
    out = b''
    for name, filename, data in fields:
        out += b'--' + b.encode() + b'\r\n'
        out += ('Content-Disposition: form-data; name="%s"; filename="%s"\r\n' % (name, filename)).encode('utf-8')
        out += b'Content-Type: application/octet-stream\r\n\r\n' + data + b'\r\n'
    out += b'--' + b.encode() + b'--\r\n'
    return 'multipart/form-data; boundary=' + b, out


class Server:
    def __init__(self, *args):
        self.port = free_port()
        self.proc = subprocess.Popen([EXE, 'serve', '--port', str(self.port), '--quiet', '--test-routes'] + list(args),
                                     cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for _ in range(100):
            try:
                self.request('GET', '/version')
                return
            except OSError:
                time.sleep(0.05)
        self.stop()
        sys.exit('server did not start: ' + self.proc.stderr.read().decode())

    def request(self, method, path, body=None, content_type=None):
        conn = http.client.HTTPConnection('127.0.0.1', self.port, timeout=30)
        headers = {}
        if content_type:
            headers['Content-Type'] = content_type
        conn.request(method, path, body=body, headers=headers)
        r = conn.getresponse()
        data = r.read()
        conn.close()
        return r, data

    def raw(self, data, wait=5.0):
        """send raw bytes, return the first line of the answer ('' if none)"""
        s = socket.create_connection(('127.0.0.1', self.port))
        s.settimeout(wait)
        try:
            if data:
                s.sendall(data)
            return recv_status(s)
        finally:
            s.close()

    def stop(self):
        self.proc.kill()
        self.proc.wait()


def recv_status(s):
    buf = b''
    try:
        while b'\r\n' not in buf:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
    except socket.timeout:
        return '<no answer>'
    return buf.split(b'\r\n')[0].decode('ascii', 'replace')


def describe(name, r, data):
    res = ['== ' + name, 'status: %d %s' % (r.status, r.reason)]
    ct = r.getheader('Content-Type')
    if ct:
        res.append('content-type: ' + ct)
    for h in SHOWN_HEADERS:
        v = r.getheader(h)
        if v is not None:
            res.append('%s: %s' % (h.lower(), v))
    if data:
        res += ['body:'] + ['  ' + l for l in summary(data)]
    return res


def routes(srv):
    pdf, cii, cii_en, plain = read_file(FX), read_file(CII), read_file(CII_EN), read_file(PLAIN)
    cases = [
        ('GET /version', 'GET', '/version', None, None),
        ('POST /info PDF', 'POST', '/info', pdf, None),
        ('POST /info UBL', 'POST', '/info', read_file(UBL), None),
        ('POST /info no invoice', 'POST', '/info', plain, None),
        ('POST /info unknown XML', 'POST', '/info', read_file(UNKNOWN), None),
        ('POST /info neither PDF nor XML', 'POST', '/info', read_file(TEXT), None),
        ('POST /info empty body', 'POST', '/info', b'', None),
        ('POST /check valid', 'POST', '/check', cii, None),
        ('POST /check errors', 'POST', '/check', read_file(EICAR), None),
        ('POST /check?verbose=1', 'POST', '/check?verbose=1', read_file(EICAR), None),
        ('POST /check?verbose=x', 'POST', '/check?verbose=x', cii, None),
        ('POST /check extra-check warning', 'POST', '/check', read_file(TEIL), None),
        ('POST /check no invoice', 'POST', '/check', plain, None),
        ('POST /extract', 'POST', '/extract', pdf, None),
        ('POST /extract no invoice', 'POST', '/extract', plain, None),
        ('POST /extract XML', 'POST', '/extract', cii, None),
        ('POST /html', 'POST', '/html', pdf, None),
        ('POST /html?lang=en&check=0', 'POST', '/html?lang=en&check=0', read_file(TEIL), None),
        ('POST /html?lang=fr', 'POST', '/html?lang=fr', pdf, None),
        ('POST /html?check=2', 'POST', '/html?check=2', pdf, None),
        ('POST /html?payment=1', 'POST', '/html?payment=1', cii, None),
        ('POST /html?payment=2', 'POST', '/html?payment=2', cii, None),
        ('POST /html no invoice', 'POST', '/html', plain, None),
        ('POST /json', 'POST', '/json', pdf, None),
        ('POST /json UBL', 'POST', '/json', read_file(UBL), None),
        ('POST /json no invoice', 'POST', '/json', plain, None),
        ('POST /attachments PDF', 'POST', '/attachments', read_file(INTARSYS), None),
        ('POST /attachments?content=1', 'POST', '/attachments?content=1', read_file(ELEKTRON), None),
        ('POST /attachments?content=2', 'POST', '/attachments?content=2', pdf, None),
        ('POST /attachments unknown XML', 'POST', '/attachments', read_file(UNKNOWN), None),
        ('POST /strip', 'POST', '/strip', pdf, None),
        ('POST /strip no invoice', 'POST', '/strip', plain, None),
        ('POST /create', 'POST', '/create', read_file(TPL + '/xrechnung.json'), 'application/json'),
        ('POST /create?today=...&nr=...', 'POST',
         '/create?today=2026-11-14&nr=2026-1000&po=PO%201&hours=7.5', read_file(CR + '/placeholders.json'), None),
        ('POST /create format errors', 'POST', '/create', read_file(CR + '/format-errors.json'), None),
        ('POST /create check errors', 'POST', '/create', read_file(CR + '/check-errors.json'), None),
        ('POST /create attachment file', 'POST', '/create', read_file(CR + '/with-file.json'), None),
        ('POST /create not JSON', 'POST', '/create', plain, None),
    ]
    ct, body = multipart([('pdf', 'brief.pdf', plain), ('xml', 'rechnung.xml', cii_en)])
    cases.append(('POST /embed', 'POST', '/embed', body, ct))
    ct, body = multipart([('pdf', 'brief.pdf', pdf), ('xml', 'rechnung.xml', cii_en)])
    cases.append(('POST /embed into ZUGFeRD PDF', 'POST', '/embed', body, ct))
    ct, body = multipart([('pdf', 'brief.pdf', plain), ('xml', 'rechnung.xml', read_file(UBL))])
    cases.append(('POST /embed UBL', 'POST', '/embed', body, ct))
    ct, body = multipart([('pdf', 'brief.pdf', plain)])
    cases.append(('POST /embed without xml', 'POST', '/embed', body, ct))
    cases.append(('POST /embed not multipart', 'POST', '/embed', plain, None))
    ct, body = multipart([('xml', 'rechnung.xml', cii), ('file', 'brief.pdf', plain), ('file', 'kopie.pdf', plain)])
    cases.append(('POST /attach two files', 'POST', '/attach', body, ct))
    ct, body = multipart([('xml', 'rechnung.xml', cii), ('file', 'LICENSE', read_file(TEXT))])
    cases.append(('POST /attach unsupported type', 'POST', '/attach', body, ct))
    ct, body = multipart([('xml', 'rechnung.xml', cii)])
    cases.append(('POST /attach without file', 'POST', '/attach', body, ct))
    cases += [
        ('GET /docs', 'GET', '/docs', None, None),
        ('POST /openapi.json', 'POST', '/openapi.json', b'', None),
        ('GET /nope', 'GET', '/nope', None, None),
        ('GET /check', 'GET', '/check', None, None),
        ('POST /version', 'POST', '/version', b'', None),
        ('POST /test/raise', 'POST', '/test/raise', b'x', None),
    ]
    lines = []
    for name, method, path, body, ct in cases:
        r, data = srv.request(method, path, body, ct)
        lines += describe(name, r, data)
    lines += openapi(srv, cases)
    return lines


def openapi(srv, cases):
    """/openapi.json: valid JSON, the same as data/openapi.json, and its paths
    and methods are exactly the routes the server answers"""
    import json
    r, data = srv.request('GET', '/openapi.json')
    lines = ['== GET /openapi.json', 'status: %d %s' % (r.status, r.reason),
             'content-type: ' + str(r.getheader('Content-Type'))]
    spec = json.loads(data)
    source = json.loads(open(os.path.join(ROOT, 'data', 'openapi.json'), encoding='utf-8').read())
    version = srv.request('GET', '/version')[1]
    source['info']['version'] = json.loads(version)['version']
    lines.append('same as data/openapi.json: %s' % (spec == source))

    def refs(node):
        if isinstance(node, dict):
            for k, v in node.items():
                if k == '$ref':
                    yield v
                else:
                    yield from refs(v)
        elif isinstance(node, list):
            for v in node:
                yield from refs(v)

    def resolves(ref):
        node = spec
        for part in ref.lstrip('#/').split('/'):
            if not isinstance(node, dict) or part not in node:
                return False
            node = node[part]
        return True

    broken = sorted({r for r in refs(spec) if not resolves(r)})
    lines.append('all $ref resolve: %s%s' % (not broken, (' (' + ', '.join(broken) + ')') if broken else ''))
    documented = sorted((m.upper(), p) for p, ops in spec['paths'].items() for m in ops)
    lines.append('documented: ' + ', '.join('%s %s' % d for d in documented))
    tested = {(m, p.split('?')[0]) for _, m, p, _, _ in cases} | {('GET', '/openapi.json')}
    answered = set()
    for m, p in tested:
        if p.startswith('/test/') or p == '/nope':
            continue
        st = srv.request(m, p, b'' if m == 'POST' else None)[0].status
        if st not in (404, 405):
            answered.add((m, p))
    lines.append('documented = answered: %s' % (set(documented) == answered))
    missing = sorted(set(documented) - answered) + sorted(answered - set(documented))
    if missing:
        lines.append('difference: ' + ', '.join('%s %s' % d for d in missing))
    return lines


def behaviour(srv):
    lines = ['== server behaviour (2 workers, queue 2, timeout %d s)' % TIMEOUT]

    # slow client: header announces 10 bytes, sends 3, then nothing
    t = time.time()
    st = srv.raw(b'POST /check HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc', wait=TIMEOUT + 3)
    lines.append('slow client: %s (after deadline: %s)' % (st, time.time() - t >= TIMEOUT - 0.2))

    # queue full: 2 idle connections occupy the workers, 2 wait in the queue, the 5th is rejected
    idle = []
    for _ in range(4):
        s = socket.create_connection(('127.0.0.1', srv.port))
        s.settimeout(TIMEOUT + 3)
        idle.append(s)
        time.sleep(0.1)
    t = time.time()
    st = srv.raw(b'GET /version HTTP/1.1\r\n\r\n', wait=TIMEOUT + 3)
    lines.append('queue full: %s (at once: %s)' % (st, time.time() - t < 1))
    answers = sorted(recv_status(s) for s in idle)
    for s in idle:
        s.close()
    lines.append('idle connections: ' + ', '.join(answers))

    # expired in the queue: both workers busy longer than the deadline, a third request waits
    busy = []
    for _ in range(2):
        s = socket.create_connection(('127.0.0.1', srv.port))
        s.settimeout(TIMEOUT + 5)
        s.sendall(b'POST /test/sleep?ms=%d HTTP/1.1\r\nContent-Length: 0\r\n\r\n' % ((TIMEOUT + 1) * 1000))
        busy.append(s)
    time.sleep(0.2)
    st = srv.raw(b'GET /version HTTP/1.1\r\n\r\n', wait=TIMEOUT + 5)
    lines.append('expired in the queue: ' + st)
    lines.append('busy workers: ' + ', '.join(recv_status(s) for s in busy))
    for s in busy:
        s.close()

    # exceptions do not kill the workers
    codes = [srv.request('POST', '/test/raise', b'x')[0].status for _ in range(5)]
    lines.append('exception 5x: %s, then /version: %d' % (codes, srv.request('GET', '/version')[0].status))

    lines.append('no Content-Length: ' + srv.raw(b'POST /check HTTP/1.1\r\n\r\n'))
    lines.append('chunked: ' + srv.raw(b'POST /check HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n'))
    lines.append('too large: ' + srv.raw(b'POST /check HTTP/1.1\r\nContent-Length: 2000000\r\n\r\n'))
    lines.append('invalid Content-Length: ' + srv.raw(b'POST /check HTTP/1.1\r\nContent-Length: x\r\n\r\n'))
    lines.append('malformed request line: ' + srv.raw(b'HELLO\r\n\r\n'))
    lines.append('not HTTP/1.x: ' + srv.raw(b'GET /version HTTP/2.0\r\n\r\n'))
    lines.append('header too large: ' + srv.raw(b'GET /version HTTP/1.1\r\nX: ' + b'a' * 20000 + b'\r\n\r\n'))

    # Expect: 100-continue: first the interim answer, then the result
    body = read_file(CII)
    s = socket.create_connection(('127.0.0.1', srv.port))
    s.settimeout(5)
    s.sendall(b'POST /check HTTP/1.1\r\nContent-Length: %d\r\nExpect: 100-continue\r\n\r\n' % len(body))
    first = s.recv(4096).split(b'\r\n')[0].decode()
    s.sendall(body)
    second = recv_status(s)
    s.close()
    lines.append('expect 100-continue: %s, then %s' % (first, second))
    return lines


def main():
    update = '--update' in sys.argv[1:]
    if not os.path.isfile(EXE):
        sys.exit('missing %s - run build.bat first' % EXE)
    if not os.path.isdir(os.path.join(ROOT, C)):
        sys.exit('missing test data - run tools/fetch-testdata.sh first')
    srv = Server()
    try:
        lines = routes(srv)
    finally:
        srv.stop()
    srv = Server('--workers', '2', '--queue', '2', '--timeout', str(TIMEOUT), '--max-size', '1')
    try:
        lines += behaviour(srv)
    finally:
        srv.stop()
    text = '\n'.join(lines) + '\n'
    if update:
        with open(GOLDEN, 'w', encoding='utf-8', newline='\n') as h:
            h.write(text)
        print('reference updated: %s' % GOLDEN)
        return
    golden = open(GOLDEN, encoding='utf-8').read() if os.path.isfile(GOLDEN) else ''
    if text == golden:
        if os.path.isfile(ACTUAL):
            os.remove(ACTUAL)
        print('all match the reference')
        return
    with open(ACTUAL, 'w', encoding='utf-8', newline='\n') as h:
        h.write(text)
    import difflib
    print('\n'.join(list(difflib.unified_diff(golden.splitlines(), text.splitlines(), 'serve.txt',
                                              'serve.actual.txt', lineterm='', n=1))[:200]))
    print('DIFFERENCES to the reference (see %s; --update accepts)' % ACTUAL)
    sys.exit(1)


if __name__ == '__main__':
    main()
