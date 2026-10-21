"""List, insert and sheet the bundled icon library (references/icons) for Excalidraw diagrams."""
import argparse
import copy
import json
import random
import string
from pathlib import Path

ICON_DIR = Path(__file__).resolve().parent.parent / 'references' / 'icons'
PATH_TYPES = {'line', 'arrow', 'freedraw'}
LABEL_COLOUR = '#868e96'
LABEL_SIZE = 16
LABEL_GAP = 8
CHAR_WIDTH = 0.6
LINE_HEIGHT = 1.25
SHEET_COLS = 6
SHEET_CELL = 220
SHEET_FIT = 140
ALPHABET = string.ascii_letters + string.digits + '_-'


def load_index():
    return json.loads((ICON_DIR / 'index.json').read_text())


def load_icon(name):
    path = ICON_DIR / f'{name}.excalidraw'
    if not path.exists():
        raise SystemExit(f'unknown icon: {name} (try: icon.py list)')
    return json.loads(path.read_text())


def new_id(taken, prefix=''):
    while True:
        cand = prefix + ''.join(random.choices(ALPHABET, k=18))
        if cand not in taken:
            taken.add(cand)
            return cand


def scale_element(el, k):
    for key in ('x', 'y', 'width', 'height'):
        if key in el:
            el[key] = el[key] * k
    if el.get('type') in PATH_TYPES and el.get('points'):
        el['points'] = [[px * k, py * k] for px, py in el['points']]
    if el.get('type') == 'text':
        el['fontSize'] = el.get('fontSize', 20) * k


def remap_element(el, ids, groups, taken):
    el['id'] = ids[el['id']]
    if el.get('containerId'):
        el['containerId'] = ids.get(el['containerId'], el['containerId'])
    if el.get('boundElements'):
        for entry in el['boundElements']:
            entry['id'] = ids.get(entry['id'], entry['id'])
    for bind in ('startBinding', 'endBinding'):
        if el.get(bind):
            el[bind]['elementId'] = ids.get(el[bind]['elementId'], el[bind]['elementId'])
    el['groupIds'] = [groups.setdefault(g, f'{g}-{new_id(taken)[:8]}') for g in el.get('groupIds', [])]
    el['frameId'] = None
    el['seed'] = random.randint(1, 2**31 - 1)
    el.pop('index', None)


def label_element(text, cx, y, group, taken, prefix):
    width = len(text) * LABEL_SIZE * CHAR_WIDTH
    return {
        'type': 'text', 'id': new_id(taken, prefix),
        'x': cx - width / 2, 'y': y,
        'width': width, 'height': LABEL_SIZE * LINE_HEIGHT,
        'text': text, 'originalText': text,
        'fontSize': LABEL_SIZE, 'fontFamily': 5,
        'textAlign': 'center', 'verticalAlign': 'top',
        'strokeColor': LABEL_COLOUR, 'backgroundColor': 'transparent',
        'fillStyle': 'solid', 'strokeWidth': 1, 'strokeStyle': 'solid',
        'roughness': 0, 'opacity': 100, 'angle': 0,
        'seed': random.randint(1, 2**31 - 1), 'version': 1, 'versionNonce': 1,
        'isDeleted': False, 'groupIds': [group], 'frameId': None,
        'boundElements': None, 'link': None, 'locked': False,
        'containerId': None, 'lineHeight': LINE_HEIGHT, 'autoResize': True,
    }


def reindex(elements):
    if not any('index' in el for el in elements):
        return
    for i, el in enumerate(elements):
        el['index'] = 'a' + format(i, '04d')


def add_icon(doc, name, x, y, scale=1.0, label=None, id_prefix=''):
    'Append an icon to doc at (x, y); return its scaled (width, height).'
    icon = load_icon(name)
    info = load_index()[name]
    taken = {el['id'] for el in doc['elements']}
    ids = {el['id']: new_id(taken, id_prefix) for el in icon['elements']}
    groups = {}
    new = []
    for el in copy.deepcopy(icon['elements']):
        scale_element(el, scale)
        el['x'] += x
        el['y'] += y
        remap_element(el, ids, groups, taken)
        new.append(el)
    width, height = info['width'] * scale, info['height'] * scale
    if label:
        group = next(iter(groups.values()), f'icon-{name}')
        new.append(label_element(label, x + width / 2, y + height + LABEL_GAP, group, taken, id_prefix))
    doc['elements'].extend(new)
    doc.setdefault('files', {}).update(icon.get('files') or {})
    reindex(doc['elements'])
    return width, height


def new_doc():
    return {
        'type': 'excalidraw', 'version': 2, 'source': 'icon.py',
        'elements': [], 'files': {},
        'appState': {'viewBackgroundColor': '#ffffff', 'gridSize': None},
    }


def pick_scale(info, args):
    if args.size:
        return args.size / max(info['width'], info['height'])
    if args.width:
        return args.width / info['width']
    if args.height:
        return args.height / info['height']
    return 1.0


def cmd_list(args):
    query = (args.query or '').lower()
    for name, info in load_index().items():
        if query and query not in name and query not in info['tags'].lower():
            continue
        print(f"{name:22} {info['width']:>4} x {info['height']:<4} {info['tags']}")


def cmd_add(args):
    info = load_index().get(args.name)
    if info is None:
        raise SystemExit(f'unknown icon: {args.name} (try: icon.py list)')
    doc = json.loads(Path(args.diagram).read_text())
    w, h = add_icon(doc, args.name, args.x, args.y, pick_scale(info, args), args.label, args.id_prefix)
    Path(args.out or args.diagram).write_text(json.dumps(doc, indent=2))
    print(f'added {args.name} at ({args.x}, {args.y}) size {w:.0f} x {h:.0f}')


def cmd_sheet(args):
    doc = new_doc()
    for i, (name, info) in enumerate(load_index().items()):
        col, row = i % SHEET_COLS, i // SHEET_COLS
        k = SHEET_FIT / max(info['width'], info['height'])
        w, h = info['width'] * k, info['height'] * k
        x = col * SHEET_CELL + (SHEET_CELL - w) / 2
        y = row * SHEET_CELL + (SHEET_FIT - h) / 2
        add_icon(doc, name, x, y, k, label=name)
    Path(args.out).write_text(json.dumps(doc, indent=2))
    print(f'wrote {args.out} ({len(doc["elements"])} elements)')


def build_parser():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('list', help='print icon names, sizes and tags')
    p.add_argument('query', nargs='?', help='substring of name or tags')
    p.set_defaults(fn=cmd_list)
    p = sub.add_parser('add', help='insert an icon into a diagram')
    p.add_argument('diagram')
    p.add_argument('name')
    p.add_argument('--x', type=float, required=True)
    p.add_argument('--y', type=float, required=True)
    size = p.add_mutually_exclusive_group()
    size.add_argument('--size', type=float, help='target size of the larger dimension')
    size.add_argument('--width', type=float)
    size.add_argument('--height', type=float)
    p.add_argument('--label', help='centred text under the icon')
    p.add_argument('--id-prefix', default='', help='prefix for new element ids')
    p.add_argument('--out', help='write here instead of editing in place')
    p.set_defaults(fn=cmd_add)
    p = sub.add_parser('sheet', help='build a contact sheet of every icon')
    p.add_argument('out')
    p.set_defaults(fn=cmd_sheet)
    return ap


def main():
    args = build_parser().parse_args()
    args.fn(args)


if __name__ == '__main__':
    main()
