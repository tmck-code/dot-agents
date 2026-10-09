# Excalidraw JSON Schema

## Element Types

| Type | Use For |
|------|---------|
| `rectangle` | Processes, actions, components |
| `ellipse` | Entry/exit points, external systems |
| `diamond` | Decisions, conditionals |
| `arrow` | Connections between shapes |
| `text` | Labels inside shapes |
| `line` | Non-arrow connections |
| `frame` | Grouping containers |

## Common Properties

All elements share these:

| Property | Type | Description |
|----------|------|-------------|
| `id` | string | Unique identifier |
| `type` | string | Element type |
| `x`, `y` | number | Position in pixels |
| `width`, `height` | number | Size in pixels |
| `strokeColor` | string | Border color (hex) |
| `backgroundColor` | string | Fill color (hex or "transparent") |
| `fillStyle` | string | "solid", "hachure", "cross-hatch" |
| `strokeWidth` | number | 1 (shadows), 2 (default: shapes and arrows), 3 (emphasis) |
| `strokeStyle` | string | "solid", "dashed", "dotted" |
| `roughness` | number | 0 (smooth), 1 (default), 2 (rough) |
| `opacity` | number | 0-100 |
| `seed` | number | Random seed for roughness |

## Text-Specific Properties

| Property | Description |
|----------|-------------|
| `text` | The display text |
| `originalText` | Same as text |
| `fontSize` | Size in pixels (16-20 recommended) |
| `fontFamily` | 8 (Comic Shanns) for body text. 5 (Excalifont) for chart, row and section titles. |
| `textAlign` | "left", "center", "right" |
| `verticalAlign` | "top", "middle", "bottom" |
| `containerId` | ID of parent shape |

## Arrow-Specific Properties

| Property | Description |
|----------|-------------|
| `elbowed` | `true` for elbow arrows (the default style). Set `roundness` to null. |
| `points` | Array of [x, y] coordinates. Elbow arrows use right-angle segments. |
| `startBinding` | Connection to start shape |
| `endBinding` | Connection to end shape |
| `startArrowhead` | null (default), "arrow", "bar", "dot", "triangle" |
| `endArrowhead` | "triangle" (default), or null, "arrow", "bar", "dot" |
| `strokeStyle` | "solid", or "dashed" for return, loop-back, optional and async flows |
| `boundElements` | Lists the arrow's bound label: `{"id": "<label id>", "type": "text"}` |

An arrow label is a text element whose `containerId` is the arrow id.

## Binding Format

```json
{
  "elementId": "shapeId",
  "fixedPoint": [1, 0.5],
  "mode": "orbit"
}
```

- `fixedPoint`: where the arrow meets the shape, as fractions of its width and height. `[1, 0.5]` is the middle of the right edge.
- `mode`: "orbit" keeps the arrow outside the shape. "inside" lets it end within the shape.
- Leave a 6 px gap between each arrow end and its shape.
- Add the arrow to `boundElements` of each bound shape: `{"id": "<arrow id>", "type": "arrow"}`.

## Rectangle Roundness

Add for rounded corners:
```json
"roundness": { "type": 3 }
```

## Shadow and Opacity

Shadows are plain rectangles with `opacity` 80 and `strokeWidth` 1. See `element-templates.md`. All other elements use `opacity` 100.
