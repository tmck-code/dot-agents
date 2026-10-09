# Color Palette & Brand Style

**This is the single source of truth for all colors and brand-specific styles.** To customize diagrams for your own brand, edit this file. Everything else in the skill is universal.

All colors are Open Color values. Diagrams must work on a light and a dark background (see Dual-Mode Rules).

---

## Shape Colors (Semantic)

Colors encode meaning, not decoration. Each concept has a fill/stroke pair.

| Concept | Fill | Stroke | Secondary fill |
|---------|------|--------|----------------|
| Hooks, rules | `#ffec99` | `#f08c00` | `#fff9db` |
| User, main thread | `#ffe3e3` | `#e03131` | `#fff5f5` |
| Agents | `#d0ebff` | `#1971c2` | `#e7f5ff` |
| Skills, CLI, gates | `#d3f9d8` | `#2f9e44` | `#ebfbee` |
| Files on disk | `#eebefa` | `#9c36b5` | `#f8f0fc` |
| Extra category (when more than five are needed) | `#dbe4ff` | `#4263eb` | `#edf2ff` |
| Unknown, inactive | `#f1f3f5` | `#868e96` (dashed stroke) | `#f8f9fa` |

**Tints**: generators may use other Open Color steps (for example 1 to 2 for fills, 7 to 9 for strokes) for tints, so long as every value is an Open Color hex.

**Rule**: Always pair a darker stroke with a lighter fill.

**Secondary fill**: for less important nodes of the same concept, use the paler Secondary fill with the same stroke. This shows hierarchy within a concept without a new hue. Use it for at most about half the nodes of a concept.

**Shapes**: rectangles with rounded corners (`roundness: {"type": 3}`). Group containers are dashed, unfilled, with a `#868e96` stroke.

---

## Dual-Mode Rules

Every diagram is exported for light and dark backgrounds. These rules keep it readable on both.

- No pure black (`#000000`) or pure white (`#ffffff`) fills. White (`#ffffff`) text on a saturated header fill is allowed.
- Free text, arrow strokes, arrow labels, frame outlines and unfilled containers: `#868e96`.
- Text inside filled shapes: `#1e1e1e`.
- Shadows use the shape's stroke color (see `element-templates.md`).

---

## Text Colors

| Where | Color |
|-------|-------|
| Free text: titles, subtitles, body, annotations | `#868e96` |
| Arrow labels | `#868e96` |
| Legend labels | `#868e96` |
| Text inside a filled shape | `#1e1e1e` |

Create hierarchy with size (the type scale in SKILL.md), not with extra text colors.

---

## Fonts

| Use | fontFamily |
|-----|-----------|
| Body text, node text, labels | `8` (Comic Shanns) |
| Chart title, row and section titles | `5` (Excalifont) |

---

## Evidence Artifact Colors

For code snippets and data examples inside technical diagrams. These dark boxes are the one exception to the `#1e1e1e` text rule: use light text on them.

| Artifact | Background | Text Color |
|----------|-----------|------------|
| Code snippet | `#343a40` | `#f1f3f5` or syntax colors |
| JSON/data example | `#343a40` | `#8ce99a` |

---

## Default Stroke & Line Colors

| Element | Color |
|---------|-------|
| Arrows | `#868e96` |
| Structural lines (dividers, trees, timelines) | `#868e96` |
| Marker dots (fill + stroke) | The concept's stroke color |

---

## Background

| Property | Value |
|----------|-------|
| Canvas background | `#ffffff` for the editable file. Exports are transparent. |

## Chart Series Colors

Series order, used by both `xychart` and `pie` (fill, stroke):

1. blue `#d0ebff` / `#1971c2`
2. green `#d3f9d8` / `#2f9e44`
3. orange `#ffec99` / `#f08c00`
4. red `#ffe3e3` / `#e03131`
5. purple `#eebefa` / `#9c36b5`
6. grey `#f1f3f5` / `#868e96`
