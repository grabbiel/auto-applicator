#!/usr/bin/env python3
"""Builds Resources/Companies.tsv: large employers and the other names each goes by, for the list of companies to leave
alone (Sources/Engine/Model/Companies.swift). From Wikidata, whose data is free to reuse (CC0).

    python3 -I scripts/make_companies.py [work folder]

Takes the organizations Wikidata gives 1,000 or more staff, those with a LinkedIn page, and what the first own; their
English names and other names; and the organization each belongs to ("parent organization", not "owned by", which also
lists shareholders). Downloads are kept in the work folder (default: build/companies) and reused on the next run; delete
it to download again. About ten minutes the first time.

Each line of the file: name, other names (split by |), staff (or empty), the owner's line number from 0 (or empty),
split by tabs, biggest employer first.
"""
import csv, io, json, os, re, sys, time, unicodedata, urllib.parse, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'build', 'companies')
OUT = os.path.join(ROOT, 'Resources', 'Companies.tsv')
AGENT = 'AutoApplicator-directory-build/1.0'
os.makedirs(WORK, exist_ok=True)


def sparql(q, accept='application/sparql-results+json'):
    for attempt in range(5):
        try:
            req = urllib.request.Request('https://query.wikidata.org/sparql', data=urllib.parse.urlencode({'query': q}).encode(),
                                         headers={'Accept': accept, 'User-Agent': AGENT})
            body = urllib.request.urlopen(req, timeout=120).read()
            return body.decode() if accept == 'text/csv' else json.loads(body)['results']['bindings']
        except Exception as e:  # the service turns busy clients away now and then
            print('  retrying:', e, file=sys.stderr)
            time.sleep(5 * (attempt + 1))
    raise SystemExit('Wikidata kept failing; try again later.')


def cached(name, make):
    path = os.path.join(WORK, name)
    if not os.path.exists(path):
        data = make()
        with open(path, 'w') as f:
            f.write(data if isinstance(data, str) else json.dumps(data))
    with open(path) as f:
        return f.read() if name.endswith('.csv') else json.load(f)


qid = lambda b, k: b[k]['value'].rsplit('/', 1)[1] if k in b else None
val = lambda b, k: (b[k]['value'].rsplit('/', 1)[-1] if b[k]['type'] == 'uri' else b[k]['value']) if k in b else None


def batched(ids, size, make_query, handle, label):
    for i in range(0, len(ids), size):
        for b in sparql(make_query(' '.join('wd:' + x for x in ids[i:i + size]))):
            handle(b)
        print(f'  {label}: {min(i + size, len(ids))}/{len(ids)}', file=sys.stderr)
        time.sleep(1.2)


print('Employers with 1,000+ staff…', file=sys.stderr)
big = {r['c'].rsplit('/', 1)[1]: float(r['emp']) for r in csv.DictReader(io.StringIO(cached('ids.csv', lambda: sparql(
    'SELECT ?c (MAX(?e) AS ?emp) WHERE { ?c wdt:P1128 ?e . FILTER(?e >= 1000) } GROUP BY ?c', 'text/csv'))))}
print('Organizations with a LinkedIn page…', file=sys.stderr)
slugs = {}
for r in csv.DictReader(io.StringIO(cached('li.csv', lambda: sparql('SELECT ?c ?li WHERE { ?c wdt:P4264 ?li }', 'text/csv')))):
    slugs.setdefault(r['c'].rsplit('/', 1)[1], set()).add(r['li'])


def details():
    ents = {}
    def entity(c):
        return ents.setdefault(c, {'id': c, 'emp': big.get(c), 'label': None, 'aliases': []})
    def add(b, key='c'):
        e = entity(qid(b, key))
        if val(b, 'label'): e['label'] = val(b, 'label')
        if val(b, 'alias') and val(b, 'alias') not in e['aliases']: e['aliases'].append(val(b, 'alias'))
        if val(b, 'emp'):
            try: e['emp'] = max(e['emp'] or 0, float(val(b, 'emp')))
            except ValueError: pass
    ids = sorted(set(big) | set(slugs))
    batched(ids, 400, lambda v: f'''SELECT ?c ?label ?alias ?emp WHERE {{ VALUES ?c {{ {v} }}
        OPTIONAL {{ ?c rdfs:label ?label . FILTER(LANG(?label) = "en") }}
        OPTIONAL {{ ?c skos:altLabel ?alias . FILTER(LANG(?alias) = "en") }}
        OPTIONAL {{ ?c wdt:P1128 ?emp }} }}''', add, 'names')
    # What the big employers own, often without a staff count of their own.
    batched(sorted(big), 300, lambda v: f'''SELECT ?child ?label ?alias WHERE {{ VALUES ?c {{ {v} }}
        ?child wdt:P749 ?c . ?child rdfs:label ?label . FILTER(LANG(?label) = "en")
        OPTIONAL {{ ?child skos:altLabel ?alias . FILTER(LANG(?alias) = "en") }} }}''', lambda b: add(b, 'child'), 'owned')
    return list(ents.values())


print('Names…', file=sys.stderr)
ents = cached('details.json', details)


def parent_links():
    out = {}
    def add(b): out.setdefault(qid(b, 'c'), []).append(qid(b, 'p'))
    batched([e['id'] for e in ents if e.get('label')], 600, lambda v: f'SELECT ?c ?p WHERE {{ VALUES ?c {{ {v} }} ?c wdt:P749 ?p }}', add, 'parents')
    return out


print('Parent organizations…', file=sys.stderr)
parents = cached('parents.json', parent_links)

# ---- the file

def latin(s):
    f = unicodedata.normalize('NFKD', s).encode('ascii', 'ignore').decode()
    return len(f) >= 0.8 * len(s.replace(' ', '')) and any(c.isalpha() for c in f)


def key(s):
    return re.sub(r'[^a-z0-9]', '', unicodedata.normalize('NFKD', s).encode('ascii', 'ignore').decode().lower())


# "Infosys limited" is shown as "Infosys", "Oracle Corporation" as "Oracle" (the longer name stays as another name).
KIND = re.compile(r'(,?\s+(inc\.?|incorporated|llc|l\.l\.c\.|ltd\.?|limited|corp\.?|corporation|plc|gmbh|ag|s\.a\.|n\.v\.|co\.))+$', re.I)

kept = []
for e in ents:
    label = (e.get('label') or '').strip()
    if not label or not latin(label) or re.match(r'^Q\d+$', label) or len(label) > 90: continue
    staff = int(e.get('emp') or 0)
    if staff < 1000 and e['id'] not in slugs: continue
    short = KIND.sub('', label).strip(' ,')
    name = short if len(short) >= 2 else label
    others, seen = [], {key(name)}
    for a in [label] + e.get('aliases', []) + [re.sub(r'\s+', ' ', s.replace('-', ' ')).strip() for s in sorted(slugs.get(e['id'], [])) if not re.search(r'\d{3,}', s)]:
        a = a.strip()
        k = key(a)
        if not (2 <= len(a) <= 80) or not latin(a) or 'http' in a.lower() or not k or k.isdigit() or k in seen: continue
        seen.add(k)
        others.append(a.replace('|', '/').replace('\t', ' '))
    kept.append({'id': e['id'], 'name': name.replace('\t', ' ').replace('|', '/'), 'others': others[:12], 'staff': staff})

kept.sort(key=lambda e: (-e['staff'], e['name'].lower()))
line = {e['id']: i for i, e in enumerate(kept)}
with open(OUT, 'w') as f:
    for e in kept:
        owner = next((line[p] for p in parents.get(e['id'], []) if p in line and p != e['id']), '')
        f.write(f"{e['name']}\t{'|'.join(e['others'])}\t{e['staff'] or ''}\t{owner}\n")
print(f'Wrote {OUT}: {len(kept)} companies')
