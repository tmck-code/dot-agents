"""mermaid `sequenceDiagram` -> Excalidraw lifelines and messages.

Styling was reverse-engineered from a conversion of this skill's own example
diagram made by Excalidraw's *own* mermaid importer (`sequence.excalidraw`):
grey-filled participant headers (top only, no footer row), thin `#868e96`
lifelines, horizontal 2-point arrows with bound labels, dashed `#fff9db`
notes, a background rectangle for `rect <colour>`, and dashed `#868e96`
rectangle frames with a keyword tab for `par`/`loop`/`alt`/`opt`.

Three things that reference gets wrong are deliberately *not* reproduced: it
keeps `<br/>` as literal text (here it becomes a real newline), it drops
`autonumber` entirely (here it prefixes the label), and it renders `-x` with a
plain arrowhead (Excalidraw has no cross head, so that one is unavoidable and
is documented as a limitation instead).

Imported by convert.py; not meant to be run directly.
"""
import math
import re

from convert import _base, new_id  # noqa: E402  (sibling module)
from flowchart import clean_label  # noqa: E402  (`<br/>` -> newline, entities)

# the participant "legend" rows top and bottom keep the reference's Excalifont;
# everything drawn between them is Comic Shanns, as elsewhere in this skill
SEQ_LEGEND_FONT_FAMILY = 5   # Excalifont
SEQ_FONT_FAMILY = 8          # Comic Shanns
SEQ_FONT = 16.0              # headers, message labels, notes, keyword tabs
SEQ_TITLE_FONT = 20.0        # actor names and block branch descriptions
SEQ_LINE_H = 1.25
SEQ_CHAR_W = 0.58            # * font size, the wider Comic Shanns face (as in
                             # flowchart.py); the reference's 0.55 was Excalifont
                             # and left message labels crowding the lifelines

SEQ_LABEL_FONT = 12          # message labels (bound to their arrow)
SEQ_LABEL_CHAR_W = 0.6       # * font size: a Comic Shanns glyph's advance width
SEQ_LABEL_PAD_W = 6          # added to the text width for the label box
SEQ_MASK_PAD = 4.0           # lifelines stop this far short of a label box

SEQ_HEADER_H = 65.0          # a one-line participant header
SEQ_HEADER_LINE_H = 14.6     # each extra label line grows the box by this,
SEQ_HEADER_LINE_UP = 9.6     # of which this much is added above the band
SEQ_HEADER_MIN_W = 150.0
SEQ_HEADER_PAD_X = 36.0
SEQ_ACTOR_MARGIN = 50.0      # mermaid's actorMargin, the floor gutter
SEQ_LABEL_MARGIN = 70.0      # air a message label needs on top of its width

SEQ_GAP = 42.0               # vertical air between two stacked items
SEQ_MSG_H = 20.0             # a one-line message label
SEQ_MSG_LINE_H = 26.0        # each extra label line
SEQ_SELF_H = 60.0            # a self-message's minimum vertical footprint
SEQ_FOOTER_GAP = 20.0        # last item -> lifeline end (no footer row is drawn)

SEQ_NOTE_H = 42.0            # a one-line note
SEQ_NOTE_LINE_H = 28.75
SEQ_NOTE_OVERHANG = 25.0     # a two-party note overhangs each lifeline by this
SEQ_NOTE_PAD_X = 24.0        # total, both sides — the reference's 10 was sized
                             # for Excalifont and clips the wider Comic Shanns

SEQ_RECT_GAP = 10.0          # previous item -> a `rect` block's top edge
SEQ_RECT_PAD = 20.0          # `rect` block padding, top and bottom
SEQ_RECT_PAD_X = 10.0

SEQ_FRAME_GAP = 20.0         # previous item -> a block frame's top line
SEQ_FRAME_OVERHANG = 11.0    # frame edges sit this far outside the lifelines
SEQ_FRAME_INSET = 10.0       # * nesting depth, so nested frames stay distinct
SEQ_FRAME_TITLE_DY = 18.0    # top line (or divider) -> branch description
SEQ_FRAME_PAD_BOTTOM = 10.0
SEQ_DIVIDER_GAP = 11.0       # last item of a branch -> the next divider
SEQ_TAB_H = 59.7
SEQ_TAB_UP = 29.7            # how much of the tab sits above the top line
SEQ_TAB_MIN_W = 35.0
SEQ_TAB_PAD_X = 12.0
SEQ_TAB_CLEAR = 8.0           # tab's right edge to the lifeline

SEQ_ARROW_START = 1.5        # a message leaves its source lifeline by this,
SEQ_ARROW_END = 4.5          # and stops this far short of the target's
SEQ_SELF_POINTS = [[0.0, 0.0], [60.5, -9.5], [60.5, 30.5], [1.0, 21.0]]
SEQ_SELF_LABEL_DX = 76.0
SEQ_SELF_LABEL_DY = 10.49
SEQ_SELF_MARGIN = 90.0       # gutter a self-message's label needs to its right

SEQ_HEADER_STROKE = "#868e96"
SEQ_HEADER_FILL = "#f1f3f5"
SEQ_LIFELINE = "#868e96"
SEQ_NOTE_FILL = "#fff9db"
SEQ_FRAME_STROKE = "#868e96"
SEQ_TAB_FILL = "#f1f3f5"
SEQ_TEXT = "#868e96"   # free text, arrows, unfilled strokes
SEQ_LABEL_TEXT = "#1e1e1e"   # text inside filled shapes

# actor stick figure, all offsets from (cx, band_top)
SEQ_ACTOR_HEAD = 30.0
SEQ_ACTOR_HEAD_DY = -5.0
SEQ_ACTOR_BODY_DY = 25.0
SEQ_ACTOR_ARM_DY = 33.0
SEQ_ACTOR_ARM_W = 36.0
SEQ_ACTOR_HIP_DY = 45.0
SEQ_ACTOR_FOOT_DY = 60.0
SEQ_ACTOR_NAME_DY = 67.5
SEQ_ACTOR_LIFELINE_DY = 98.0

DIRECTIVE_RE = re.compile(r'^sequenceDiagram\b')
AUTONUMBER_RE = re.compile(r'^autonumber\b')
PARTICIPANT_RE = re.compile(r'^(participant|actor)\s+(\S+?)(?:\s+as\s+(.+?))?\s*$')
ACTIVATION_RE = re.compile(r'^(activate|deactivate)\s+\S+\s*$')
NOTE_RE = re.compile(r'^[Nn]ote\s+(over|left of|right of)\s+([^:]+?)\s*:\s*(.*)$')
RECT_RE = re.compile(r'^rect\s+(.+?)\s*$')
BLOCK_RE = re.compile(r'^(par|loop|alt|opt)\b\s*(.*?)\s*$')
BRANCH_RE = re.compile(r'^(and|else)\b\s*(.*?)\s*$')
END_RE = re.compile(r'^end\s*$')
ARROW_RE = re.compile(r'--?>>|--?>|--?x|--?\)')


class Participant:
    def __init__(self, pid, label, is_actor, index):
        self.id = pid
        self.label = label
        self.is_actor = is_actor
        self.index = index
        self.lines = label.split("\n")
        self.anchor_id = new_id()   # header rect, or the actor's head ellipse
        self.width = SEQ_HEADER_MIN_W
        self.cx = 0.0
        self.bound = []             # ids of arrows touching this participant


class Block:
    """A `par`/`loop`/`alt`/`opt`/`rect` container of branches of events."""

    def __init__(self, kind, colour=None):
        self.kind = kind
        self.colour = colour
        self.branches = []   # [(description, [events])]

    def add_branch(self, description):
        self.branches.append((description, []))
        return self.branches[-1][1]


def text_size(text, font):
    lines = text.split("\n") or [""]
    return (max(len(l) for l in lines) * font * SEQ_CHAR_W,
            len(lines) * font * SEQ_LINE_H)


def label_size(text, font=SEQ_LABEL_FONT):
    """(width, height) of a message label box: ceil(chars * font * 0.6) + 6."""
    lines = text.split("\n")
    width = math.ceil(max(len(l) for l in lines) * font * SEQ_LABEL_CHAR_W)
    return width + SEQ_LABEL_PAD_W, math.ceil(font * SEQ_LINE_H) * len(lines)


def wrap_text(text, width, font):
    """Greedy word-wrap to whatever fits `width`, preserving explicit newlines."""
    limit = max(1, int(width / (font * SEQ_CHAR_W)))
    out = []
    for para in text.split("\n"):
        line = ""
        for word in para.split():
            candidate = f"{line} {word}".strip()
            if line and len(candidate) > limit:
                out.append(line)
                line = word
            else:
                line = candidate
        out.append(line)
    return "\n".join(out)


# --- parsing -----------------------------------------------------------

def parse_sequence(text):
    """Return (participants, root_events, autonumber).

    `root_events` is a tree: messages and notes are leaves, blocks hold
    branches of further events, so nesting falls out of the walk in layout.
    """
    parts = {}
    order = []
    root = []
    stack = []           # [(Block, events_list)]
    autonumber = False

    def ensure(pid, label=None, is_actor=False):
        pid = pid.strip()
        if pid not in parts:
            parts[pid] = Participant(pid, clean_label(label or pid), is_actor,
                                     len(order))
            order.append(parts[pid])
        elif label:
            parts[pid].label = clean_label(label)
            parts[pid].lines = parts[pid].label.split("\n")
        return parts[pid]

    for raw in text.splitlines():
        line = raw.split("%%", 1)[0].strip()
        if not line or DIRECTIVE_RE.match(line):
            continue
        events = stack[-1][1] if stack else root

        if AUTONUMBER_RE.match(line):
            autonumber = True
            continue
        if ACTIVATION_RE.match(line):
            continue  # activation bars are parsed and ignored
        m = PARTICIPANT_RE.match(line)
        if m:
            ensure(m.group(2), m.group(3), m.group(1) == "actor")
            continue
        m = NOTE_RE.match(line)
        if m:
            targets = [ensure(p) for p in m.group(2).split(",")]
            events.append(("note", m.group(1), targets, clean_label(m.group(3))))
            continue
        m = RECT_RE.match(line)
        if m:
            block = Block("rect", m.group(1))
            events.append(("block", block))
            stack.append((block, block.add_branch("")))
            continue
        m = BLOCK_RE.match(line)
        if m:
            block = Block(m.group(1))
            events.append(("block", block))
            stack.append((block, block.add_branch(m.group(2))))
            continue
        m = BRANCH_RE.match(line)
        if m and stack:
            block = stack[-1][0]
            stack[-1] = (block, block.add_branch(m.group(2)))
            continue
        if END_RE.match(line):
            if stack:
                stack.pop()
            continue
        event = _parse_message(line, ensure)
        if event:
            events.append(event)

    if not order:
        raise ValueError("sequence diagram has no participants")
    return order, root, autonumber


def _parse_message(line, ensure):
    """`A->>+B: label` -> ("msg", src, dst, dotted, label), or None."""
    m = ARROW_RE.search(line)
    if not m:
        return None
    src = line[:m.start()].strip()
    rest = line[m.end():]
    dst, _, label = rest.partition(":")
    dst = dst.strip().lstrip("+-").strip()   # activation suffixes are ignored
    if not src or not dst:
        return None
    dotted = m.group(0).startswith("--")
    return ("msg", ensure(src), ensure(dst), dotted, clean_label(label.strip()))


# --- horizontal layout -------------------------------------------------

def _collect_spans(events, spans, n):
    """Gather (first_gutter, last_gutter+1, minimum_span) width constraints."""
    for event in events:
        if event[0] == "msg":
            _, src, dst, _, label = event
            width = label_size(label)[0] if label else 0.0
            if src is dst:
                if src.index < n - 1:
                    spans.append((src.index, src.index + 1,
                                  width + SEQ_SELF_MARGIN))
            else:
                lo, hi = sorted((src.index, dst.index))
                spans.append((lo, hi, width + SEQ_LABEL_MARGIN))
        elif event[0] == "note":
            _, placement, targets, body = event
            width = text_size(body, SEQ_FONT)[0]
            idx = [p.index for p in targets]
            if placement == "over" and len(idx) > 1:
                # the box is span + 2 * overhang wide, and must hold the text
                spans.append((min(idx), max(idx),
                              width + SEQ_NOTE_PAD_X - 2 * SEQ_NOTE_OVERHANG))
            else:
                half = width / 2 + SEQ_NOTE_OVERHANG
                if idx[0] > 0:
                    spans.append((idx[0] - 1, idx[0], half))
                if idx[0] < n - 1:
                    spans.append((idx[0], idx[0] + 1, half))
        elif event[0] == "block":
            for _, branch in event[1].branches:
                _collect_spans(branch, spans, n)


def _layout_columns(order, root):
    for part in order:
        width = max(text_size(l, SEQ_FONT)[0] for l in part.lines)
        part.width = max(SEQ_HEADER_MIN_W, width + SEQ_HEADER_PAD_X)
        if part.is_actor:
            name_w = text_size(part.label, SEQ_TITLE_FONT)[0]
            part.width = max(part.width, name_w + SEQ_HEADER_PAD_X)

    n = len(order)
    gaps = [order[i].width / 2 + order[i + 1].width / 2 + SEQ_ACTOR_MARGIN
            for i in range(n - 1)]
    spans = []
    _collect_spans(root, spans, n)

    # widen the gutters a wide label crosses, proportionally, until every
    # label fits the span it has to cross; constraints interact, so iterate
    for _ in range(8):
        settled = True
        for lo, hi, need in spans:
            if lo >= hi:
                continue
            have = sum(gaps[lo:hi])
            if need <= have + 0.01:
                continue
            extra = need - have
            for k in range(lo, hi):
                gaps[k] += extra * gaps[k] / have
            settled = False
        if settled:
            break

    x = order[0].width / 2
    order[0].cx = x
    for i, gap in enumerate(gaps):
        x += gap
        order[i + 1].cx = x


# --- element helpers ---------------------------------------------------

def _text(text, x, y, width, font, align="center", valign="middle",
          color=SEQ_TEXT, container=None, family=SEQ_FONT_FAMILY):
    lines = text.count("\n") + 1
    return _base(
        new_id(), "text", x, y, width, math.ceil(font * SEQ_LINE_H * lines), [],
        strokeColor=color, backgroundColor="transparent", roughness=1,
        text=text, originalText=text, fontSize=font,
        fontFamily=family, textAlign=align, verticalAlign=valign,
        containerId=container, autoResize=True, lineHeight=SEQ_LINE_H,
    )


def _boxed(rect, text, font, color, family=SEQ_FONT_FAMILY):
    """Bind `text` centrally inside `rect`; returns [rect, text]."""
    lines = text.count("\n") + 1
    height = font * SEQ_LINE_H * lines
    label = _text(text, rect["x"], rect["y"] + (rect["height"] - height) / 2,
                  rect["width"], font, color=color, container=rect["id"],
                  family=family)
    rect["boundElements"] = (rect.get("boundElements") or []) + [
        {"type": "text", "id": label["id"]}]
    return [rect, label]


def _line(x, y, points, color, style="solid", width=1):
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    return _base(
        new_id(), "line", x, y, max(xs) - min(xs), max(ys) - min(ys), [],
        strokeColor=color, strokeWidth=width, strokeStyle=style, roughness=1,
        roundness={"type": 2}, points=points, lastCommittedPoint=None,
        startBinding=None, endBinding=None, startArrowhead=None,
        endArrowhead=None, polygon=False, boundElements=None,
    )


def _lifeline(cx, top, bottom, obstacles):
    """Vertical line segments from top to bottom, broken around label boxes."""
    cuts = sorted((y0, y1) for x0, x1, y0, y1 in obstacles if x0 < cx < x1)
    out = []
    y = top
    for y0, y1 in cuts:
        if y0 > y:
            out.append(_line(cx, y, [[0.0, 0.0], [0.0, y0 - y]], SEQ_LIFELINE))
        y = max(y, y1)
    out.append(_line(cx, y, [[0.0, 0.0], [0.0, bottom - y]], SEQ_LIFELINE))
    return out


def _header_geometry(part, band_top):
    lines = len(part.lines)
    height = SEQ_HEADER_H + SEQ_HEADER_LINE_H * (lines - 1)
    top = band_top - SEQ_HEADER_LINE_UP * (lines - 1)
    return top, height


def _header(part, band_top, anchor_id):
    top, height = _header_geometry(part, band_top)
    rect = _base(anchor_id, "rectangle", part.cx - part.width / 2, top,
                 part.width, height, [], strokeColor=SEQ_HEADER_STROKE,
                 backgroundColor=SEQ_HEADER_FILL, strokeWidth=2, roughness=1,
                 roundness={"type": 3})
    return _boxed(rect, part.label, SEQ_FONT, SEQ_LABEL_TEXT,
                  family=SEQ_LEGEND_FONT_FAMILY)


def _actor(part, band_top, anchor_id):
    cx = part.cx
    group = [new_id()]
    head = _base(anchor_id, "ellipse", cx - SEQ_ACTOR_HEAD / 2,
                 band_top + SEQ_ACTOR_HEAD_DY, SEQ_ACTOR_HEAD, SEQ_ACTOR_HEAD,
                 group, strokeColor=SEQ_TEXT, strokeWidth=2, roughness=1)
    half = SEQ_ACTOR_ARM_W / 2
    strokes = [
        (cx, band_top + SEQ_ACTOR_BODY_DY, [[0.0, 0.0], [0.0, 20.0]]),
        (cx - half, band_top + SEQ_ACTOR_ARM_DY,
         [[0.0, 0.0], [SEQ_ACTOR_ARM_W, 0.0]]),
        (cx - half, band_top + SEQ_ACTOR_FOOT_DY,
         [[0.0, 0.0], [half, SEQ_ACTOR_HIP_DY - SEQ_ACTOR_FOOT_DY]]),
        (cx, band_top + SEQ_ACTOR_HIP_DY,
         [[0.0, 0.0], [half - 2.0, SEQ_ACTOR_FOOT_DY - SEQ_ACTOR_HIP_DY]]),
    ]
    els = [head]
    for x, y, points in strokes:
        el = _line(x, y, points, SEQ_TEXT)
        el["groupIds"] = group
        els.append(el)
    name_w = text_size(part.label, SEQ_TITLE_FONT)[0]
    name = _text(part.label, cx - name_w / 2, band_top + SEQ_ACTOR_NAME_DY,
                 name_w, SEQ_TITLE_FONT, align="left", valign="top",
                 family=SEQ_LEGEND_FONT_FAMILY)
    name["groupIds"] = group
    els.append(name)
    return els


# --- vertical walk -----------------------------------------------------

class Layout:
    """Buckets of elements, filled in during the recursive walk over events."""

    def __init__(self, order, autonumber):
        self.order = order
        self.autonumber = autonumber
        self.counter = 0
        self.backgrounds = []
        self.notes = []
        self.messages = []
        self.frames = []
        self.tabs = []
        self.obstacles = []   # (x0, x1, y0, y1) boxes lifelines must not cross
        self.extents = []   # stack of open containers
        self.depth = 0      # block-frame nesting depth

    def mark(self, x0, x1, *parts):
        for frame in self.extents:
            frame["x0"] = min(frame["x0"], x0)
            frame["x1"] = max(frame["x1"], x1)
            for part in parts:
                frame["lo"] = min(frame["lo"], part.index)
                frame["hi"] = max(frame["hi"], part.index)

    def number(self, label):
        self.counter += 1
        return f"{self.counter}. {label}" if self.autonumber and label else label


def _walk(events, cursor, ctx):
    for event in events:
        if event[0] == "msg":
            cursor = _place_message(event, cursor, ctx)
        elif event[0] == "note":
            cursor = _place_note(event, cursor, ctx)
        elif event[0] == "block":
            block = event[1]
            if block.kind == "rect":
                cursor = _place_rect(block, cursor, ctx)
            else:
                cursor = _place_frame(block, cursor, ctx)
    return cursor


def _place_message(event, cursor, ctx):
    _, src, dst, dotted, label = event
    label = ctx.number(label)
    lines = label.count("\n") + 1 if label else 1
    style = "dashed" if dotted else "solid"
    top = cursor + SEQ_GAP

    if src is dst:
        y = top + 9.5
        arrow = _base(
            new_id(), "arrow", src.cx + 0.5, y, 60.5, 40.0, [],
            strokeColor=SEQ_TEXT, strokeWidth=2, strokeStyle=style,
            roughness=1, roundness={"type": 2},
            points=[list(p) for p in SEQ_SELF_POINTS], lastCommittedPoint=None,
            startBinding={"elementId": src.anchor_id},
            endBinding={"elementId": src.anchor_id},
            startArrowhead=None, endArrowhead="triangle", elbowed=False,
        )
        ctx.messages.append(arrow)
        src.bound.append(arrow["id"])
        width = 0.0
        if label:
            # a bound label would be re-centred on the loop's far edge and sit
            # on the arrow, so a self-message label is free text to its right
            width, height = label_size(label)
            text = _text(label, src.cx + SEQ_SELF_LABEL_DX,
                         y + SEQ_SELF_LABEL_DY + 10 - height / 2, width,
                         SEQ_LABEL_FONT, align="left")
            ctx.messages.append(text)
        ctx.mark(src.cx, src.cx + SEQ_SELF_LABEL_DX + width, src)
        return top + max(SEQ_SELF_H, SEQ_MSG_H * (lines + 1))

    height = SEQ_MSG_H + SEQ_MSG_LINE_H * (lines - 1)
    y = top + height - SEQ_MSG_H / 2
    step = 1.0 if dst.cx > src.cx else -1.0
    x0 = src.cx + step * SEQ_ARROW_START
    x1 = dst.cx - step * SEQ_ARROW_END
    arrow = _base(
        new_id(), "arrow", x0, y, abs(x1 - x0), 0.0, [],
        strokeColor=SEQ_TEXT, strokeWidth=2, strokeStyle=style, roughness=1,
        roundness={"type": 2}, points=[[0.0, 0.0], [x1 - x0, 0.0]],
        lastCommittedPoint=None,
        startBinding={"elementId": src.anchor_id},
        endBinding={"elementId": dst.anchor_id},
        startArrowhead=None, endArrowhead="triangle", elbowed=False,
    )
    ctx.messages.append(arrow)
    src.bound.append(arrow["id"])
    dst.bound.append(arrow["id"])
    if label:
        width, height = label_size(label)
        mid = (x0 + x1) / 2
        text = _text(label, mid - width / 2, y - height / 2, width,
                     SEQ_LABEL_FONT, container=arrow["id"])
        text["height"] = height
        arrow["boundElements"] = [{"type": "text", "id": text["id"]}]
        ctx.messages.append(text)
        ctx.obstacles.append((mid - width / 2 - SEQ_MASK_PAD,
                              mid + width / 2 + SEQ_MASK_PAD,
                              y - height / 2, y + height / 2))
    ctx.mark(min(x0, x1), max(x0, x1), src, dst)
    return y + SEQ_MSG_H / 2


def _place_note(event, cursor, ctx):
    _, placement, targets, body = event
    raw_w = text_size(body, SEQ_FONT)[0]
    first = targets[0]
    if placement == "over" and len(targets) > 1:
        lo = min(p.cx for p in targets)
        hi = max(p.cx for p in targets)
        width = hi - lo + 2 * SEQ_NOTE_OVERHANG
        x = lo - SEQ_NOTE_OVERHANG
    else:
        width = max(SEQ_HEADER_MIN_W, raw_w + SEQ_NOTE_PAD_X)
        if placement == "left of":
            x = first.cx - SEQ_NOTE_OVERHANG - width
        elif placement == "right of":
            x = first.cx + SEQ_NOTE_OVERHANG
        else:
            x = first.cx - width / 2

    body = wrap_text(body, width - SEQ_NOTE_PAD_X, SEQ_FONT)
    lines = body.count("\n") + 1
    height = SEQ_NOTE_H + SEQ_NOTE_LINE_H * (lines - 1)
    top = cursor + SEQ_GAP
    rect = _base(new_id(), "rectangle", x, top, width, height, [],
                 strokeColor=SEQ_HEADER_STROKE, backgroundColor=SEQ_NOTE_FILL,
                 strokeWidth=2, strokeStyle="dashed", roughness=1,
                 roundness={"type": 3})
    ctx.notes.extend(_boxed(rect, body, SEQ_FONT, SEQ_LABEL_TEXT))
    ctx.mark(x, x + width, *targets)
    return top + height


def _place_rect(block, cursor, ctx):
    top = cursor + SEQ_RECT_GAP
    frame = {"x0": float("inf"), "x1": float("-inf"),
             "lo": len(ctx.order), "hi": -1}
    ctx.extents.append(frame)
    # the first inner item lands SEQ_RECT_PAD below the top edge
    inner = _walk(block.branches[0][1], top + SEQ_RECT_PAD - SEQ_GAP, ctx)
    ctx.extents.pop()
    bottom = inner + SEQ_RECT_PAD
    if frame["hi"] < 0:
        return bottom
    x0 = frame["x0"] - SEQ_RECT_PAD_X
    x1 = frame["x1"] + SEQ_RECT_PAD_X
    background = _base(new_id(), "rectangle", x0, top, x1 - x0, bottom - top,
                       [], strokeColor=SEQ_TEXT, backgroundColor=block.colour,
                       strokeWidth=2, roughness=1, roundness={"type": 3})
    # nested blocks close first, so insert at the front to keep an outer
    # background *below* the inner one it contains
    ctx.backgrounds.insert(0, background)
    ctx.mark(x0, x1)
    return bottom


def _place_frame(block, cursor, ctx):
    top = cursor + SEQ_FRAME_GAP
    frame = {"x0": float("inf"), "x1": float("-inf"),
             "lo": len(ctx.order), "hi": -1}
    ctx.extents.append(frame)
    ctx.depth += 1
    branch_tops = []
    inner = top
    for index, (_, branch) in enumerate(block.branches):
        branch_top = top if index == 0 else inner + SEQ_DIVIDER_GAP
        branch_tops.append(branch_top)
        title_h = SEQ_TITLE_FONT * SEQ_LINE_H
        inner = _walk(branch, branch_top + SEQ_FRAME_TITLE_DY + title_h, ctx)
    ctx.depth -= 1
    ctx.extents.pop()
    bottom = inner + SEQ_FRAME_PAD_BOTTOM

    # a nested frame is inset, so its edges never sit exactly on its parent's
    inset = SEQ_FRAME_OVERHANG - SEQ_FRAME_INSET * min(ctx.depth, 2)
    lo = max(0, min(frame["lo"], len(ctx.order) - 1))
    hi = max(frame["hi"], lo)
    tab_w = max(SEQ_TAB_MIN_W,
                text_size(block.kind, SEQ_FONT)[0] + SEQ_TAB_PAD_X)
    # the tab hangs off the left edge, so keep it clear of the lifeline there
    x0 = ctx.order[lo].cx - max(inset, tab_w + SEQ_TAB_CLEAR)
    x1 = ctx.order[hi].cx + inset
    width = x1 - x0
    ctx.frames.append(_base(
        new_id(), "rectangle", x0, top, width, bottom - top, [],
        strokeColor=SEQ_FRAME_STROKE, backgroundColor="transparent",
        strokeWidth=2, strokeStyle="dashed", roughness=1,
        roundness={"type": 3}))

    for index, (description, _) in enumerate(block.branches):
        branch_top = branch_tops[index]
        if index:
            ctx.frames.append(_line(x0, branch_top, [[0.0, 0.0], [width, 0.0]],
                                    SEQ_FRAME_STROKE, "dashed", 2))
        if not description:
            continue
        caption = f"[{description}]"
        caption_w = text_size(caption, SEQ_TITLE_FONT)[0]
        ctx.obstacles.append(((x0 + x1) / 2 - caption_w / 2 - SEQ_MASK_PAD,
                              (x0 + x1) / 2 + caption_w / 2 + SEQ_MASK_PAD,
                              branch_top + SEQ_FRAME_TITLE_DY,
                              branch_top + SEQ_FRAME_TITLE_DY
                              + SEQ_TITLE_FONT * SEQ_LINE_H))
        ctx.frames.append(_text(
            caption, (x0 + x1) / 2 - caption_w / 2,
            branch_top + SEQ_FRAME_TITLE_DY, caption_w, SEQ_TITLE_FONT,
            align="left", valign="top"))

    tab = _base(new_id(), "rectangle", x0, top - SEQ_TAB_UP, tab_w, SEQ_TAB_H,
                [], strokeColor=SEQ_FRAME_STROKE, backgroundColor=SEQ_TAB_FILL,
                strokeWidth=2, roughness=1, roundness={"type": 3})
    ctx.tabs.extend(_boxed(tab, block.kind, SEQ_FONT, SEQ_LABEL_TEXT))
    ctx.mark(x0, x1)
    return bottom


# --- entry point -------------------------------------------------------

def convert_sequence(mermaid_text):
    order, root, autonumber = parse_sequence(mermaid_text)
    _layout_columns(order, root)

    band_top = 0.0
    ctx = Layout(order, autonumber)
    cursor = _walk(root, SEQ_HEADER_H, ctx)
    footer_top = cursor + SEQ_FOOTER_GAP

    headers, actors, lifelines = [], [], []
    for part in order:
        if part.is_actor:
            actors.extend(_actor(part, band_top, part.anchor_id))
            top = band_top + SEQ_ACTOR_LIFELINE_DY
            bottom = footer_top
        else:
            headers.extend(_header(part, band_top, part.anchor_id))
            top = band_top + SEQ_HEADER_H
            bottom = footer_top
        lifelines.extend(_lifeline(part.cx, top, bottom, ctx.obstacles))
        if part.bound:
            headers_by_id = {e["id"]: e for e in headers + actors}
            anchor = headers_by_id[part.anchor_id]
            anchor["boundElements"] = (anchor.get("boundElements") or []) + [
                {"type": "arrow", "id": aid} for aid in part.bound]

    # bottom-to-top: block backgrounds, notes,
    # lifelines, messages, frames, actor figures, top headers, tabs
    return (ctx.backgrounds + lifelines + ctx.notes + ctx.messages
            + ctx.frames + actors + headers + ctx.tabs)
