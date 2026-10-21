#!/usr/bin/env python3
"""Convert a mermaid `classDiagram` or `erDiagram` into an Excalidraw file.

Three input paths:

- `classDiagram` (direction LR) + composition edges (`*--`/`--*`) + optional
  member lists -> pastel UML boxes (the original v1 behaviour).
- `erDiagram` + entity attribute blocks + crowfoot relationships -> ERD
  tables styled after a hand-drawn ERD reference (colored header band,
  matching light body tint, mono rows, grey row dividers, PK/UK/FK colored
  rows).
- `flowchart` / `graph` + subgraphs + `classDef`/`class`/`style`/`linkStyle`
  -> rounded boxes styled after a hand-drawn decision-tree reference. See
  `flowchart.py`.
- `gantt` + sections + `name : start, end` tasks -> banded timeline with
  rounded bars and a unit grid, styled after a hand-converted reference. See
  `gantt.py`.
- `pie` (optionally `showData`) + `"label" : value` slices -> a hand-drawn
  pie chart with solid-filled wedges, percentage labels, no legend,
  styled after a hand-drawn reference pie. See `pie.py`.
- `sequenceDiagram` + `participant`/`actor` declarations, messages, notes and
  `par`/`loop`/`alt`/`opt`/`rect` blocks -> participant headers over grey
  lifelines with bound message labels, styled after a reference conversion of
  this skill's own example. See `sequence.py`.

The diagram type is taken from the first directive line in the input.

Usage: convert.py [--format full|min] [--no-examples] <input.mmd> <output.excalidraw>
"""
import argparse
import json
import math
import re
import sys
import textwrap
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).absolute().parent))  # -I drops it

from shadow import add_shadows

FONT_SIZE = 22
FONT_FAMILY = 8  # matches the hand-converted reference boxes
CHAR_W = FONT_SIZE * 0.55
TITLE_OFFSET_Y = 20
DIVIDER_OFFSET_Y = 60.5
FIRST_MEMBER_OFFSET_Y = 77.0
MEMBER_LINE_H = 61.5
BASE_HEIGHT = 120.0
HEIGHT_A = 58.5
MIN_WIDTH = 150.0
PAD_X = 50.0
COL_GAP = 120.0
ROW_GAP = 40.0

PALETTE = [  # (fill, stroke) pairs
    ("#e7f5ff", "#1971c2"),  # blue
    ("#e6fcf5", "#0ca678"),  # teal
    ("#ebfbee", "#2f9e44"),  # green
    ("#f4fce3", "#66a80f"),  # lime
    ("#f3f0ff", "#7048e8"),  # purple
    ("#fff0f6", "#c2255c"),  # pink
    ("#fff5f5", "#e03131"),  # red-tint
]
LINE_COLOR = "#868e96"

# --- ERD table styling -------------------------------------------------
# Geometry reverse-engineered from the tables in a hand-drawn ERD
# reference diagram. Those were drawn at a huge zoom;
# every ratio below is that file's geometry divided through by its row
# font size, then re-multiplied by ERD_ROW_FONT.
ERD_ROW_FONT = 20.0
ERD_FONT_FAMILY = 8  # body text
ERD_TITLE_FONT_FAMILY = 5  # entity titles
ERD_TITLE_FONT = ERD_ROW_FONT * 1.385
ERD_ROW_H = ERD_ROW_FONT * 2.307
ERD_HEADER_H = ERD_ROW_FONT * 3.075
ERD_TITLE_OFFSET_Y = ERD_ROW_FONT * 0.847
ERD_PAD_X = ERD_ROW_FONT * 0.77
ERD_CHAR_W = ERD_ROW_FONT * 0.6  # excalidraw's mono face
ERD_MIN_WIDTH = 260.0
ERD_COL_GAP = 240.0
ERD_LABEL_FONT = 12
EX_FONT = 12  # example-data tables
EX_CHAR_W = EX_FONT * 0.6
EX_ROW_H = 24.0
EX_PAD_X = 8.0
EX_GAP = 56.0  # entity bottom -> example table top
EX_GRID = "#ced4da"
EX_HEADER_FILL = "#f1f3f5"
EX_COMMENT_RE = re.compile(r"^%%\s*example\s+(\S+)\s*:\s*(.*)$")
GROUP_COMMENT_RE = re.compile(
    r"^%%\s*group\s+(.+?)(?:\s+color=([\w-]+))?\s*:\s*(.*)$")
NOTE_COMMENT_RE = re.compile(r"^%%\s*note\s+(.+?)\s*:\s*(.*)$")
GP = 36.0  # container padding
COMPACT_STEP = 18.0  # min format: spacing of parallel lines
MIN_GP = 14.0  # min format: half-gap between cells
GROUP_TAG_GAP = 70.0  # extra room above a container for its caption tag
NOTE_WRAP = 34
NOTE_LINE_H = 15.0
EX_SIDE_GAP = 70.0  # entity right edge -> example table, when placed beside
MIN_ROW_GAP = 34.0
MIN_LABEL_MARGIN = 40.0
ERD_BODY_IN_GROUP = "#f8f9fa"
# hue name -> (header band / container stroke, container secondary fill),
# from references/color-palette.md
ERD_HUES = {
    "blue": ("#1971c2", "#e7f5ff"),
    "green": ("#2f9e44", "#ebfbee"),
    "orange": ("#f08c00", "#fff9db"),
    "yellow": ("#f08c00", "#fff9db"),
    "red": ("#e03131", "#fff5f5"),
    "purple": ("#9c36b5", "#f8f0fc"),
    "indigo": ("#4263eb", "#edf2ff"),
    "gray": ("#868e96", "#f8f9fa"),
}
ERD_HUE_CYCLE = ["blue", "green", "orange", "red", "purple", "indigo"]
ERD_LABEL_COLOR = "#868e96"
ERD_LABEL_PAD = 6  # added to the estimated label width
ERD_LABEL_MARGIN = 90.0  # visible line length each side of a label
ERD_ROW_GAP = 60.0
ERD_DIVIDER_COLOR = "#868e96"
ERD_BORDER_COLOR = "#868e96"  # arrows and markers
ERD_TITLE_COLOR = "#ffffff"
ERD_TEXT_COLOR = "#1e1e1e"
ERD_KEY_COLORS = {"PK": "#e67700", "UK": "#2f9e44", "FK": "#c92a2a"}
# (header band / body tint) pairs, cycled per entity — "style B" from the
# reference diagram, i.e. a tinted body rather than a transparent one.
ERD_PALETTE = [
    ("#1971c2", "#e7f5ff"),  # blue
    ("#2f9e44", "#ebfbee"),  # green
    ("#9c36b5", "#f8f0fc"),  # purple
    ("#e8590c", "#fff4e6"),  # orange
    ("#0c8599", "#e3fafc"),  # cyan
    ("#c2255c", "#fff0f6"),  # pink
]
# mermaid crowfoot cardinality -> excalidraw arrowhead
ERD_ARROWHEADS = {
    "||": "crowfoot_one",
    "|o": "circle_outline",
    "o|": "circle_outline",
    "}o": "crowfoot_many",
    "o{": "crowfoot_many",
    "}|": "crowfoot_one_or_many",
    "|{": "crowfoot_one_or_many",
}


def new_id():
    return uuid.uuid4().hex[:20]


class Node:
    def __init__(self, node_id, label):
        self.id = node_id
        self.label = label
        self.members = []
        self.col = 0
        self.x = 0.0
        self.y = 0.0
        self.width = MIN_WIDTH
        self.height = BASE_HEIGHT
        # populated during render
        self.rect_id = None


CLASS_WITH_BODY_RE = re.compile(r'class\s+(\w+)\["([^"]+)"\]\s*\{')
CLASS_WITH_LABEL_RE = re.compile(r'class\s+(\w+)\["([^"]+)"\]\s*$')
CLASS_BARE_RE = re.compile(r'class\s+(\w+)\s*$')
EDGE_RE = re.compile(r'(\w+)\s*(\*--|--\*|--)\s*(\w+)')


def parse_mermaid(text):
    lines = [l.strip() for l in text.splitlines()]
    nodes = {}
    edges = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if not line or line.startswith("classDiagram") or line.startswith("direction"):
            i += 1
            continue
        m = CLASS_WITH_BODY_RE.match(line)
        if m:
            node_id, label = m.group(1), m.group(2)
            node = Node(node_id, label)
            i += 1
            while i < len(lines) and lines[i] != "}":
                member = lines[i].strip()
                if member:
                    node.members.append(member)
                i += 1
            nodes[node_id] = node
            i += 1
            continue
        m = CLASS_WITH_LABEL_RE.match(line)
        if m:
            node_id, label = m.group(1), m.group(2)
            nodes[node_id] = Node(node_id, label)
            i += 1
            continue
        m = CLASS_BARE_RE.match(line)
        if m:
            node_id = m.group(1)
            if node_id not in nodes:
                nodes[node_id] = Node(node_id, node_id)
            i += 1
            continue
        m = EDGE_RE.match(line)
        if m:
            a, op, b = m.group(1), m.group(2), m.group(3)
            if op == "*--":
                owner, other = a, b  # diamond at a (owner)
            elif op == "--*":
                owner, other = b, a  # diamond at b (owner)
            else:
                owner, other = None, None
            edges.append((a, b, owner, other))
            i += 1
            continue
        i += 1
    return nodes, edges


def compute_columns(nodes, edges):
    incoming = {nid: set() for nid in nodes}
    outgoing = {nid: [] for nid in nodes}
    for a, b, _, _ in edges:
        outgoing[a].append(b)
        incoming[b].add(a)
    col = {nid: 0 for nid in nodes}
    roots = [nid for nid in nodes if not incoming[nid]]
    if not roots:
        roots = list(nodes)

    def visit(nid, depth, seen):
        if depth > col[nid]:
            col[nid] = depth
        if nid in seen:
            return
        seen = seen | {nid}
        for child in outgoing[nid]:
            visit(child, col[nid] + 1, seen)

    for r in roots:
        visit(r, 0, set())
    for nid in nodes:
        nodes[nid].col = col[nid]
    return outgoing


def size_node(node):
    lines = [node.label] + [m for m in node.members]
    max_chars = max(len(l) for l in lines)
    node.width = max(MIN_WIDTH, max_chars * CHAR_W + PAD_X)
    n_members = len(node.members)
    node.height = BASE_HEIGHT if n_members <= 1 else HEIGHT_A + MEMBER_LINE_H * n_members


def layout(nodes, outgoing):
    for node in nodes.values():
        size_node(node)

    max_col = max((n.col for n in nodes.values()), default=0)
    columns = {c: [] for c in range(max_col + 1)}
    for node in nodes.values():
        columns[node.col].append(node)

    x = 0.0
    col_widths = {}
    for c in range(max_col + 1):
        col_nodes = columns[c]
        col_widths[c] = max((n.width for n in col_nodes), default=MIN_WIDTH)

    for c in range(max_col + 1):
        col_nodes = columns[c]
        total_h = sum(n.height for n in col_nodes) + ROW_GAP * max(0, len(col_nodes) - 1)
        y = -total_h / 2.0
        for n in col_nodes:
            n.x = x
            n.y = y
            y += n.height + ROW_GAP
        x += col_widths[c] + COL_GAP


def make_frame_less_box(node, color, stroke):
    """Return (rectangle, title_text, [line, member_text]) excalidraw elements for a node."""
    group_id = new_id() if node.members else None
    group_ids = [group_id] if group_id else []

    rect_id = new_id()
    node.rect_id = rect_id
    rect = {
        "id": rect_id, "type": "rectangle",
        "x": node.x, "y": node.y, "width": node.width, "height": node.height,
        "angle": 0, "strokeColor": stroke, "backgroundColor": color,
        "fillStyle": "solid", "strokeWidth": 2, "strokeStyle": "solid",
        "roughness": 0, "opacity": 100, "groupIds": group_ids, "frameId": None,
        "roundness": None, "seed": 1, "version": 1, "versionNonce": 1,
        "isDeleted": False, "boundElements": [], "updated": 1, "link": None,
        "locked": False, "customData": {"shadow": True},
    }

    title = {
        "id": new_id(), "type": "text",
        "x": node.x + 21.3, "y": node.y + TITLE_OFFSET_Y,
        "width": len(node.label) * CHAR_W, "height": 27.5,
        "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": color,
        "fillStyle": "hachure", "strokeWidth": 1, "strokeStyle": "solid",
        "roughness": 0, "opacity": 100, "groupIds": group_ids, "frameId": None,
        "roundness": None, "seed": 1, "version": 1, "versionNonce": 1,
        "isDeleted": False, "boundElements": [], "updated": 1, "link": None,
        "locked": False,
        "text": node.label, "fontSize": FONT_SIZE, "fontFamily": FONT_FAMILY,
        "textAlign": "left", "verticalAlign": "top", "containerId": None,
        "originalText": node.label, "autoResize": True, "lineHeight": 1.25,
    }

    extras = []
    if node.members:
        line = {
            "id": new_id(), "type": "line",
            "x": node.x, "y": node.y + DIVIDER_OFFSET_Y,
            "width": node.width, "height": 1.0,
            "angle": 0, "strokeColor": LINE_COLOR, "backgroundColor": color,
            "fillStyle": "solid", "strokeWidth": 2, "strokeStyle": "solid",
            "roughness": 0, "opacity": 100, "groupIds": group_ids, "frameId": None,
            "roundness": None, "seed": 1, "version": 1, "versionNonce": 1,
            "isDeleted": False, "boundElements": None, "updated": 1, "link": None,
            "locked": False,
            "points": [[0, 0], [node.width, 0]],
            "startBinding": None, "endBinding": None,
            "startArrowhead": None, "endArrowhead": None, "polygon": False,
        }
        extras.append(line)
        for idx, member in enumerate(node.members):
            text = {
                "id": new_id(), "type": "text",
                "x": node.x + 21.3, "y": node.y + FIRST_MEMBER_OFFSET_Y + idx * MEMBER_LINE_H,
                "width": len(member) * CHAR_W, "height": 27.5,
                "angle": 0, "strokeColor": "#1e1e1e", "backgroundColor": color,
                "fillStyle": "hachure", "strokeWidth": 1, "strokeStyle": "solid",
                "roughness": 0, "opacity": 100, "groupIds": group_ids, "frameId": None,
                "roundness": None, "seed": 1, "version": 1, "versionNonce": 1,
                "isDeleted": False, "boundElements": [], "updated": 1, "link": None,
                "locked": False,
                "text": member, "fontSize": FONT_SIZE, "fontFamily": FONT_FAMILY,
                "textAlign": "left", "verticalAlign": "top", "containerId": None,
                "originalText": member, "autoResize": True, "lineHeight": 1.25,
            }
            extras.append(text)

    return rect, title, extras


def make_arrow(owner_node, other_node):
    """Elbowed composition arrow, diamond at owner_node's edge."""
    # owner -> other, left to right (owner is upstream column)
    start_x = owner_node.x + owner_node.width
    start_y = owner_node.y + owner_node.height / 2.0
    end_x = other_node.x
    end_y = other_node.y + other_node.height / 2.0

    mid_x = (start_x + end_x) / 2.0
    dx_end = end_x - start_x
    points = [
        [0, 0],
        [mid_x - start_x, 0],
        [mid_x - start_x, end_y - start_y],
        [dx_end, end_y - start_y],
    ]

    arrow_id = new_id()
    arrow = {
        "id": arrow_id, "type": "arrow",
        "x": start_x, "y": start_y,
        "width": abs(dx_end), "height": abs(end_y - start_y),
        "angle": 0, "strokeColor": LINE_COLOR, "backgroundColor": "transparent",
        "fillStyle": "solid", "strokeWidth": 2, "strokeStyle": "solid",
        "roughness": 0, "opacity": 100, "groupIds": [], "frameId": None,
        "roundness": None, "seed": 1, "version": 1, "versionNonce": 1,
        "isDeleted": False, "boundElements": [], "updated": 1, "link": None,
        "locked": False,
        "points": points, "lastCommittedPoint": None,
        "startBinding": {
            "elementId": owner_node.rect_id, "mode": "orbit",
            "fixedPoint": [1.0, 0.5],
        },
        "endBinding": {
            "elementId": other_node.rect_id, "mode": "orbit",
            "fixedPoint": [0.0, 0.5],
        },
        "startArrowhead": "diamond", "endArrowhead": None,
        "elbowed": True, "fixedSegments": None,
        "startIsSpecial": None, "endIsSpecial": None,
    }
    return arrow


# --- erDiagram ---------------------------------------------------------

ER_ENTITY_OPEN_RE = re.compile(r'^(\w+)\s*(?:\["([^"]+)"\])?\s*\{$')
ER_ENTITY_BARE_RE = re.compile(r'^(\w+)\s*(?:\["([^"]+)"\])?$')
ER_ATTR_RE = re.compile(
    r'^(?P<type>\S+)\s+(?P<name>\w+)'
    r'(?:\s+(?P<keys>(?:PK|FK|UK)(?:\s*,\s*(?:PK|FK|UK))*))?'
    r'(?:\s+"(?P<comment>[^"]*)")?$'
)
ER_REL_RE = re.compile(
    r'^(\w+)\s+(\|\||\|o|\}o|\}\|)(--|\.\.)(\|\||o\||o\{|\|\{)\s+(\w+)'
    r'\s*(?::\s*(?:"([^"]*)"|(\S.*?))\s*)?$'
)


class Entity(Node):
    def __init__(self, entity_id, label):
        super().__init__(entity_id, label)
        self.attrs = []  # list of (name, type, keys)
        self.rows = []   # rendered row strings, filled by size_entity
        self.examples = []  # list of value lists from `%% example` comments
        self.ex_cols = []   # example table column widths
        self.ex_w = 0.0
        self.ex_h = 0.0
        self.beside = False  # example table to the right instead of below
        self.group = None    # Group, set by parse_er
        self.note = []       # wrapped caption-tag lines
        self.note_h = 0.0    # space above the box taken by the tag


class Group:
    def __init__(self, name, color, members):
        self.name = name
        self.color = color
        self.members = members
        self.note = []
        self.hue = None  # (stroke, secondary), set by parse_er


def parse_er(text, examples=True):
    """Parse an `erDiagram` into (entities, relationships).

    Relationships are (left_id, right_id, left_card, right_card, dotted, label).
    """
    lines = [l.strip() for l in text.splitlines()]
    entities = {}
    rels = []
    group_defs = []
    notes = []

    def ensure(eid, label=None):
        if eid not in entities:
            entities[eid] = Entity(eid, label or eid)
        elif label:
            entities[eid].label = label
        return entities[eid]

    pending = []
    i = 0
    while i < len(lines):
        line = lines[i]
        gm = GROUP_COMMENT_RE.match(line)
        if gm:
            names = [n.strip() for n in gm.group(3).split(",") if n.strip()]
            group_defs.append((gm.group(1).strip(), gm.group(2), names))
            i += 1
            continue
        nm = NOTE_COMMENT_RE.match(line)
        if nm:
            notes.append((nm.group(1).strip(), nm.group(2).strip()))
            i += 1
            continue
        em = EX_COMMENT_RE.match(line)
        if em:
            if examples:
                pending.append((em.group(1),
                                [v.strip() for v in em.group(2).split("|")]))
            i += 1
            continue
        if not line or line.startswith("erDiagram") or line.startswith("direction") \
                or line.startswith("%%"):
            i += 1
            continue

        m = ER_REL_RE.match(line)
        if m:
            left, lcard, link, rcard, right, qlabel, plabel = m.groups()
            ensure(left)
            ensure(right)
            rels.append((left, right, lcard, rcard, link == "..",
                         qlabel if qlabel is not None else (plabel or "")))
            i += 1
            continue

        m = ER_ENTITY_OPEN_RE.match(line)
        if m:
            entity = ensure(m.group(1), m.group(2))
            i += 1
            while i < len(lines) and lines[i] != "}":
                attr = lines[i].strip()
                am = ER_ATTR_RE.match(attr) if attr else None
                if am:
                    keys = am.group("keys") or ""
                    keys = ",".join(k.strip() for k in keys.split(",") if k.strip())
                    entity.attrs.append((am.group("name"), am.group("type"), keys))
                i += 1
            i += 1
            continue

        m = ER_ENTITY_BARE_RE.match(line)
        if m:
            ensure(m.group(1), m.group(2))
            i += 1
            continue

        i += 1
    for key, values in pending:
        for entity in entities.values():
            if key in (entity.id, entity.label):
                entity.examples.append(values)
    groups = []
    for gi, (name, color, names) in enumerate(group_defs):
        hue = color if color in ERD_HUES else ERD_HUE_CYCLE[gi % len(ERD_HUE_CYCLE)]
        members = []
        for entity in entities.values():
            if entity.id in names or entity.label in names:
                members.append(entity)
        group = Group(name, hue, members)
        group.hue = ERD_HUES[hue]
        for entity in members:
            entity.group = group
        groups.append(group)
    for key, text_ in notes:
        lines_ = textwrap.wrap(text_, NOTE_WRAP) or [""]
        target = next((e for e in entities.values() if key in (e.id, e.label)),
                      None)
        if target is None:
            target = next((g for g in groups
                           if g.name.lower() == key.lower()), None)
        if target is not None:
            target.note = lines_
    for entity in entities.values():
        if entity.note:
            entity.note_h = note_size(entity.note)[1] + 10.0
    return entities, rels, groups


def note_size(lines):
    w = max(len(l) for l in lines) * EX_CHAR_W + 16.0
    return w, len(lines) * NOTE_LINE_H + 10.0


def size_entity(entity):
    """Lay out the attribute columns and set the entity's box size."""
    if entity.attrs:
        name_w = max(len(a[0]) for a in entity.attrs) + 2
        type_w = max(len(a[1]) for a in entity.attrs) + 3
    else:
        name_w = type_w = 0
    entity.rows = [
        (f"{name:<{name_w}}{type_:<{type_w}}{keys}".rstrip(), keys)
        for name, type_, keys in entity.attrs
    ]
    widest = max([len(r[0]) for r in entity.rows] or [0])
    title_w = len(entity.label) * ERD_TITLE_FONT * 0.6
    entity.width = max(
        ERD_MIN_WIDTH,
        widest * ERD_CHAR_W + 2 * ERD_PAD_X,
        title_w + 2 * ERD_PAD_X,
    )
    entity.height = ERD_HEADER_H + ERD_ROW_H * len(entity.rows)
    size_examples(entity)


def example_header(entity):
    return [a[0] for a in entity.attrs]


def size_examples(entity):
    """Set the column widths and size of the entity's example-data table."""
    entity.ex_cols, entity.ex_w, entity.ex_h = [], 0.0, 0.0
    if not entity.examples:
        return
    header = example_header(entity)
    ncols = len(header)
    grid = [header] + [(r + [""] * ncols)[:ncols] for r in entity.examples]
    entity.ex_cols = [
        max(len(row[c]) for row in grid) * EX_CHAR_W + 2 * EX_PAD_X
        for c in range(ncols)
    ]
    entity.ex_w = sum(entity.ex_cols)
    entity.ex_h = EX_ROW_H * len(grid)


def erd_label_width(label):
    return math.ceil(len(label) * ERD_LABEL_FONT * 0.6) + ERD_LABEL_PAD


def slot_height(entity):
    """Note tag, entity, and the example table below it when there is one."""
    below = EX_GAP + entity.ex_h if entity.ex_h and not entity.beside else 0.0
    return entity.note_h + entity.height + below


def slot_gap(a, b, full, row_gap):
    if not full or a.group is b.group or not (a.group or b.group):
        return row_gap
    return row_gap + 2 * GP + (GROUP_TAG_GAP if b.group and b.group.note else 0)


def er_layout(entities, rels=(), groups=(), fmt="full"):
    full = fmt == "full"
    row_gap = ERD_ROW_GAP if full else MIN_ROW_GAP
    margin = ERD_LABEL_MARGIN if full else MIN_LABEL_MARGIN
    base_gap = ERD_COL_GAP if full else ERD_COL_GAP / 2.0
    pad_gap = 2 * GP if full and groups else 0.0
    for entity in entities.values():
        size_entity(entity)
    max_col = max((e.col for e in entities.values()), default=0)
    columns = {c: [] for c in range(max_col + 1)}
    for entity in entities.values():
        columns[entity.col].append(entity)
        entity.beside = bool(full and entity.ex_h and entity.col == max_col)
    order = {id(g): i for i, g in enumerate(groups)}
    for col in columns.values():  # keep group members next to each other
        col.sort(key=lambda e: order[id(e.group)] if e.group else -1)
    gaps = {c: base_gap + pad_gap for c in range(max_col + 1)}
    for left, right, _lc, _rc, _dot, label in rels:
        a, b = entities[left], entities[right]
        lo = min(a.col, b.col)
        need = erd_label_width(label) + 2 * margin if label else 0
        gaps[lo] = max(gaps[lo], need + pad_gap)
    x = pad_gap / 2.0
    for c in range(max_col + 1):
        col_entities = columns[c]
        gap_sum = sum(slot_gap(a, b, full, row_gap)
                      for a, b in zip(col_entities, col_entities[1:]))
        total_h = sum(slot_height(e) for e in col_entities) + gap_sum
        y = -total_h / 2.0
        for i, e in enumerate(col_entities):
            e.x = x
            e.y = y + e.note_h
            y += slot_height(e)
            if i + 1 < len(col_entities):
                y += slot_gap(e, col_entities[i + 1], full, row_gap)
        x += max((e.width + EX_SIDE_GAP + e.ex_w if e.beside
                  else max(e.width, e.ex_w) for e in col_entities),
                 default=ERD_MIN_WIDTH) + gaps[c]


def _base(el_id, el_type, x, y, width, height, group_ids, **extra):
    el = {
        "id": el_id, "type": el_type,
        "x": x, "y": y, "width": width, "height": height,
        "angle": 0, "strokeColor": ERD_BORDER_COLOR,
        "backgroundColor": "transparent", "fillStyle": "solid",
        "strokeWidth": 1, "strokeStyle": "solid", "roughness": 0,
        "opacity": 100, "groupIds": group_ids, "frameId": None,
        "roundness": None, "seed": 1, "version": 1, "versionNonce": 1,
        "isDeleted": False, "boundElements": [], "updated": 1, "link": None,
        "locked": False,
    }
    el.update(extra)
    return el


def _erd_text(text, x, y, width, color, font_size, align, group_ids,
              family=ERD_FONT_FAMILY):
    return _base(
        new_id(), "text", x, y, width, font_size * 1.25, group_ids,
        strokeColor=color, text=text, originalText=text,
        fontSize=font_size, fontFamily=family,
        textAlign=align, verticalAlign="top", containerId=None,
        autoResize=False, lineHeight=1.25,
    )


def make_erd_table(entity, accent, tint):
    """Return the excalidraw elements for one ERD table (style B: tinted body)."""
    group_ids = [new_id()]
    els = []

    # body tint, then the header band, then the outer border on top
    els.append(_base(new_id(), "rectangle", entity.x, entity.y,
                     entity.width, entity.height, group_ids,
                     strokeColor=accent, backgroundColor=tint,
                     customData={"shadow": True}))
    els.append(_base(new_id(), "rectangle", entity.x, entity.y,
                     entity.width, ERD_HEADER_H, group_ids,
                     strokeColor=accent, backgroundColor=accent,
                     customData={"shadow": False}))
    rect_id = new_id()
    entity.rect_id = rect_id
    els.append(_base(rect_id, "rectangle", entity.x, entity.y,
                     entity.width, entity.height, group_ids,
                     strokeColor=accent, strokeWidth=2))

    els.append(_erd_text(entity.label, entity.x,
                         entity.y + ERD_TITLE_OFFSET_Y, entity.width,
                         ERD_TITLE_COLOR, ERD_TITLE_FONT, "center", group_ids,
                         family=ERD_TITLE_FONT_FAMILY))

    text_w = entity.width - 2 * ERD_PAD_X
    row_text_dy = (ERD_ROW_H - ERD_ROW_FONT * 1.25) / 2.0
    for idx, (row, keys) in enumerate(entity.rows):
        top = entity.y + ERD_HEADER_H + idx * ERD_ROW_H
        els.append(_base(new_id(), "line", entity.x, top, entity.width, 0.0,
                         group_ids, strokeColor=ERD_DIVIDER_COLOR,
                         points=[[0, 0], [entity.width, 0]],
                         startBinding=None, endBinding=None,
                         startArrowhead=None, endArrowhead=None,
                         lastCommittedPoint=None, polygon=False,
                         boundElements=None))
        color = ERD_TEXT_COLOR
        for key in keys.split(","):
            if key in ERD_KEY_COLORS:
                color = ERD_KEY_COLORS[key]
                break
        els.append(_erd_text(row, entity.x + ERD_PAD_X, top + row_text_dy,
                             text_w, color, ERD_ROW_FONT, "left", group_ids))
    return els


def make_example_table(entity, accent):
    """Thin-grid example-data table, caption and curved connector."""
    group_ids = [new_id()]
    if entity.beside:
        x0, y0 = entity.x + entity.width + EX_SIDE_GAP, entity.y + EX_ROW_H
    else:
        x0, y0 = entity.x, entity.y + entity.height + EX_GAP
    w, h = entity.ex_w, entity.ex_h
    no_shadow = {"shadow": False}
    els = []
    els.append(_base(new_id(), "rectangle", x0, y0, w, EX_ROW_H, group_ids,
                     strokeColor=EX_GRID, backgroundColor=EX_HEADER_FILL,
                     customData=no_shadow))
    els.append(_base(new_id(), "rectangle", x0, y0, w, h, group_ids,
                     strokeColor=EX_GRID, customData=no_shadow))

    def grid_line(x, y, dx, dy):
        return _base(new_id(), "line", x, y, dx, dy, group_ids,
                     strokeColor=EX_GRID, points=[[0, 0], [dx, dy]],
                     startBinding=None, endBinding=None,
                     startArrowhead=None, endArrowhead=None,
                     lastCommittedPoint=None, polygon=False,
                     boundElements=None)

    nrows = len(entity.examples) + 1
    for r in range(1, nrows):
        els.append(grid_line(x0, y0 + r * EX_ROW_H, w, 0.0))
    cx = x0
    for width in entity.ex_cols[:-1]:
        cx += width
        els.append(grid_line(cx, y0, 0.0, h))
    header = example_header(entity)
    grid = [header] + [(r + [""] * len(header))[:len(header)]
                       for r in entity.examples]
    dy = (EX_ROW_H - EX_FONT * 1.25) / 2.0
    for r, row in enumerate(grid):
        cx = x0
        for c, value in enumerate(row):
            color = ERD_TEXT_COLOR if r else accent
            els.append(_erd_text(value, cx + EX_PAD_X, y0 + r * EX_ROW_H + dy,
                                 entity.ex_cols[c] - 2 * EX_PAD_X, color,
                                 EX_FONT, "left", group_ids))
            cx += entity.ex_cols[c]

    if entity.beside:  # short straight connector, entity edge -> table
        ay = y0 + EX_ROW_H / 2.0
        els.append(_base(
            new_id(), "arrow", entity.x + entity.width + 2.0, ay,
            EX_SIDE_GAP - 4.0, 0.0, [], strokeColor=accent, strokeWidth=1,
            points=[[0, 0], [EX_SIDE_GAP - 4.0, 0]],
            lastCommittedPoint=None, startBinding=None, endBinding=None,
            startArrowhead=None, endArrowhead="arrow", elbowed=False))
    else:
        # curved connector: entity bottom -> table top, small head at the table
        ax = x0 + min(36.0, entity.width / 4.0)
        bx = ax + 14.0
        span = EX_GAP - 4.0
        els.append(_base(
            new_id(), "arrow", ax, entity.y + entity.height + 2.0,
            bx - ax, span, [], strokeColor=accent, strokeWidth=1,
            roundness={"type": 2},
            points=[[0, 0], [-10, span / 2.0], [bx - ax, span]],
            lastCommittedPoint=None, startBinding=None, endBinding=None,
            startArrowhead=None, endArrowhead="arrow",
            elbowed=False))

    cap_w = 7 * EX_CHAR_W + 4
    els.append(_erd_text("example", x0 + w - cap_w, y0 - EX_FONT * 1.25 - 4,
                         cap_w, ERD_LABEL_COLOR, EX_FONT, "right", []))
    return els


def make_er_arrow(left, right, lcard, rcard, dotted, label):
    """Elbowed relationship arrow with crowfoot arrowheads at both ends."""
    start_x = left.x + left.width
    end_x = right.x
    top = max(left.y, right.y)
    bottom = min(left.y + left.height, right.y + right.height)
    if top < bottom:  # side by side: one shared y keeps the line straight
        start_y = end_y = (top + bottom) / 2.0
    else:
        start_y = left.y + left.height / 2.0
        end_y = right.y + right.height / 2.0
    mid_x = (start_x + end_x) / 2.0
    dx_end = end_x - start_x
    if start_y == end_y:
        points = [[0, 0], [dx_end, 0]]
    else:
        points = [
            [0, 0],
            [mid_x - start_x, 0],
            [mid_x - start_x, end_y - start_y],
            [dx_end, end_y - start_y],
        ]
    fp_l = (start_y - left.y) / left.height
    fp_r = (end_y - right.y) / right.height
    arrow = _base(
        new_id(), "arrow", start_x, start_y, abs(dx_end), abs(end_y - start_y),
        [], strokeWidth=2, strokeStyle="dashed" if dotted else "solid",
        points=points, lastCommittedPoint=None,
        startBinding={"elementId": left.rect_id, "mode": "orbit",
                      "fixedPoint": [1.0, fp_l]},
        endBinding={"elementId": right.rect_id, "mode": "orbit",
                    "fixedPoint": [0.0, fp_r]},
        startArrowhead=ERD_ARROWHEADS.get(lcard),
        endArrowhead=ERD_ARROWHEADS.get(rcard),
        elbowed=True, fixedSegments=None,
        startIsSpecial=None, endIsSpecial=None,
    )
    els = [arrow]
    if label:
        label_w = erd_label_width(label)
        label_h = math.ceil(ERD_LABEL_FONT * 1.25)
        text = _erd_text(label, mid_x - label_w / 2.0,
                         (start_y + end_y) / 2.0 - label_h / 2.0,
                         label_w, ERD_LABEL_COLOR, ERD_LABEL_FONT, "center", [])
        text["height"] = label_h
        text["containerId"] = arrow["id"]
        text["verticalAlign"] = "middle"
        arrow["boundElements"] = [{"id": text["id"], "type": "text"}]
        els.append(text)
    return els


LANE_STEP = 20.0  # spacing of parallel relationship lines in a channel
GRID_MAX_COLS = 3
TAG_ZONE = 56.0  # room above a container for its caption tag


def grid_columns(count, compact=False):
    """Entities per row: one row up to 3 entities, else ceil(sqrt(n)), max 3.

    The compact (min) grid allows 4 per row once there are 9 or more.
    """
    cap = 4 if compact and count >= 9 else GRID_MAX_COLS
    if count <= GRID_MAX_COLS:
        return max(count, 1)
    return min(cap, math.ceil(math.sqrt(count)))


def place_grid(entities, compact=False):
    """Set row and col on each entity, keeping each group's members adjacent.

    A group is placed as one block in consecutive cells of one row. If it does
    not fit in what is left of the row it starts a new row. A group wider than
    a row fills whole rows and the next block starts on a new row, so a
    container never encloses a non-member.
    """
    ncols = grid_columns(len(entities), compact)
    blocks, seen = [], set()
    for entity in entities:
        if id(entity) in seen:
            continue
        block = entity.group.members if entity.group else [entity]
        seen.update(id(m) for m in block)
        blocks.append(block)
    row = col = 0
    for block in blocks:
        grouped = block[0].group is not None
        if grouped and col and col + len(block) > ncols:
            row, col = row + 1, 0
        for member in block:
            if col >= ncols:
                row, col = row + 1, 0
            member.row, member.col = row, col
            col += 1
        if grouped and len(block) > ncols and col:
            row, col = row + 1, 0


def port_offset(entity, index):
    """Distance from the entity top of its index-th connection point."""
    return min(ERD_HEADER_H + ERD_ROW_H * (0.5 + index),
               entity.height - 12.0)


def plan_routes(entities, rels):
    """Choose a path kind, sides and connection points per relationship."""
    plans, ports, channels = [], {}, {}
    for left, right, lcard, rcard, dotted, label in rels:
        a, b = entities[left], entities[right]
        if a is b:
            continue
        if (b.col, b.row) < (a.col, a.row):
            a, b, lcard, rcard = b, a, rcard, lcard
        plan = {"a": a, "b": b, "lcard": lcard, "rcard": rcard,
                "dotted": dotted, "label": label,
                "side_b": "R" if b.col == a.col else "L",
                "kind": "dogleg" if b.col <= a.col + 1 else "channel"}
        if plan["kind"] == "channel":
            plan["crow"] = max(a.row, b.row)
            plan["clane"] = len(channels.setdefault(plan["crow"], []))
            channels[plan["crow"]].append(plan)
        for ent, side, key in ((a, "R", "port_a"), (b, plan["side_b"], "port_b")):
            other = b if ent is a else a
            if plan["kind"] == "channel":
                way = -1 if plan["crow"] == ent.row else 1
            else:
                way = (other.row > ent.row) - (other.row < ent.row)
            used = ports.setdefault((id(ent), side, way), [])
            # lines going up use the top rows, level lines the middle, and
            # lines going down the bottom, so lines do not cross each other
            plan[key] = port_offset(ent, {-1: 0, 0: 2, 1: 3}[way] + len(used))
            used.append(plan)
        plans.append(plan)
    return plans, channels


def assign_lanes(uses):
    """Give each (span, plan, key) use a lane; spans that miss share a lane."""
    lanes = []  # per lane: list of occupied (lo, hi) spans
    for lo, hi, plan, key in sorted(uses, key=lambda u: (u[0], u[1])):
        for k, spans in enumerate(lanes):
            if all(hi + 8.0 < s_lo or lo - 8.0 > s_hi for s_lo, s_hi in spans):
                break
        else:
            k = len(lanes)
            lanes.append([])
        lanes[k].append((lo, hi))
        plan[key] = k
    return len(lanes)


def assign_lanes_close(uses, step):
    """Like assign_lanes, but lanes are `step` apart, so a label stays clear.

    A line with a label centred on it also keeps the lanes within half the
    label width free where their y spans overlap.
    """
    def reach(plan):
        if plan["kind"] != "dogleg" or not plan["label"]:
            return 0
        return math.ceil((erd_label_width(plan["label"]) / 2.0 + 6.0) / step)

    lanes = []  # per lane: list of (lo, hi, reach)
    for lo, hi, plan, key in sorted(uses, key=lambda u: (u[0], u[1])):
        mine = reach(plan)
        for k in range(len(lanes) + 1):
            if k == len(lanes):
                lanes.append([])
                break
            clash = any(
                abs(j - k) <= max(mine, r) and not (hi + 8.0 < s_lo
                                                    or lo - 8.0 > s_hi)
                for j, spans in enumerate(lanes)
                for s_lo, s_hi, r in spans)
            if not clash:
                break
        lanes[k].append((lo, hi, mine))
        plan[key] = k
    return len(lanes)


def grid_layout(entities, rels, groups, compact=False):
    """Lay entities out in a grid and route relationships between cells.

    Returns one route per relationship: a dict holding the two entities,
    cardinalities, label and the absolute polyline points.
    """
    ents = list(entities.values())
    for entity in ents:
        size_entity(entity)
        entity.beside = False
    place_grid(ents, compact)
    gp = MIN_GP if compact else GP
    nrows = max(e.row for e in ents) + 1
    ncols = max(e.col for e in ents) + 1
    plans, channels = plan_routes(entities, rels)
    tag_zone = TAG_ZONE if not compact and any(g.note for g in groups) else 0.0

    # vertical layout does not depend on lanes, so do it first
    row_h = [max((slot_height(e) for e in ents if e.row == r), default=0.0)
             for r in range(nrows)]
    row_top, y = [], 0.0
    for r in range(nrows):
        if r:
            y += (2 * gp + tag_zone + 30.0
                  + LANE_STEP * len(channels.get(r, [])))
        row_top.append(y)
        y += row_h[r]
    for entity in ents:
        entity.y = row_top[entity.row] + entity.note_h

    label_h = math.ceil(ERD_LABEL_FONT * 1.25)
    uses = {}
    for p in plans:
        a, b = p["a"], p["b"]
        p["y1"], p["y2"] = a.y + p["port_a"], b.y + p["port_b"]
        if p["kind"] == "dogleg":
            mid = (p["y1"] + p["y2"]) / 2.0
            lo = min(p["y1"], p["y2"], mid - label_h)
            hi = max(p["y1"], p["y2"], mid + label_h)
            uses.setdefault(a.col, []).append((lo, hi, p, "lane"))
        else:
            p["yc"] = (row_top[p["crow"]] - gp - tag_zone - 10.0
                       - LANE_STEP * p["clane"])
            p["gutter_b"] = b.col - 1
            uses.setdefault(a.col, []).append(
                (min(p["y1"], p["yc"]), max(p["y1"], p["yc"]), p, "lane"))
            uses.setdefault(b.col - 1, []).append(
                (min(p["y2"], p["yc"]), max(p["y2"], p["yc"]), p, "lane_b"))

    gutter_w, first_lane, step = {}, {}, {}
    for g in range(ncols - 1):
        n = (assign_lanes_close(uses.get(g, []), COMPACT_STEP) if compact
             else assign_lanes(uses.get(g, [])))
        widest = max((erd_label_width(p["label"]) for _l, _h, p, key
                      in uses.get(g, []) if p["label"]
                      and p["kind"] == "dogleg"), default=0)
        step[g] = (COMPACT_STEP if compact
                   else widest + 14.0 if widest else 16.0)
        first_lane[g] = gp + 12.0 + widest / 2.0
        gutter_w[g] = 2 * gp + 24.0 + widest + max(n - 1, 0) * step[g]
    col_w = [max((max(e.width, e.ex_w) for e in ents if e.col == c),
                 default=ERD_MIN_WIDTH) for c in range(ncols)]
    col_x, x = [], gp
    for c in range(ncols):
        col_x.append(x)
        x += col_w[c] + gutter_w.get(c, 0.0)
    for entity in ents:
        entity.x = col_x[entity.col]

    def lane_x(g, k):
        return col_x[g] + col_w[g] + first_lane[g] + k * step[g]

    routes = []
    for p in plans:
        a, b = p["a"], p["b"]
        xa, y1, y2 = a.x + a.width, p["y1"], p["y2"]
        xe = b.x if p["side_b"] == "L" else b.x + b.width
        xl = lane_x(a.col, p["lane"])
        if p["kind"] == "dogleg":
            pts = [(xa, y1), (xl, y1), (xl, y2), (xe, y2)]
            lx, ly = xl, (y1 + y2) / 2.0
            if y1 == y2 and p["side_b"] == "L":
                pts = [(xa, y1), (xe, y2)]
        else:
            xt = lane_x(p["gutter_b"], p["lane_b"])
            yc = p["yc"]
            pts = [(xa, y1), (xl, y1), (xl, yc), (xt, yc), (xt, y2), (xe, y2)]
            lx, ly = (xl + xt) / 2.0, yc
        routes.append({**p, "points": pts, "label_at": (lx, ly)})
    return routes


def make_grid_arrow(route):
    """Polyline relationship arrow with crowfoot heads and a centred label."""
    a, b = route["a"], route["b"]
    x0, y0 = route["points"][0]
    rel = [[px - x0, py - y0] for px, py in route["points"]]
    xs, ys = [p[0] for p in rel], [p[1] for p in rel]
    end_fx = 0.0 if route["side_b"] == "L" else 1.0
    arrow = _base(
        new_id(), "arrow", x0, y0, max(xs) - min(xs), max(ys) - min(ys),
        [], strokeWidth=2, strokeStyle="dashed" if route["dotted"] else "solid",
        points=rel, lastCommittedPoint=None,
        startBinding={"elementId": a.rect_id, "mode": "orbit",
                      "fixedPoint": [1.0, route["port_a"] / a.height]},
        endBinding={"elementId": b.rect_id, "mode": "orbit",
                    "fixedPoint": [end_fx, route["port_b"] / b.height]},
        startArrowhead=ERD_ARROWHEADS.get(route["lcard"]),
        endArrowhead=ERD_ARROWHEADS.get(route["rcard"]),
        elbowed=True, fixedSegments=None,
        startIsSpecial=None, endIsSpecial=None,
    )
    els = [arrow]
    label = route["label"]
    if label:
        label_w = erd_label_width(label)
        label_h = math.ceil(ERD_LABEL_FONT * 1.25)
        lx, ly = route["label_at"]
        text = _erd_text(label, lx - label_w / 2.0, ly - label_h / 2.0,
                         label_w, ERD_LABEL_COLOR, ERD_LABEL_FONT, "center", [])
        text["height"] = label_h
        text["containerId"] = arrow["id"]
        text["verticalAlign"] = "middle"
        arrow["boundElements"] = [{"id": text["id"], "type": "text"}]
        els.append(text)
    return els


def make_note_tag(lines, x, y, stroke):
    """Small caption tag with its top-left corner at (x, y)."""
    w, h = note_size(lines)
    els = [_base(new_id(), "rectangle", x, y, w, h, [], strokeColor=stroke,
                 backgroundColor=ERD_BODY_IN_GROUP, roundness={"type": 3},
                 customData={"shadow": True})]
    els.append(_erd_text("\n".join(lines), x + 8.0, y + 5.0, w - 16.0,
                         ERD_TEXT_COLOR, EX_FONT, "left", []))
    els[-1]["height"] = len(lines) * EX_FONT * 1.25
    return els, w, h


def entity_bounds(entity):
    x0, y0 = entity.x, entity.y - entity.note_h
    x1, y1 = entity.x + entity.width, entity.y + entity.height
    if entity.ex_h and entity.beside:
        x1 = entity.x + entity.width + EX_SIDE_GAP + entity.ex_w
        y1 = max(y1, entity.y + EX_ROW_H + entity.ex_h)
    elif entity.ex_h:
        x1 = max(x1, entity.x + entity.ex_w)
        y1 = y1 + EX_GAP + entity.ex_h
    return x0, y0, x1, y1


def make_group_container(group):
    """Dashed, soft-tinted container around the group's entities (+ tag)."""
    boxes = [entity_bounds(e) for e in group.members]
    x0 = min(b[0] for b in boxes) - GP
    y0 = min(b[1] for b in boxes) - GP
    x1 = max(b[2] for b in boxes) + GP
    y1 = max(b[3] for b in boxes) + GP
    stroke, fill = group.hue
    # shadow.py skips dashed shapes, so the container has no shadow
    els = [_base(new_id(), "rectangle", x0, y0, x1 - x0, y1 - y0, [],
                 strokeColor=stroke, backgroundColor=fill, strokeStyle="dashed",
                 roundness={"type": 3}, customData={"shadow": False})]
    if group.note:
        tag, _w, h = make_note_tag(group.note, x0 + 24.0, 0.0, stroke)
        dy = y0 - h + 8.0
        for el in tag:
            el["y"] += dy
        els.extend(tag)
    return els


def convert_er(mermaid_text, examples=True, fmt="full"):
    full = fmt == "full"
    entities, rels, groups = parse_er(mermaid_text, examples and full)
    if not full:
        # no containers: fold a group caption into its first member
        for group in groups:
            if group.note and group.members:
                first = group.members[0]
                first.note = group.note + first.note
                first.note_h = note_size(first.note)[1] + 10.0
    routes = grid_layout(entities, rels, groups, compact=not full)

    elements = []
    if full:
        for group in groups:
            if group.members:
                elements.extend(make_group_container(group))
    for idx, entity in enumerate(entities.values()):
        if entity.group:
            accent, tint = entity.group.hue[0], entity.group.hue[1]
            if full:
                tint = ERD_BODY_IN_GROUP
        else:
            accent, tint = ERD_PALETTE[idx % len(ERD_PALETTE)]
        elements.extend(make_erd_table(entity, accent, tint))
        if entity.ex_h:
            elements.extend(make_example_table(entity, accent))
        if entity.note:
            tag, _w, h = make_note_tag(entity.note, entity.x,
                                       entity.y - entity.note_h + 2.0, accent)
            elements.extend(tag)
    bound = {eid: [] for eid in entities}
    for route in routes:
        arrow_els = make_grid_arrow(route)
        elements.extend(arrow_els)
        bound[route["a"].id].append(arrow_els[0]["id"])
        bound[route["b"].id].append(arrow_els[0]["id"])

    by_id = {e["id"]: e for e in elements}
    for entity in entities.values():
        if bound[entity.id]:
            by_id[entity.rect_id]["boundElements"] = [
                {"id": aid, "type": "arrow"} for aid in bound[entity.id]
            ]
    return elements


def convert(mermaid_text, examples=True, fmt="full"):
    if re.search(r'^\s*(?:flowchart|graph)\s', mermaid_text, re.M):
        from flowchart import convert_flowchart
        return document(convert_flowchart(mermaid_text))
    if re.search(r'^\s*gantt\b', mermaid_text, re.M):
        from gantt import convert_gantt
        return document(convert_gantt(mermaid_text))
    if re.search(r'^\s*pie\b', mermaid_text, re.M):
        from pie import convert_pie
        return document(convert_pie(mermaid_text), shadows=False)
    if re.search(r'^\s*xychart-beta\b', mermaid_text, re.M):
        # no legend names via this path; run xychart.py directly for --legend
        from xychart import convert_xychart
        return document(convert_xychart(mermaid_text), shadows=False)
    if re.search(r'^\s*sequenceDiagram\b', mermaid_text, re.M):
        from sequence import convert_sequence
        return document(convert_sequence(mermaid_text))
    if re.search(r'^\s*erDiagram\b', mermaid_text, re.M):
        elements = convert_er(mermaid_text, examples, fmt)
        return document(elements)
    nodes, edges = parse_mermaid(mermaid_text)
    outgoing = compute_columns(nodes, edges)
    layout(nodes, outgoing)

    elements = []
    for idx, node in enumerate(nodes.values()):
        color, stroke = PALETTE[idx % len(PALETTE)]
        rect, title, extras = make_frame_less_box(node, color, stroke)
        elements.append(rect)
        elements.append(title)
        elements.extend(extras)

    for a, b, owner, other in edges:
        if owner is None:
            owner, other = a, b
        arrow = make_arrow(nodes[owner], nodes[other])
        elements.append(arrow)
        nodes[owner].__dict__.setdefault("_bound", []).append(arrow["id"])
        nodes[other].__dict__.setdefault("_bound", []).append(arrow["id"])

    by_id = {e["id"]: e for e in elements}
    for node in nodes.values():
        bound = getattr(node, "_bound", [])
        if bound:
            by_id[node.rect_id]["boundElements"] = [
                {"id": aid, "type": "arrow"} for aid in bound
            ]

    return document(elements)


def finalise(elements):
    """Fill the fields Excalidraw's current element schema (and the
    Excalidraw+ REST API validator) require but the emitters don't set:
    a fractional `index` per element, and `mode` + `fixedPoint` on every
    arrow binding. fixedPoint is the arrow endpoint normalised to the bound
    shape's box.
    """
    by_id = {e["id"]: e for e in elements}
    for i, el in enumerate(elements):
        el["index"] = "a" + format(i, "04d")
        if el.get("type") != "arrow":
            continue
        pts = el["points"]
        for key, pt in (("startBinding", pts[0]), ("endBinding", pts[-1])):
            binding = el.get(key)
            if not binding:
                continue
            shape = by_id[binding["elementId"]]
            ax, ay = el["x"] + pt[0], el["y"] + pt[1]
            fx = (ax - shape["x"]) / shape["width"] if shape["width"] else 0.5
            fy = (ay - shape["y"]) / shape["height"] if shape["height"] else 0.5
            # not clamped to [0,1]: a sequence message binds to its participant's
            # *header* box while sitting far below it, so fy is legitimately > 1
            # (the hand-converted reference does the same). Every other path
            # anchors on the shape's own edge, so this is a no-op there.
            binding["fixedPoint"] = [round(fx, 6), round(fy, 6)]
            binding["mode"] = "orbit"
    return elements


def document(elements, shadows=True):
    """Wrap elements in a scene; shadows=False skips add_shadows (pie, xychart)."""
    if shadows:
        elements = add_shadows(elements)
    finalise(elements)
    return {
        "type": "excalidraw",
        "version": 2,
        "source": "https://app.excalidraw.com",
        "elements": elements,
        "appState": {"gridSize": None, "viewBackgroundColor": "#ffffff"},
        "files": {},
    }


def main():
    ap = argparse.ArgumentParser(description="Convert mermaid to Excalidraw.")
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--format", choices=["full", "min"], default="full",
                    help="erDiagram only: full (containers, example tables) "
                         "or min (entity tables only)")
    ap.add_argument("--no-examples", action="store_true",
                    help="ignore ER `%% example` rows (implied by --format min)")
    args = ap.parse_args()
    with open(args.src) as f:
        text = f.read()
    doc = convert(text, not args.no_examples, args.format)
    with open(args.dst, "w") as f:
        json.dump(doc, f, indent=2)


if __name__ == "__main__":
    main()
