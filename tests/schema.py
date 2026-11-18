"""Schema test: keeps docs/invoice-json/invoice.schema.json in step with the
format reader (source/abdecker.format.pas) and the templates.

    python tests/schema.py         exit code 1 on differences

Checks without extra packages:
- the schema is valid JSON, and every object of the format allows exactly the
  field names of its list in abdecker.format.pas (RootFields, SellerFields ...)
- every field name used in templates/*.json is known to the schema
If the package jsonschema is installed, the templates are also validated
against the schema; otherwise that part is skipped (with a note).
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEMA = os.path.join(ROOT, 'docs', 'invoice-json', 'invoice.schema.json')
FORMAT = os.path.join(ROOT, 'source', 'abdecker.format.pas')


def field_list(src, name):
    m = re.search(name + r": array\[[^\]]*\] of string = \((.*?)\);", src, re.S)
    if not m:
        raise SystemExit(f'{name} not found in abdecker.format.pas')
    return set(re.findall(r"'([^']*)'", m.group(1)))


def objects(schema):
    """The field lists of abdecker.format.pas and the schema objects they belong to."""
    p = schema['properties']
    d = schema['definitions']
    return {
        'RootFields': p,
        'PeriodFields': p['period']['properties'],
        'PrecedingFields': p['precedingInvoice']['properties'],
        'DiscountFields': p['cashDiscount']['properties'],
        'TotalsFields': p['totals']['properties'],
        'SellerFields': d['seller']['properties'],
        'BuyerFields': d['buyer']['properties'],
        'ContactFields': d['contact']['properties'],
        'AddressFields': d['electronicAddress']['anyOf'][1]['properties'],
        'LineFields': d['line']['properties'],
        'AttachmentFields': d['attachment']['properties'],
    }


def template_fields(value, path, out):
    """Paths of all field names, arrays as [] (e.g. lines[].name)."""
    if isinstance(value, dict):
        for k, v in value.items():
            p = f'{path}.{k}' if path else k
            out.add(p)
            template_fields(v, p, out)
    elif isinstance(value, list):
        for v in value:
            template_fields(v, path + '[]', out)


def schema_fields(schema):
    p = schema['properties']
    d = schema['definitions']
    known = set(p)
    nested = {
        'period': p['period'], 'precedingInvoice': p['precedingInvoice'],
        'cashDiscount': p['cashDiscount'], 'totals': p['totals'],
        'seller': d['seller'], 'buyer': d['buyer'], 'lines[]': d['line'],
        'attachments[]': d['attachment'], 'seller.contact': d['contact'],
    }
    for prefix, obj in nested.items():
        known |= {f'{prefix}.{k}' for k in obj['properties']}
    for party in ('seller', 'buyer'):
        known |= {f'{party}.electronicAddress.{k}' for k in d['electronicAddress']['anyOf'][1]['properties']}
    return known


def main():
    failed = False
    schema = json.load(open(SCHEMA, encoding='utf-8'))
    src = open(FORMAT, encoding='utf-8-sig').read()

    for name, obj in objects(schema).items():
        code, doc = field_list(src, name), set(obj)
        if code != doc:
            failed = True
            print(f'{name}: only in the code {sorted(code - doc)}, only in the schema {sorted(doc - code)}')

    known = schema_fields(schema)
    templates = sorted(glob.glob(os.path.join(ROOT, 'templates', '*.json')))

    for fn in templates:
        used = set()
        template_fields(json.load(open(fn, encoding='utf-8')), '', used)
        unknown = sorted(used - known)
        if unknown:
            failed = True
            print(f'{os.path.basename(fn)}: fields unknown to the schema: {unknown}')

    try:
        from jsonschema import Draft7Validator
    except ImportError:
        print('note: package jsonschema missing, templates not validated against the schema')
    else:
        Draft7Validator.check_schema(schema)
        validator = Draft7Validator(schema)
        for fn in templates:
            for e in validator.iter_errors(json.load(open(fn, encoding='utf-8'))):
                failed = True
                print(f'{os.path.basename(fn)}: {"/".join(map(str, e.path)) or "(root)"}: {e.message}')

    print('DIFFERENCES' if failed else f'schema OK ({len(templates)} templates)')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
