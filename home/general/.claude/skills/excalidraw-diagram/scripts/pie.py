"""mermaid `pie` -> Excalidraw pie chart.

Wedges start at 12 o'clock and run clockwise, largest first. Each wedge is a
solid-filled `line` polygon (centre -> arc samples -> centre) with a thin
outline in a darker shade of its hue. There is no legend: every wedge carries
`name` / `(pct%)` inside it (`name: value` with `showData`). A wedge too small
for its label gets a plain leader line to a label outside the circle, coloured
as the wedge stroke; outside labels are pushed outward until none overlap.

`%% subtitle: text` (a mermaid comment) adds a grey subtitle under the title.
"""
import math
import re

from convert import _base, new_id  # noqa: E402  (sibling module)

PIE_FONT_FAMILY = 8          # Comic Shanns, as elsewhere in this skill
PIE_TITLE_FONT_FAMILY = 5    # Excalifont, as in the gantt title
PIE_RADIUS = 230.0
PIE_ARC_STEP = 4.0           # degrees between arc samples
PIE_CHAR_W = 0.55            # * font size, same heuristic as the UML path
PIE_LABEL_FONT = 16.0
PIE_LABEL_LINE_H = PIE_LABEL_FONT * 1.25
PIE_LABEL_PAD = 6.0          # clearance around a label box
PIE_INSIDE_R = (0.5, 0.88)   # * radius, range searched for an inside label
PIE_LEADER_STEP = 12.0       # px an outside label moves per overlap retry
PIE_TITLE_FONT = 28.0
PIE_SUBTITLE_FONT = 16.0
PIE_TITLE_GAP_Y = 24.0
PIE_FREE_TEXT = "#868e96"    # dual-mode: free text (title, subtitle)
PIE_DARK_TEXT = "#1e1e1e"    # text on light fills
PIE_LIGHT_TEXT = "#ffffff"   # text on dark fills
PIE_PALETTE = [  # (fill, stroke): saturated Open Color hue, darker same-hue outline
    ("#339af0", "#1864ab"),  # blue
    ("#12b886", "#087f5b"),  # teal
    ("#fcc419", "#e67700"),  # yellow
    ("#ff922b", "#d9480f"),  # orange
    ("#fa5252", "#c92a2a"),  # red
    ("#9775fa", "#5f3dc4"),  # violet
    ("#f06595", "#a61e4d"),  # pink
    ("#22b8cf", "#0b7285"),  # cyan
    ("#94d82d", "#5c940d"),  # lime
]

SLICE_RE = re.compile(r'^"([^"]*)"\s*:\s*(-?\d+(?:\.\d+)?)$')
SUBTITLE_RE = re.compile(r'^\s*%%\s*subtitle:\s*(.+?)\s*$', re.I)


def parse_pie(text):
    """Return (title, subtitle, show_data, [(label, value), ...])."""
    title = subtitle = None
    show_data = False
    slices = []
    for raw in text.splitlines():
        m = SUBTITLE_RE.match(raw)
        if m:
            subtitle = m.group(1)
            continue
        line = raw.split("%%", 1)[0].strip()
        if not line:
            continue
        if line.startswith("pie"):
            show_data = "showData" in line
            # `pie showData title "..."` keeps the title on the directive line
            m = re.search(r'\btitle\s+(.+)$', line)
            if m:
                t = m.group(1).strip()
                title = t[1:-1] if t[:1] == t[-1:] == '"' else t
            continue
        if line.startswith("title "):
            title = line[6:].strip()
            continue
        m = SLICE_RE.match(line)
        if m:
            slices.append((m.group(1), float(m.group(2))))
    if not slices:
        raise ValueError("pie diagram has no slices")
    return title, subtitle, show_data, slices


def _text(text, x, y, width, font_size, align, group_ids, family=PIE_FONT_FAMILY,
          color=PIE_FREE_TEXT):
    lines = text.count("\n") + 1
    return _base(
        new_id(), "text", x, y, width, font_size * 1.25 * lines, group_ids,
        strokeColor=color, backgroundColor="transparent",
        text=text, originalText=text, fontSize=font_size, fontFamily=family,
        textAlign=align, verticalAlign="top", containerId=None,
        autoResize=False, lineHeight=1.25,
    )


def _rim(cx, cy, r, angle):
    """Point on the circle at `angle` degrees clockwise from 12 o'clock."""
    a = math.radians(angle)
    return cx + r * math.sin(a), cy - r * math.cos(a)


def _arc(cx, cy, r, a0, a1):
    n = max(1, int(math.ceil((a1 - a0) / PIE_ARC_STEP)))
    return [_rim(cx, cy, r, a0 + (a1 - a0) * i / n) for i in range(n + 1)]


def _wedge(cx, cy, r, a0, a1, fill, stroke, group_ids):
    pts = [(cx, cy)] + _arc(cx, cy, r, a0, a1) + [(cx, cy)]
    ox, oy = pts[0]
    rel = [[px - ox, py - oy] for px, py in pts]
    xs = [p[0] for p in rel]
    ys = [p[1] for p in rel]
    return _base(
        new_id(), "line", ox, oy, max(xs) - min(xs), max(ys) - min(ys), group_ids,
        strokeColor=stroke, backgroundColor=fill, fillStyle="solid",
        customData={"shadow": False},
        strokeWidth=1, roughness=1, points=rel, lastCommittedPoint=None,
        startBinding=None, endBinding=None,
        startArrowhead=None, endArrowhead=None, polygon=False,
    )


def _luminance(hex_color):
    rgb = [int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    lin = [c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4 for c in rgb]
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]


def _fmt_pct(pct):
    return f"{pct:.1f}%" if pct < 10 else f"{pct:.0f}%"


def _box(cx, cy, w, h):
    return (cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)


def _hit(a, b, pad=PIE_LABEL_PAD):
    return not (a[2] + pad <= b[0] or b[2] + pad <= a[0]
                or a[3] + pad <= b[1] or b[3] + pad <= a[1])


def _fits_inside(box, mid, sweep, r):
    """True when every corner of `box` (relative to the centre) is in the wedge."""
    for x, y in ((box[0], box[1]), (box[2], box[1]), (box[0], box[3]), (box[2], box[3])):
        if math.hypot(x, y) > r * 0.96:
            return False
        ang = math.degrees(math.atan2(x, -y)) % 360
        diff = abs((ang - mid + 180) % 360 - 180)
        if diff > sweep / 2 - 0.5:
            return False
    return True


def _inside_pos(mid, sweep, w, h, r):
    n = 24
    for i in range(n + 1):
        lr = r * (PIE_INSIDE_R[0] + (PIE_INSIDE_R[1] - PIE_INSIDE_R[0]) * i / n)
        x, y = _rim(0, 0, lr, mid)
        if _fits_inside(_box(x, y, w, h), mid, sweep, r):
            return x, y
    return None


def _outside_pos(mid, w, h, r, taken):
    """Stack the label above the rim point, its near side flush with the leader.

    A label in the left half ends at the leader and one in the right half starts
    at it, so leaders of neighbouring small wedges never cross a label. The label
    is raised until it clears the circle and every label placed before it.
    """
    sx, sy = _rim(0, 0, r, mid)
    left = math.sin(math.radians(mid)) < 0
    x0 = sx - w if left else sx
    d = PIE_LABEL_PAD * 2
    while True:
        box = (x0, sy - d - h, x0 + w, sy - d)
        nx = min(max(0, box[0]), box[2]) if box[0] > 0 or box[2] < 0 else 0
        ny = min(max(0, box[1]), box[3]) if box[1] > 0 or box[3] < 0 else 0
        clear = math.hypot(nx, ny) > r + PIE_LABEL_PAD
        if clear and not any(_hit(box, t) for t in taken):
            return left, box
        d += PIE_LEADER_STEP


def _leader(r, mid, box, left, stroke, group_ids):
    sx, sy = _rim(0, 0, r, mid)
    ex, ey = (box[2] if left else box[0]), box[3]
    return _base(new_id(), "line", sx, sy, abs(ex - sx), abs(ey - sy), group_ids,
                 strokeColor=stroke, strokeWidth=1, roughness=1,
                 points=[[0, 0], [ex - sx, ey - sy]], lastCommittedPoint=None,
                 startBinding=None, endBinding=None,
                 startArrowhead=None, endArrowhead=None)


def convert_pie(mermaid_text):
    title, subtitle, show_data, slices = parse_pie(mermaid_text)
    total = sum(v for _, v in slices)
    if total <= 0:
        raise ValueError("pie slice values must sum to more than zero")

    cx = cy = 0.0
    r = PIE_RADIUS
    group_ids = [new_id()]
    # largest first; sorted() is stable so ties keep their source order
    order = sorted(range(len(slices)), key=lambda i: -slices[i][1])
    ranked = [slices[i] for i in order]
    pairs = [PIE_PALETTE[i % len(PIE_PALETTE)] for i in range(len(ranked))]

    circle = []
    if len(ranked) == 1:
        f, s = pairs[0]
        circle = [_base(new_id(), "ellipse", cx - r, cy - r, 2 * r, 2 * r, group_ids,
                        strokeColor=s, backgroundColor=f, fillStyle="solid",
                        strokeWidth=1, roughness=1, customData={"shadow": False})]

    wedges, labels, leaders = [], [], []
    taken = []   # boxes of every label placed so far
    pending = []
    angle = 0.0
    for (name, value), (fill, stroke) in zip(ranked, pairs):
        sweep = value / total * 360.0
        a0, a1 = angle, angle + sweep
        angle = a1
        mid = (a0 + a1) / 2
        if len(ranked) > 1:
            wedges.append(_wedge(cx, cy, r, a0, a1, fill, stroke, group_ids))
        head = f"{name}: {value:,g}" if show_data else name
        text = f"{head}\n({_fmt_pct(value / total * 100)})"
        w = max(len(t) for t in text.split("\n")) * PIE_LABEL_FONT * PIE_CHAR_W
        h = 2 * PIE_LABEL_LINE_H
        pos = _inside_pos(mid, sweep, w, h, r) if sweep < 359.9 else (r * 0.5, 0)
        if pos is not None:
            x, y = pos
            color = PIE_DARK_TEXT if _luminance(fill) > 0.4 else PIE_LIGHT_TEXT
            taken.append(_box(x, y, w, h))
            labels.append(_text(text, x - w / 2, y - h / 2, w, PIE_LABEL_FONT,
                                "center", [], color=color))
        else:
            pending.append((mid, text, w, h, stroke))

    for mid, text, w, h, stroke in pending:
        left_side, box = _outside_pos(mid, w, h, r, taken)
        taken.append(box)
        leaders.append(_leader(r, mid, box, left_side, stroke, []))
        labels.append(_text(text, box[0], box[1], w, PIE_LABEL_FONT,
                            "right" if left_side else "left", [], color=stroke))

    # title block sits above everything, left-aligned with the leftmost element
    left = min([cx - r] + [b[0] for b in taken])
    top = min([cy - r] + [b[1] for b in taken])
    title_els = []
    y = top - PIE_TITLE_GAP_Y
    if subtitle:
        y -= PIE_SUBTITLE_FONT * 1.25
        sw = len(subtitle) * PIE_SUBTITLE_FONT * PIE_CHAR_W
        title_els.append(_text(subtitle, left, y, sw, PIE_SUBTITLE_FONT, "left", [],
                               family=PIE_FONT_FAMILY, color=PIE_FREE_TEXT))
    if title:
        y -= PIE_TITLE_FONT * 1.25 + (4 if subtitle else 0)
        tw = len(title) * PIE_TITLE_FONT * 0.57
        title_els.append(_text(title, left, y, tw, PIE_TITLE_FONT, "left", [],
                               family=PIE_TITLE_FONT_FAMILY))

    return circle + wedges + leaders + labels + title_els
