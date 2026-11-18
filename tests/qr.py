"""QR test: the QR encoder of abdecker (source/abdecker.qr.pas) against the
Python library segno (pip install segno).

    python tests/qr.py         exit code 1 on differences

A QR code is fixed by data, version, error correction level and mask. For
every text, segno builds the code with the same settings (byte mode, level M,
UTF-8, no ECI, no level boost) and the mask abdecker chose; both matrices must
be equal module by module. Also compared: the mask segno chooses itself (the
penalty rules) and the version.

Texts: synthetic ones of every length class (versions 1 to 40, with umlauts),
and the GiroCode texts of the corpus (tests/golden/girocode.txt, written by
the test runner). The matrices come from bin/abdeckertests --qr.
"""
import os
import random
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNNER = os.path.join(ROOT, 'bin', 'abdeckertests.exe' if os.name == 'nt' else 'abdeckertests')
GIROCODES = os.path.join(ROOT, 'tests', 'golden', 'girocode.txt')


def synthetic():
    rnd = random.Random(16931)
    alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,-/äöüßÄÖÜ€\n'
    texts = ['', 'A', 'abdecker', 'Größe: 1 €']
    n = 1
    while n < 2400:   # byte capacity of version 40-M is 2331
        texts.append(''.join(rnd.choice(alphabet) for _ in range(n)))
        n = n + 1 + n // 6
    # all eight masks on a few texts
    return [(t, None) for t in texts] + [(texts[k], m) for k in (5, 20, 40) for m in range(8)]


def girocodes():
    """The payloads in girocode.txt: lines 'code: <text>' with \\n for line breaks."""
    if not os.path.exists(GIROCODES):
        return []
    result = []
    for line in open(GIROCODES, encoding='utf-8'):
        if line.startswith('code: '):
            result.append((line[6:].rstrip('\n').replace('\\n', '\n'), None))
    return result


def run_encoder(cases):
    with tempfile.TemporaryDirectory() as tmp:
        fin = os.path.join(tmp, 'in.txt')
        fout = os.path.join(tmp, 'out.txt')
        with open(fin, 'w', encoding='utf-8', newline='\n') as f:
            for text, mask in cases:
                f.write(text.encode('utf-8').hex() + ('' if mask is None else f' {mask}') + '\n')
        subprocess.run([RUNNER, '--qr', fin, fout], check=True)
        blocks = open(fout, encoding='utf-8').read().split('\n\n')
    return [b.split('\n') for b in blocks[:len(cases)]]


def patch_segno():
    """segno (1.6) adds eight zero bits after the terminator even when the bit
    stream already ends at a codeword boundary, i.e. always in byte mode; ISO/IEC
    18004, 7.4.10, adds padding bits only if it does not. Both codes read the
    same, but the modules differ: segno is patched to the standard here."""
    from segno import consts, encoder

    def write_padding_bits(buff, version, length):
        if version not in (consts.VERSION_M1, consts.VERSION_M3) and length % 8:
            buff.extend([0] * (8 - length % 8))

    encoder.write_padding_bits = write_padding_bits


def main():
    import segno

    patch_segno()

    cases = synthetic()
    corpus = girocodes()
    cases += corpus
    results = run_encoder(cases)
    failed = 0
    same_mask = 0
    auto = 0
    for (text, mask), lines in zip(cases, results):
        data = text.encode('utf-8')
        label = repr(text[:40]) + f' ({len(data)} bytes)'
        try:
            ref = segno.make(data, error='m', mode='byte', boost_error=False, micro=False)
        except segno.DataOverflowError:
            ref = None
        if lines[0] == 'too long':
            if ref is not None:
                failed += 1
                print(f'{label}: abdecker says too long, segno: version {ref.version}')
            continue
        if ref is None:
            failed += 1
            print(f'{label}: segno says too long, abdecker: {lines[0]}')
            continue
        version, our_mask = map(int, lines[0].split())
        if version != ref.version:
            failed += 1
            print(f'{label}: version {version}, segno {ref.version}')
            continue
        if mask is None:
            auto += 1
            if our_mask == ref.mask:
                same_mask += 1
            else:
                failed += 1
                print(f'{label}: mask {our_mask}, segno chooses {ref.mask}')
        elif our_mask != mask:
            failed += 1
            print(f'{label}: mask {our_mask}, {mask} was given')
        fixed = segno.make(data, error='m', mode='byte', boost_error=False, micro=False,
                           version=version, mask=our_mask)
        rows = [''.join('1' if m else '0' for m in row) for row in fixed.matrix]
        if rows != lines[1:]:
            failed += 1
            diff = sum(a != b for r1, r2 in zip(rows, lines[1:]) for a, b in zip(r1, r2))
            print(f'{label}: matrix differs from segno (version {version}, mask {our_mask}, {diff} modules)')

    print(f'{len(cases)} codes ({len(corpus)} GiroCodes of the corpus), '
          f'mask as segno: {same_mask} of {auto}')
    print('DIFFERENCES' if failed else 'QR OK')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
