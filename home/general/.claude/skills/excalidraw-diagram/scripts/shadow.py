"""Add offset shadows behind filled, labelled shapes in an Excalidraw document."""
import argparse
import copy
import json
import uuid

SHAPES = {'rectangle', 'diamond', 'ellipse'}
SWATCH = (26, 20)


def has_text_child(shape, by_id):
    for entry in shape.get('boundElements') or []:
        if entry.get('type') != 'text':
            continue
        child = by_id.get(entry.get('id'))
        if child and child.get('containerId') == shape['id']:
            return True
    return False


def wants_shadow(shape, by_id):
    if shape.get('type') not in SHAPES:
        return False
    custom = shape.get('customData') or {}
    if custom.get('shadow') is False or 'shadowOf' in custom:
        return False
    if shape.get('backgroundColor', 'transparent') == 'transparent':
        return False
    if shape.get('strokeStyle') != 'solid':
        return False
    if (shape.get('width'), shape.get('height')) == SWATCH:
        return False
    return custom.get('shadow') is True or has_text_child(shape, by_id)


def make_shadow(shape, offset, opacity, taken):
    el = copy.deepcopy(shape)
    new_id = uuid.uuid4().hex[:20]
    while new_id in taken:
        new_id = uuid.uuid4().hex[:20]
    colour = shape.get('strokeColor', '#1e1e1e')
    el.update(
        id=new_id,
        x=shape['x'] + offset,
        y=shape['y'] + offset,
        backgroundColor=colour,
        strokeColor=colour,
        fillStyle='solid',
        strokeWidth=1,
        strokeStyle='solid',
        opacity=opacity,
        boundElements=[] if shape.get('boundElements') is not None else None,
        link=None,
        customData={'shadowOf': shape['id']},
    )
    el.pop('index', None)
    return el


def index_between(prev, nxt):
    """Return a string strictly between prev and nxt, or None if no room."""
    cand = (prev or 'a0') + 'V'
    if cand > prev and (nxt is None or cand < nxt):
        return cand
    return None


def reindex(elements):
    for i, el in enumerate(elements):
        el['index'] = 'a' + format(i, '04d')


def indexes_valid(elements):
    idx = [el.get('index') for el in elements]
    return all(isinstance(i, str) for i in idx) and all(a < b for a, b in zip(idx, idx[1:]))


def add_shadows(elements, offset=6, opacity=80):
    by_id = {el['id']: el for el in elements}
    taken = set(by_id)
    out = []
    need_reindex = False
    for i, el in enumerate(elements):
        if wants_shadow(el, by_id) and not any(
            (o.get('customData') or {}).get('shadowOf') == el['id'] for o in elements
        ):
            sh = make_shadow(el, offset, opacity, taken)
            taken.add(sh['id'])
            prev = out[-1].get('index') if out else None
            idx = index_between(prev or '', el.get('index'))
            if idx is None or not isinstance(el.get('index'), str):
                need_reindex = True
            else:
                sh['index'] = idx
            out.append(sh)
        out.append(el)
    if need_reindex or not indexes_valid(out):
        reindex(out)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('src')
    ap.add_argument('dst')
    ap.add_argument('--offset', type=float, default=6)
    ap.add_argument('--opacity', type=int, default=80)
    args = ap.parse_args()
    with open(args.src) as f:
        doc = json.load(f)
    doc['elements'] = add_shadows(doc['elements'], args.offset, args.opacity)
    with open(args.dst, 'w') as f:
        json.dump(doc, f, indent=2)


if __name__ == '__main__':
    main()
