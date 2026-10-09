"""Add hard drop shadows behind filled shapes that hold text.

Usage: python3 shadow.py SRC.excalidraw DST.excalidraw [--offset PX] [--opacity PCT]

A shadow is a copy of the shape, moved by `--offset` px right and down, filled
with the shape's own stroke colour and inserted just below it in z-order.
Handles rectangles, diamonds and ellipses that contain a bound text element
and have a fill other than transparent.

Skipped: legend swatches (shapes exactly 26x20), the neutral `#e9ecef` panel
fill, shapes 1000 px or wider (backgrounds and frames), and shapes that
already have a shadow, so a second run changes nothing.
"""
from __future__ import annotations

import argparse
import json

SHAPES = {'rectangle', 'diamond', 'ellipse'}
SWATCH_SIZE = (26, 20)
SKIP_FILLS = {'transparent', '#e9ecef'}
MAX_WIDTH = 1000
INDEX_SUFFIXES = ('V', 'k', 'VV')


def free_index(idx: str, used: set[str]) -> str:
    'A fractional index sorting just below idx, unused so far.'
    pred = max((i for i in used if i < idx), default='')
    for suffix in INDEX_SUFFIXES:
        cand = pred + suffix
        if pred < cand < idx and cand not in used:
            used.add(cand)
            return cand
    raise SystemExit(f'no free index below {idx}')


def wants_shadow(e: dict, texted: set[str], ids: set[str]) -> bool:
    if e['type'] not in SHAPES or e['id'] not in texted:
        return False
    if e['id'] + '-shadow' in ids:
        return False
    if e.get('backgroundColor', 'transparent') in SKIP_FILLS:
        return False
    if (round(e['width']), round(e['height'])) == SWATCH_SIZE:
        return False
    return e['width'] < MAX_WIDTH


def make_shadow(e: dict, offset: float, opacity: int, used: set[str]) -> dict:
    s = dict(e)
    s.update(
        id              = e['id'] + '-shadow',
        x               = e['x'] + offset,
        y               = e['y'] + offset,
        backgroundColor = e['strokeColor'],
        fillStyle       = 'solid',
        strokeWidth     = 1,
        opacity         = opacity,
        boundElements   = None,
        groupIds        = list(e.get('groupIds') or []),
        index           = free_index(e['index'], used),
        seed            = e['seed'] + 7919,
        versionNonce    = e['versionNonce'] + 1,
        version         = 1,
        link            = None,
        locked          = False,
    )
    return s


def add_shadows(doc: dict, offset: float, opacity: int) -> int:
    els = doc['elements']
    texted = {e['containerId'] for e in els if e['type'] == 'text' and e.get('containerId')}
    used = {e['index'] for e in els}
    ids = {e['id'] for e in els}
    out, count = [], 0
    for e in els:
        if wants_shadow(e, texted, ids):
            out.append(make_shadow(e, offset, opacity, used))
            count += 1
        out.append(e)
    doc['elements'] = out
    return count


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('src')
    ap.add_argument('dst')
    ap.add_argument('--offset', type=float, default=6)
    ap.add_argument('--opacity', type=int, default=80)
    args = ap.parse_args()
    with open(args.src) as f:
        doc = json.load(f)
    count = add_shadows(doc, args.offset, args.opacity)
    with open(args.dst, 'w') as f:
        json.dump(doc, f, indent=2)
    print('shadowed', count)


if __name__ == '__main__':
    main()
