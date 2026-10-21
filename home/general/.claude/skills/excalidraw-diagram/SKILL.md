---
name: excalidraw-diagram
description: Create Excalidraw diagram JSON files that make visual arguments. Use when the user wants to visualize workflows, architectures, or concepts.
---

# Excalidraw Diagram Creator

Generate `.excalidraw` JSON files that **argue visually**, not just display information.

**Setup:** If the user asks you to set up this skill (renderer, dependencies, etc.), see `README.md` for instructions.

## Customization

**All colors and brand-specific styles live in one file:** `references/color-palette.md`. Read it before generating any diagram and use it as the single source of truth for all color choices — shape fills, strokes, text colors, evidence artifact backgrounds, everything.

To make this skill produce diagrams in your own brand style, edit `color-palette.md`. Everything else in this file is universal design methodology and Excalidraw best practices.

---

## Core Philosophy

**Diagrams should ARGUE, not DISPLAY.**

A diagram isn't formatted text. It's a visual argument that shows relationships, causality, and flow that words alone can't express. The shape should BE the meaning.

**The Isomorphism Test**: If you removed all text, would the structure alone communicate the concept? If not, redesign.

**The Education Test**: Could someone learn something concrete from this diagram, or does it just label boxes? A good diagram teaches—it shows actual formats, real event names, concrete examples.

---

## Depth Assessment (Do This First)

Before designing, determine what level of detail this diagram needs:

### Simple/Conceptual Diagrams
Use abstract shapes when:
- Explaining a mental model or philosophy
- The audience doesn't need technical specifics
- The concept IS the abstraction (e.g., "separation of concerns")

### Comprehensive/Technical Diagrams
Use concrete examples when:
- Diagramming a real system, protocol, or architecture
- The diagram will be used to teach or explain (e.g., YouTube video)
- The audience needs to understand what things actually look like
- You're showing how multiple technologies integrate

**For technical diagrams, you MUST include evidence artifacts** (see below).

---

## Research Mandate (For Technical Diagrams)

**Before drawing anything technical, research the actual specifications.**

If you're diagramming a protocol, API, or framework:
1. Look up the actual JSON/data formats
2. Find the real event names, method names, or API endpoints
3. Understand how the pieces actually connect
4. Use real terminology, not generic placeholders

Bad: "Protocol" → "Frontend"
Good: "AG-UI streams events (RUN_STARTED, STATE_DELTA, A2UI_UPDATE)" → "CopilotKit renders via createA2UIMessageRenderer()"

**Research makes diagrams accurate AND educational.**

---

## Evidence Artifacts

Evidence artifacts are concrete examples that prove your diagram is accurate and help viewers learn. Include them in technical diagrams.

**Types of evidence artifacts** (choose what's relevant to your diagram):

| Artifact Type | When to Use | How to Render |
|---------------|-------------|---------------|
| **Code snippets** | APIs, integrations, implementation details | Dark rectangle + syntax-colored text (see color palette for evidence artifact colors) |
| **Data/JSON examples** | Data formats, schemas, payloads | Dark rectangle + colored text (see color palette) |
| **Event/step sequences** | Protocols, workflows, lifecycles | Timeline pattern (line + dots + labels) |
| **UI mockups** | Showing actual output/results | Nested rectangles mimicking real UI |
| **Real input content** | Showing what goes IN to a system | Rectangle with sample content visible |
| **API/method names** | Real function calls, endpoints | Use actual names from docs, not placeholders |

**Example**: For a diagram about a streaming protocol, you might show:
- The actual event names from the spec (not just "Event 1", "Event 2")
- A code snippet showing how to connect
- What the streamed data actually looks like

**Example**: For a diagram about a data transformation pipeline:
- Show sample input data (actual format, not "Input")
- Show sample output data (actual format, not "Output")
- Show intermediate states if relevant

The key principle: **show what things actually look like**, not just what they're called.

---

## Multi-Zoom Architecture

Comprehensive diagrams operate at multiple zoom levels simultaneously. Think of it like a map that shows both the country borders AND the street names.

### Level 1: Summary Flow
A simplified overview showing the full pipeline or process at a glance. Often placed at the top or bottom of the diagram.

*Example*: `Input → Processing → Output` or `Client → Server → Database`

### Level 2: Section Boundaries
Labeled regions that group related components. These create visual "rooms" that help viewers understand what belongs together.

*Example*: Grouping by responsibility (Backend / Frontend), by phase (Setup / Execution / Cleanup), or by team (User / System / External)

### Level 3: Detail Inside Sections
Evidence artifacts, code snippets, and concrete examples within each section. This is where the educational value lives.

*Example*: Inside a "Backend" section, you might show the actual API response format, not just a box labeled "API Response"

**For comprehensive diagrams, aim to include all three levels.** The summary gives context, the sections organize, and the details teach.

### Bad vs Good

| Bad (Displaying) | Good (Arguing) |
|------------------|----------------|
| 5 equal boxes with labels | Each concept has a shape that mirrors its behavior |
| Card grid layout | Visual structure matches conceptual structure |
| Icons decorating text | Shapes that ARE the meaning |
| Same container for everything | Distinct visual vocabulary per concept |
| Everything in a box | Free-floating text with selective containers |

### Simple vs Comprehensive (Know Which You Need)

| Simple Diagram | Comprehensive Diagram |
|----------------|----------------------|
| Generic labels: "Input" → "Process" → "Output" | Specific: shows what the input/output actually looks like |
| Named boxes: "API", "Database", "Client" | Named boxes + examples of actual requests/responses |
| "Events" or "Messages" label | Timeline with real event/message names from the spec |
| "UI" or "Dashboard" rectangle | Mockup showing actual UI elements and content |
| ~30 seconds to explain | ~2-3 minutes of teaching content |
| Viewer learns the structure | Viewer learns the structure AND the details |

**Simple diagrams** are fine for abstract concepts, quick overviews, or when the audience already knows the details. **Comprehensive diagrams** are needed for technical architectures, tutorials, educational content, or when you want the diagram itself to teach.

---

## Container vs. Free-Floating Text

**Not every piece of text needs a shape around it.** Default to free-floating text. Add containers only when they serve a purpose.

| Use a Container When... | Use Free-Floating Text When... |
|------------------------|-------------------------------|
| It's the focal point of a section | It's a label or description |
| It needs visual grouping with other elements | It's supporting detail or metadata |
| Arrows need to connect to it | It describes something nearby |
| The shape itself carries meaning (decision diamond, etc.) | Typography alone creates sufficient hierarchy |
| It represents a distinct "thing" in the system | It's a section title, subtitle, or annotation |

**Typography as hierarchy**: Use font size, weight, and color to create visual hierarchy without boxes. A 28px title doesn't need a rectangle around it.

**The container test**: For each boxed element, ask "Would this work as free-floating text?" If yes, remove the container.

---

## Design Process (Do This BEFORE Generating JSON)

### Step 0: Assess Depth Required
Before anything else, determine if this needs to be:
- **Simple/Conceptual**: Abstract shapes, labels, relationships (mental models, philosophies)
- **Comprehensive/Technical**: Concrete examples, code snippets, real data (systems, architectures, tutorials)

**If comprehensive**: Do research first. Look up actual specs, formats, event names, APIs.

### Step 1: Understand Deeply
Read the content. For each concept, ask:
- What does this concept **DO**? (not what IS it)
- What relationships exist between concepts?
- What's the core transformation or flow?
- **What would someone need to SEE to understand this?** (not just read about)

### Step 2: Map Concepts to Patterns
For each concept, find the visual pattern that mirrors its behavior:

| If the concept... | Use this pattern |
|-------------------|------------------|
| Spawns multiple outputs | **Fan-out** (radial arrows from center) |
| Combines inputs into one | **Convergence** (funnel, arrows merging) |
| Has hierarchy/nesting | **Tree** (lines + free-floating text) |
| Is a sequence of steps | **Timeline** (line + dots + free-floating labels) |
| Loops or improves continuously | **Spiral/Cycle** (arrow returning to start) |
| Is an abstract state or context | **Cloud** (overlapping ellipses) |
| Transforms input to output | **Assembly line** (before → process → after) |
| Compares two things | **Side-by-side** (parallel with contrast) |
| Separates into phases | **Gap/Break** (visual separation between sections) |

### Step 3: Ensure Variety
For multi-concept diagrams: **each major concept must use a different visual pattern**. No uniform cards or grids.

### Step 4: Sketch the Flow
Before JSON, mentally trace how the eye moves through the diagram. There should be a clear visual story.

### Step 5: Generate JSON
Only now create the Excalidraw elements. **See below for how to handle large diagrams.**

### Step 6: Render & Validate (MANDATORY)
After generating the JSON, you MUST run the render-view-fix loop until the diagram looks right. This is not optional — see the **Render & Validate** section below for the full process.

---

## Large / Comprehensive Diagram Strategy

**For comprehensive or technical diagrams, you MUST build the JSON one section at a time.** Do NOT attempt to generate the entire file in a single pass. This is a hard constraint — Claude Code has a ~32,000 token output limit per response, and a comprehensive diagram easily exceeds that in one shot. Even if it didn't, generating everything at once leads to worse quality. Section-by-section is better in every way.

### The Section-by-Section Workflow

**Phase 1: Build each section**

1. **Create the base file** with the JSON wrapper (`type`, `version`, `appState`, `files`) and the first section of elements.
2. **Add one section per edit.** Each section gets its own dedicated pass — take your time with it. Think carefully about the layout, spacing, and how this section connects to what's already there.
3. **Use descriptive string IDs** (e.g., `"trigger_rect"`, `"arrow_fan_left"`) so cross-section references are readable.
4. **Namespace seeds by section** (e.g., section 1 uses 100xxx, section 2 uses 200xxx) to avoid collisions.
5. **Update cross-section bindings** as you go. When a new section's element needs to bind to an element from a previous section (e.g., an arrow connecting sections), edit the earlier element's `boundElements` array at the same time.

**Phase 2: Review the whole**

After all sections are in place, read through the complete JSON and check:
- Are cross-section arrows bound correctly on both ends?
- Is the overall spacing balanced, or are some sections cramped while others have too much whitespace?
- Do IDs and bindings all reference elements that actually exist?

Fix any alignment or binding issues before rendering.

**Phase 3: Render & validate**

Now run the render-view-fix loop from the Render & Validate section. This is where you'll catch visual issues that aren't obvious from JSON — overlaps, clipping, imbalanced composition.

### Section Boundaries

Plan your sections around natural visual groupings from the diagram plan. A typical large diagram might split into:

- **Section 1**: Entry point / trigger
- **Section 2**: First decision or routing
- **Section 3**: Main content (hero section — may be the largest single section)
- **Section 4-N**: Remaining phases, outputs, etc.

Each section should be independently understandable: its elements, internal arrows, and any cross-references to adjacent sections.

### What NOT to Do

- **Don't generate the entire diagram in one response.** You will hit the output token limit and produce truncated, broken JSON. Even if the diagram is small enough to fit, splitting into sections produces better results.
- **Don't use a coding agent** to generate the JSON. The agent won't have sufficient context about the skill's rules, and the coordination overhead negates any benefit.
- **Don't write a Python generator script.** The templating and coordinate math seem helpful but introduce a layer of indirection that makes debugging harder. Hand-crafted JSON with descriptive IDs is more maintainable.

---

## Visual Pattern Library

### Fan-Out (One-to-Many)
Central element with arrows radiating to multiple targets. Use for: sources, PRDs, root causes, central hubs.
```
        ○
       ↗
  □ → ○
       ↘
        ○
```

### Convergence (Many-to-One)
Multiple inputs merging through arrows to single output. Use for: aggregation, funnels, synthesis.
```
  ○ ↘
  ○ → □
  ○ ↗
```

### Tree (Hierarchy)
Parent-child branching with connecting lines and free-floating text (no boxes needed). Use for: file systems, org charts, taxonomies.
```
  label
  ├── label
  │   ├── label
  │   └── label
  └── label
```
Use `line` elements for the trunk and branches, free-floating text for labels.

### Spiral/Cycle (Continuous Loop)
Elements in sequence with arrow returning to start. Use for: feedback loops, iterative processes, evolution.
```
  □ → □
  ↑     ↓
  □ ← □
```

### Cloud (Abstract State)
Overlapping ellipses with varied sizes. Use for: context, memory, conversations, mental states.

### Assembly Line (Transformation)
Input → Process Box → Output with clear before/after. Use for: transformations, processing, conversion.
```
  ○○○ → [PROCESS] → □□□
  chaos              order
```

### Side-by-Side (Comparison)
Two parallel structures with visual contrast. Use for: before/after, options, trade-offs.

### Gap/Break (Separation)
Visual whitespace or barrier between sections. Use for: phase changes, context resets, boundaries.

### Lines as Structure
Use lines (type: `line`, not arrows) as primary structural elements instead of boxes:
- **Timelines**: Vertical or horizontal line with small dots (10-20px ellipses) at intervals, free-floating labels beside each dot
- **Tree structures**: Vertical trunk line + horizontal branch lines, with free-floating text labels (no boxes needed)
- **Dividers**: Thin dashed lines to separate sections
- **Flow spines**: A central line that elements relate to, rather than connecting boxes

```
Timeline:           Tree:
  ●─── Label 1        │
  │                   ├── item
  ●─── Label 2        │   ├── sub
  │                   │   └── sub
  ●─── Label 3        └── item
```

Lines + free-floating text often creates a cleaner result than boxes + contained text.

---

## Shape Meaning

Choose shape based on what it represents—or use no shape at all:

| Concept Type | Shape | Why |
|--------------|-------|-----|
| Labels, descriptions, details | **none** (free-floating text) | Typography creates hierarchy |
| Section titles, annotations | **none** (free-floating text) | Font size/weight is enough |
| Markers on a timeline | small `ellipse` (10-20px) | Visual anchor, not container |
| Start, trigger, input | `ellipse` | Soft, origin-like |
| End, output, result | `ellipse` | Completion, destination |
| Decision, condition | `diamond` | Classic decision symbol |
| Process, action, step | `rectangle` | Contained action |
| Abstract state, context | overlapping `ellipse` | Fuzzy, cloud-like |
| Hierarchy node | lines + text (no boxes) | Structure through lines |

**Rule**: Default to no container. Add shapes only when they carry meaning. Aim for <30% of text elements to be inside containers.

---

## Color as Meaning

Colors encode information, not decoration. Every color choice should come from `references/color-palette.md` — the semantic shape colors, text hierarchy colors, and evidence artifact colors are all defined there.

**Key principles:**
- Each semantic purpose (start, end, decision, AI, error, etc.) has a specific fill/stroke pair
- Free-floating text uses color for hierarchy (titles, subtitles, details — each at a different level)
- Evidence artifacts (code snippets, JSON examples) use their own dark background + colored text scheme
- Always pair a darker stroke with a lighter fill for contrast

Each pair also has a paler Secondary fill in `references/color-palette.md`. Use it for less important nodes of the same concept instead of a new hue.

Colors are Open Color pastel fills with darker strokes. `references/color-palette.md` has the hex values. Diagrams must work on light and dark pages, so:
- No pure black or pure white fills.
- Free text, arrow strokes, arrow labels, frame outlines and unfilled containers use `#868e96`.
- Text inside a filled shape uses `#1e1e1e`.

**Do not invent new colors.** If a concept doesn't fit an existing semantic category, use Primary/Neutral or Secondary.

---

## Flowchart House Style (Lexer)

Derived from the user's hand-edit pass on "Identity resolution — bird's-eye
pipeline" (`AGdGHYQB3tL`). Apply to any diagram with boxes/ovals connected by
arrows — flowcharts, ER diagrams, sequence/state/class diagrams. Does not
apply to pure charts (pie, xychart-beta) or mindmaps.

- **Arrows**: elbow arrows by default (`elbowed: true`; use a straight arrow
  only when the route is a single straight run). `strokeColor: "#868e96"`,
  `strokeWidth: 2`, `strokeStyle: "solid"`, `startArrowhead: null`,
  `endArrowhead: "triangle"`. Use `strokeStyle: "dashed"` (same head) for
  return paths, loop-backs and optional or async flows. Keep solid for the
  main path.
- **Arrow labels**: bind the label to its arrow. Set the text's `containerId`
  to the arrow id and list the text in the arrow's `boundElements`. Size the
  label box to the text (`width = ceil(chars * fontSize * 0.6) + 6`,
  `height = ceil(fontSize * 1.25)`) and centre it on the arrow midpoint, or the
  line shows through the text. Label
  color is `#868e96`. Put qualifiers (conditions, rule names) here, not in
  the target box.
- **Rounded corners**: every rectangle has `roundness: {"type": 3}`.
- **Group containers**: thin dashed grey outline (`strokeStyle: "dashed"`,
  `strokeColor: "#868e96"`, `strokeWidth: 1`, `backgroundColor: "transparent"`),
  not a filled lane or group box.
- **Every arrow must be bound on both ends** — real `startBinding`/`endBinding`
  objects with a `fixedPoint` tuple and `mode` (`"orbit"` for arrows
  approaching a shape from outside; `"inside"` when the endpoint lands inside/
  overlapping the target, e.g. a label box nested in a larger box). Leave a
  6 px gap between the arrow end and the shape. No floating arrow endpoints,
  no arrows merely positioned near a shape.
- **Background/async job boxes** (a Databricks job, a queue worker, any
  "runs later / not inline" process box): use a dashed stroke on a palette
  fill. Do not use a black or dark fill.
- **Offset shadow**: `scripts/shadow.py` exposes
  `add_shadows(elements, offset=6, opacity=80) -> list`. CLI:
  `python3 -I scripts/shadow.py in.excalidraw out.excalidraw [--offset 6] [--opacity 80]`.
  Rule: a rectangle, diamond or ellipse gets a shadow when its fill is not
  transparent, its stroke is solid, it is not a 26x20 legend swatch, and it has
  a bound text child or `customData.shadow: true`. Set `customData.shadow: false`
  to opt out. Each shadow carries `customData.shadowOf` (the node id). The
  script is idempotent, so running it twice adds no second shadow. The shadow is
  the same shape offset +6 px in x and y. Its `backgroundColor` and
  `strokeColor` are the node's stroke color, with `fillStyle: "solid"`,
  `strokeWidth: 1`, `opacity: 80`. It is inserted just before its node, with an
  `index` lower than the node's. `convert.py` applies shadows once, in
  `document()`. Pie and xychart output is excluded. For hand-written JSON, see
  the Shadow template in `references/element-templates.md`.
- **Legend**: every diagram has one, top-right by default. If that area holds a
  node, arrow or header, use the nearest free corner. One 26x20 swatch per concept,
  with its label in `#868e96`. Swatches have no shadow.
- **Node layout**: rule boxes hold only a title and a one-line summary. Top-align
  boxes on a row. Gaps: 20 px between boxes on one row with no arrow between
  them. Where an arrow runs between shapes, the gap fits 6 px + arrow + 6 px.
  For a labelled arrow, the gap is label width + about 40 px. Minimum 60 px
  for an unlabelled arrow. Size boxes to text plus padding (see Layout
  Principles); do not stretch them.
- **Well-known systems get their real symbol, not a text label.** E.g.
  Elasticsearch/OpenSearch nodes are drawn as the actual multi-color Elastic
  logo (bent-line shape in the palette colours from `color-palette.md`)
  rather than a box labeled "ES".
  Reuse this pattern for other recognizable third-party systems where a
  simple brand mark exists.
- After hand-edits land in the live collection, re-fetch via `GET
  /api/v1/scenes/{sceneId}/content` before touching a diagram again — don't
  work from a stale local copy.

---

## Modern Aesthetics

For clean, professional diagrams:

### Roughness
- `roughness: 0` — Clean, crisp edges. Use for modern/technical diagrams.
- `roughness: 1` — Hand-drawn, organic feel. Use for brainstorming/informal diagrams.

**Default to 0** for most professional use cases.

### Stroke Width
- `strokeWidth: 1` — Thin. Dashed group containers, shadows, dividers.
- `strokeWidth: 2` — Standard. Shapes and all arrows.
- `strokeWidth: 4` — Bold. Use sparingly for emphasis.

### Opacity
**Use `opacity: 100` for all elements except offset shadows (`opacity: 80`).** Use color, size, and stroke width to create hierarchy instead of transparency.

### Small Markers Instead of Shapes
Instead of full shapes, use small dots (10-20px ellipses) as:
- Timeline markers
- Bullet points
- Connection nodes
- Visual anchors for free-floating text

---

## Layout Principles

### Hierarchy Through Scale
- **Hero**: 300×150 - visual anchor, most important
- **Primary**: 180×90
- **Secondary**: 120×60
- **Small**: 60×40

These are reference sizes. Size each box to its text plus padding: 20 px each side horizontally, 12 px vertically. Do not stretch boxes to a size.

### Whitespace = Importance
The most important element has the most empty space around it (200px+).

### Flow Direction
Guide the eye: typically left→right or top→bottom for sequences, radial for hub-and-spoke.

### Spacing Minimums
- Gap between nodes: at least one node height (one node width for horizontal flow). Exception: boxes in one top-aligned row use 20 px gaps.
- Padding between text and shape edge: at least 20 px horizontal, 12 px vertical.
- Aim for about 10 nodes per diagram. Beyond that, split into sections or frames.

### Connections Required
Position alone doesn't show relationships. If A relates to B, there must be an arrow.

---

## Text Rules

**CRITICAL**: The JSON `text` property contains ONLY readable words.

```json
{
  "id": "myElement1",
  "text": "Start",
  "originalText": "Start"
}
```

Settings: `fontSize: 16`, `fontFamily: 8` (Comic Shanns), `textAlign: "center"`, `verticalAlign: "middle"`

**Type scale**: use four sizes per diagram and no others. Same size for all labels of one level.
- 28: chart title (`fontFamily: 5`, Excalifont)
- 20: section or row title (`fontFamily: 5`, Excalifont)
- 16: node label
- 12 to 13: annotation, arrow label, legend

Use `fontFamily: 8` (Comic Shanns) for all other text. Never use `fontFamily: 3`.

---

## JSON Structure

```json
{
  "type": "excalidraw",
  "version": 2,
  "source": "https://excalidraw.com",
  "elements": [...],
  "appState": {
    "viewBackgroundColor": "#ffffff",
    "gridSize": 20
  },
  "files": {}
}
```

Editable files use `#ffffff` as `viewBackgroundColor`. A cream scene background set by the user in Excalidraw+ is kept on re-upload.

## Arrow Labels and Elbow Arrows

- A labelled arrow segment must be at least label width + 40 px long.
- For elbow arrows, the renderer places the bound label at the middle vertex (middle segment) of `points`. It re-routes elbow arrows from `fixedPoint`, so `points` are only a hint.
- Fan-out arrows from one box need distinct segment positions, so their bends and labels do not overlap.
- Self-loops: use an unbound label beside the loop. This is the exception to the bound-label rule.

## Sequence Diagrams

- Draw lifelines as narrow rectangles so arrows can bind to them. Or use lines split around labels.
- Put notes above the lifelines.
- Loop and par frames are dashed `#868e96` rectangles with a tab label.
- Actors are drawn as stick figures, at the top only.
- Return messages are dashed, not dotted.
- `activate`/`deactivate` and the `->>+` / `-->>-` shorthand draw activation bars on the lifeline.

## Generated Diagram Types (`scripts/convert.py`)

- **Flowchart**: nodes have shadows. Edge labels have a white background.
- **Class and ER tables**: one shadow sits behind the whole table box.
- **ER format**: `--format full|min` (default `full`). `full` uses a grid layout with up to 3 entities per row. Relationship lines run in the gaps between cells and rows. `min` is a compact grid. It uses the same grid code with tighter gaps. It has up to 3 entities per row, or 4 when there are 9 or more entities. It draws entity tables and small caption tags only. It has no group containers and no example tables. Group members stay next to each other and keep the group header colour. Each caption tag sits above its entity. `--no-examples` is kept for compatibility. `--format min` already covers it. Note: `--no-examples` alone still draws group containers; `min` does not.
- **ER example rows**: add `%% example Entity: v1 | v2 | v3` lines, one per row. Values follow the attribute order. The entity is matched by id or label. Rows are padded or truncated to the attribute count. `min` ignores them. In `full`, the table sits below its entity. It has a thin grid, a header row, a mono font, a curved connector and an "example" caption.
- **ER groups**: `%% group <Name> [color=<name>]: A, B`. In `full`, the group is a dashed, tinted container with no shadow. In both formats it sets the header colour of its entities. Colours: blue, green, orange, yellow, red, purple, indigo, gray. Without `color=`, colours cycle. Group members are placed in adjacent grid cells. A group that does not fit in the rest of a row starts a new row, so containers never overlap.
- **ER notes**: `%% note <Entity or Group>: text` adds a caption tag. It works in both formats.
- **ER commands**: `python3 -I scripts/convert.py --format full example-erd.mmd example-erd.excalidraw`, and `--format min example-erd.mmd example-erd-min.excalidraw`.
- **Pie**: `scripts/pie.py`, run through `convert.py`. Wedges start at 12 o'clock, go clockwise, largest first. Fills are saturated, with a darker outline of the same hue. Label text colour follows fill luminance. There is no legend. Inside labels are `name` and `(pct%)`. With `showData` they are `name: value` and `(pct%)`. Percentages under 10% show one decimal. Small wedges get a plain leader line to an outside label, coloured as the wedge stroke. The title is size 28, fontFamily 5. `%% subtitle: text` adds a size-16 grey subtitle. No shadows.
- **Gantt**: task bars have shadows. Status colors: done green, active blue, crit red, milestone amber. The legend lists only the statuses used. There is no Today marker (`todayMarker` is ignored).
- **Xychart**: `xychart.py` takes `--legend "Signups,Churn"` for series names. See `example-xychart.mmd`. It draws no shadows.

## Element Templates

See `references/element-templates.md` for copy-paste JSON templates for each element type (text, line, dot, rectangle, arrow). Pull colors from `references/color-palette.md` based on each element's semantic purpose.

---

## Pushing to an Excalidraw+ Collection

Publishing a generated `.excalidraw` file into an Excalidraw+ collection is a
two-step call. Auth token for both calls comes from the `EXCALIDRAW_API_KEY`
env var — never hardcode it.

**1. Create the scene (registers a name/slot in the collection):**

```
POST https://api.excalidraw.com/api/v1/collections/{collectionId}/scenes
Authorization: Bearer $EXCALIDRAW_API_KEY
Content-Type: application/json

{"name": "<scene name>", "pinned": false}
```

- `collectionId` — the collection's id (a personal key can also use the literal
  `private` for the owner's default collection).
- Response metadata includes the new scene's `id` — capture it for step 2.

**Fetching current content** (e.g. after a hand-edit, or before re-touching a
pushed diagram):

```
GET https://api.excalidraw.com/api/v1/scenes/{sceneId}/content
Authorization: Bearer $EXCALIDRAW_API_KEY
```

Returns the same `type`/`version`/`source`/`appState`/`elements`/`files`
shape as the PUT body, plus `sceneVersion` and `filesFailedToEmbed`.

**2. Upload the diagram content (authoritative full replace):**

```
PUT https://api.excalidraw.com/api/v1/scenes/{sceneId}/content
Authorization: Bearer $EXCALIDRAW_API_KEY
Content-Type: application/json

{"type": "excalidraw", "version": 2, "source": "...", "appState": {...}, "elements": [...], "files": {}}
```

- Body is exactly the `.excalidraw` file's JSON (`type`/`version`/`source`/
  `appState`/`elements`/`files`) — the same structure this skill already
  produces.
- This is a **full replace**: any elements omitted are removed, and connected
  editors reload rather than incrementally reconcile. Treat each PUT as
  overwriting the scene's entire content, not patching it.
- This writes to a live, possibly-shared collection — confirm scope (which
  collection, how many scenes) with the user before running this in bulk.

**Stricter element schema than the bare `.excalidraw` format:** the scene-content
PUT endpoint validates elements more strictly than what this skill's templates
produce. Every element additionally needs `index` (fractional-index string),
`roundness` (null if unused), `frameId` (null), `updated` (number), and
`autoResize` (boolean, text only). Every arrow — and even plain structural
`line` elements — needs `startArrowhead`/`endArrowhead` present (null if
unused) and, if bound to a shape, `startBinding`/`endBinding` objects that
include a `fixedPoint` tuple and a `mode` (`"inside"`/`"orbit"`/`"skip"`)
field. A shape's `boundElements` entry must reference a text element whose own
`containerId` points back to that shape — never list a free-floating label
positioned near a shape/arrow in its `boundElements`. Write a small
normalize/backfill helper that adds these defaults to generated JSON before
every PUT rather than hand-authoring them per element.

---

## Render & Validate (MANDATORY)

You cannot judge a diagram from JSON alone. After generating or editing the Excalidraw JSON, you MUST render it to PNG, view the image, and fix what you see — in a loop until it's right. This is a core part of the workflow, not a final check.

### How to Render

Build the image once, from the skill directory:

```bash
docker build -t excalidraw-render .
```

Render from the directory that holds the diagram:

```bash
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/data" excalidraw-render in.excalidraw --output out.png [--scale 1] [--width N] [--transparent] [--dark] [--svg out.svg]
```

- `--scale` defaults to 1. Use 2 for higher resolution.
- An SVG is written beside the PNG with the same stem. `--svg path` sets another path. `--output` is for the PNG only; `--output x.svg` fails with "Unsupported screenshot mime type".
- `--transparent` removes the background and keeps alpha.
- `--dark` is a true dark render (Excalidraw `exportWithDarkMode`).
- Rendering fetches Excalidraw and fonts from esm.sh, so it needs network access.
- Without Docker: run `uv run render_excalidraw.py ...` inside `references/`.

Then use the **Read tool** on the PNG to view it.

**Transparent background (only when asked):** if the user wants an image that works on both light and dark pages (README, docs site with a theme toggle), export with `--transparent`.

A transparent export has no canvas, so the diagram itself must work on either background:
- Use grey `#868e96` for everything drawn with no fill behind it: free text, arrow and line strokes, arrow labels, frame outlines, unfilled containers and their text.
- Text inside a filled shape is `#1e1e1e`.
- No pure-black or pure-white fills. Replace a `#1e1e1e` band with a palette fill (for example green `#d3f9d8` / `#2f9e44`).
- These rules apply to every diagram, not only transparent exports.
- Legibility check for `--transparent`: run `magick out.png -background '#121212' -flatten check.png` and view `check.png`.
- `--dark` is a true dark render, so the diagram can also be checked by rendering with `--dark` and viewing it.

### The Loop

After generating the initial JSON, run this cycle:

**1. Render & View** — Run the render script, then Read the PNG.

**2. Audit against your original vision** — Before looking for bugs, compare the rendered result to what you designed in Steps 1-4. Ask:
- Does the visual structure match the conceptual structure you planned?
- Does each section use the pattern you intended (fan-out, convergence, timeline, etc.)?
- Does the eye flow through the diagram in the order you designed?
- Is the visual hierarchy correct — hero elements dominant, supporting elements smaller?
- For technical diagrams: are the evidence artifacts (code snippets, data examples) readable and properly placed?

**3. Check for visual defects:**
- Text clipped by or overflowing its container
- Text or shapes overlapping other elements
- Arrows crossing through elements instead of routing around them
- Arrows landing on the wrong element or pointing into empty space
- Labels floating ambiguously (not clearly anchored to what they describe)
- Uneven spacing between elements that should be evenly spaced
- Sections with too much whitespace next to sections that are too cramped
- Text too small to read at the rendered size
- Overall composition feels lopsided or unbalanced

**4. Fix** — Edit the JSON to address everything you found. Common fixes:
- Widen containers when text is clipped
- Adjust `x`/`y` coordinates to fix spacing and alignment
- Add intermediate waypoints to arrow `points` arrays to route around elements
- Reposition labels closer to the element they describe
- Resize elements to rebalance visual weight across sections

**5. Re-render & re-view** — Run the render script again and Read the new PNG.

**6. Repeat** — Keep cycling until the diagram passes both the vision check (Step 2) and the defect check (Step 3). Typically takes 2-4 iterations. Don't stop after one pass just because there are no critical bugs — if the composition could be better, improve it.

### When to Stop

The loop is done when:
- The rendered diagram matches the conceptual design from your planning steps
- No text is clipped, overlapping, or unreadable
- Arrows route cleanly and connect to the right elements
- Spacing is consistent and the composition is balanced
- You'd be comfortable showing it to someone without caveats

### First-Time Setup
If the render image has not been built yet, run this from the skill directory:
```bash
docker build -t excalidraw-render .
```

---

## Quality Checklist

### Depth & Evidence (Check First for Technical Diagrams)
1. **Research done**: Did you look up actual specs, formats, event names?
2. **Evidence artifacts**: Are there code snippets, JSON examples, or real data?
3. **Multi-zoom**: Does it have summary flow + section boundaries + detail?
4. **Concrete over abstract**: Real content shown, not just labeled boxes?
5. **Educational value**: Could someone learn something concrete from this?

### Conceptual
6. **Isomorphism**: Does each visual structure mirror its concept's behavior?
7. **Argument**: Does the diagram SHOW something text alone couldn't?
8. **Variety**: Does each major concept use a different visual pattern?
9. **No uniform containers**: Avoided card grids and equal boxes?

### Container Discipline
10. **Minimal containers**: Could any boxed element work as free-floating text instead?
11. **Lines as structure**: Are tree/timeline patterns using lines + text rather than boxes?
12. **Typography hierarchy**: Are font size and color creating visual hierarchy (reducing need for boxes)?

### Structural
13. **Connections**: Every relationship has an arrow or line
14. **Flow**: Clear visual path for the eye to follow
15. **Hierarchy**: Important elements are larger/more isolated

### Technical
16. **Text clean**: `text` contains only readable words
17. **Font**: `fontFamily: 8` for body text, `5` for the chart title and row/section titles; no `fontFamily: 3`
18. **Roughness**: `roughness: 0` for clean/modern (unless hand-drawn style requested)
19. **Opacity**: `opacity: 100` for all elements except offset shadows (`80`)
20. **Container ratio**: <30% of text elements should be inside containers

### Visual Validation (Render Required)
21. **Rendered to PNG**: Diagram has been rendered and visually inspected
22. **No text overflow**: All text fits within its container
23. **No overlapping elements**: Shapes and text don't overlap unintentionally
24. **Even spacing**: Similar elements have consistent spacing
25. **Arrows land correctly**: Arrows connect to intended elements without crossing others
26. **Readable at export size**: Text is legible in the rendered PNG
27. **Balanced composition**: No large empty voids or overcrowded regions
28. **Spacing minimums**: Node gaps at least one node height (20 px between boxes in one top-aligned row); text padding at least 20 px horizontal by 12 px vertical; about 10 nodes or fewer per diagram
