# Element Templates

Copy-paste JSON templates for each Excalidraw element type. Placeholder colors in angle brackets come from `color-palette.md` by the element's concept. Fixed colors follow the Dual-Mode Rules there. Free text titles use `fontFamily` 5. All other text uses 8.

## Free-Floating Text (no container)
```json
{
  "type": "text",
  "id": "label1",
  "x": 100, "y": 100,
  "width": 200, "height": 25,
  "text": "Section Title",
  "originalText": "Section Title",
  "fontSize": 20,
  "fontFamily": 5,
  "textAlign": "left",
  "verticalAlign": "top",
  "strokeColor": "#868e96",
  "backgroundColor": "transparent",
  "fillStyle": "solid",
  "strokeWidth": 1,
  "strokeStyle": "solid",
  "roughness": 0,
  "opacity": 100,
  "angle": 0,
  "seed": 11111,
  "version": 1,
  "versionNonce": 22222,
  "isDeleted": false,
  "groupIds": [],
  "boundElements": null,
  "link": null,
  "locked": false,
  "containerId": null,
  "lineHeight": 1.25
}
```

## Line (structural, not arrow)
```json
{
  "type": "line",
  "id": "line1",
  "x": 100, "y": 100,
  "width": 0, "height": 200,
  "strokeColor": "#868e96",
  "backgroundColor": "transparent",
  "fillStyle": "solid",
  "strokeWidth": 2,
  "strokeStyle": "solid",
  "roughness": 0,
  "opacity": 100,
  "angle": 0,
  "seed": 44444,
  "version": 1,
  "versionNonce": 55555,
  "isDeleted": false,
  "groupIds": [],
  "boundElements": null,
  "link": null,
  "locked": false,
  "points": [[0, 0], [0, 200]]
}
```

## Small Marker Dot
```json
{
  "type": "ellipse",
  "id": "dot1",
  "x": 94, "y": 94,
  "width": 12, "height": 12,
  "strokeColor": "<marker dot color from palette>",
  "backgroundColor": "<marker dot color from palette>",
  "fillStyle": "solid",
  "strokeWidth": 1,
  "strokeStyle": "solid",
  "roughness": 0,
  "opacity": 100,
  "angle": 0,
  "seed": 66666,
  "version": 1,
  "versionNonce": 77777,
  "isDeleted": false,
  "groupIds": [],
  "boundElements": null,
  "link": null,
  "locked": false
}
```

## Rectangle
```json
{
  "type": "rectangle",
  "id": "elem1",
  "x": 100, "y": 100, "width": 180, "height": 90,
  "strokeColor": "<stroke from palette based on semantic purpose>",
  "backgroundColor": "<fill from palette based on semantic purpose>",
  "fillStyle": "solid",
  "strokeWidth": 2,
  "strokeStyle": "solid",
  "roughness": 0,
  "opacity": 100,
  "angle": 0,
  "seed": 12345,
  "version": 1,
  "versionNonce": 67890,
  "isDeleted": false,
  "groupIds": [],
  "boundElements": [{"id": "text1", "type": "text"}],
  "link": null,
  "locked": false,
  "roundness": {"type": 3}
}
```

## Text (centered in shape)
For text bound in a shape, `height` must equal `ceil(fontSize * lineHeight * lines)`. Otherwise it renders at the top of the shape. (16 px, lineHeight 1.25, one line: 20.)

```json
{
  "type": "text",
  "id": "text1",
  "x": 130, "y": 132,
  "width": 120, "height": 25,
  "text": "Process",
  "originalText": "Process",
  "fontSize": 16,
  "fontFamily": 8,
  "textAlign": "center",
  "verticalAlign": "middle",
  "strokeColor": "#1e1e1e",
  "backgroundColor": "transparent",
  "fillStyle": "solid",
  "strokeWidth": 1,
  "strokeStyle": "solid",
  "roughness": 0,
  "opacity": 100,
  "angle": 0,
  "seed": 11111,
  "version": 1,
  "versionNonce": 22222,
  "isDeleted": false,
  "groupIds": [],
  "boundElements": null,
  "link": null,
  "locked": false,
  "containerId": "elem1",
  "lineHeight": 1.25
}
```

## Shadow (offset duplicate)
Put one behind every filled node rectangle that holds text. Place it immediately before its shape in the `elements` array, with an `index` that sorts just before the shape's index.

Rules:
- Same width, height and roundness as the shape.
- Offset +6 px in x and y from the shape.
- `backgroundColor` and `strokeColor` both equal the shape's stroke color.
- `fillStyle` "solid", `strokeWidth` 1, `opacity` 80.
- No text, no bindings (`boundElements` null), same `groupIds` as the shape.
- No shadow on legend swatches, full-width bands, the bottom summary box, or dashed or unfilled shapes.

Shadow for the Rectangle above (shape at x 100, y 100, `index` "a1"):
```json
{
  "type": "rectangle",
  "id": "elem1-shadow",
  "index": "a0V",
  "x": 106, "y": 106, "width": 180, "height": 90,
  "strokeColor": "<same stroke as elem1>",
  "backgroundColor": "<same stroke as elem1>",
  "fillStyle": "solid",
  "strokeWidth": 1,
  "strokeStyle": "solid",
  "roughness": 0,
  "opacity": 80,
  "angle": 0,
  "seed": 88888,
  "version": 1,
  "versionNonce": 99999,
  "isDeleted": false,
  "groupIds": [],
  "boundElements": null,
  "link": null,
  "locked": false,
  "roundness": {"type": 3}
}
```

## Legend Swatch
Every diagram has a legend in the top-right corner: one swatch per concept, with a label. Swatch is 26x20, filled with the concept's fill and stroked with its stroke, no shadow. The label is a free text element (`fontFamily` 8, `fontSize` 12 to 13) with `strokeColor` `#868e96`.
```json
{
  "type": "rectangle",
  "id": "legend-agents",
  "x": 900, "y": 20, "width": 26, "height": 20,
  "strokeColor": "#1971c2",
  "backgroundColor": "#d0ebff",
  "fillStyle": "solid",
  "strokeWidth": 2,
  "strokeStyle": "solid",
  "roughness": 0,
  "opacity": 100,
  "angle": 0,
  "seed": 12121,
  "version": 1,
  "versionNonce": 21212,
  "isDeleted": false,
  "groupIds": [],
  "boundElements": null,
  "link": null,
  "locked": false,
  "roundness": {"type": 3}
}
```

## Arrow
Elbow arrow. The default for all connections. Rules:
- `elbowed` true, `roundness` null, `strokeWidth` 2, `startArrowhead` null, `endArrowhead` "triangle".
- Bound at both ends with `fixedPoint`. Each value is a fraction of the shape's width and height: `[1, 0.5]` is the middle of the right edge, `[0, 0.5]` the left edge, `[0.5, 0]` the top, `[0.5, 1]` the bottom.
- 6 px gap between each arrow end and its shape. Here elem1 ends at x 280, the arrow runs x 286 to 404, and elem2 starts at x 410.
- Stroke `#868e96`.
- Add the arrow to `boundElements` of both shapes: `{"id": "arrow1", "type": "arrow"}`.

```json
{
  "type": "arrow",
  "id": "arrow1",
  "x": 286, "y": 145, "width": 118, "height": 0,
  "strokeColor": "#868e96",
  "backgroundColor": "transparent",
  "fillStyle": "solid",
  "strokeWidth": 2,
  "strokeStyle": "solid",
  "roughness": 0,
  "opacity": 100,
  "angle": 0,
  "seed": 33333,
  "version": 1,
  "versionNonce": 44444,
  "isDeleted": false,
  "groupIds": [],
  "boundElements": null,
  "link": null,
  "locked": false,
  "elbowed": true,
  "roundness": null,
  "fixedSegments": null,
  "points": [[0, 0], [118, 0]],
  "startBinding": {"elementId": "elem1", "fixedPoint": [1, 0.5], "mode": "orbit"},
  "endBinding": {"elementId": "elem2", "fixedPoint": [0, 0.5], "mode": "orbit"},
  "startArrowhead": null,
  "endArrowhead": "triangle"
}
```

Dashed variant: set `"strokeStyle": "dashed"`. Use it for return, loop-back, optional and async flows. Change nothing else.

For a bend, add corner points to `points`, for example `[[0, 0], [59, 0], [59, 80], [118, 80]]`, and set `height` to 80.

## Arrow Label
Put a qualifier on the arrow, not in the box. Bind the label: set the text's `containerId` to the arrow id, and list the text in the arrow's `boundElements` as `{"id": "arrow1-label", "type": "text"}`.

The renderer hides the arrow line only inside the label's declared box. If the box is smaller than the rendered text, the line shows through the text. So size the box to the text:

- `width` = `ceil(chars * fontSize * 0.6) + 6` (verified for fontFamily 8; for fontSize 12 this is `ceil(chars * 7.2) + 6`).
- A labelled segment must be at least label width + 40 px long. For elbow arrows the renderer puts the label at the middle vertex of `points` and re-routes from `fixedPoint`, so `points` are a hint. Fan-out arrows from one box need distinct segment positions. Self-loops use an unbound label beside the loop.
- `height` = `ceil(fontSize * lineHeight)` (15 for fontSize 12, lineHeight 1.25).
- Centre the box on the midpoint of the arrow's middle segment: `x` = midpoint x minus width / 2, `y` = midpoint y minus height / 2. For a straight arrow the midpoint is `(arrow.x + width / 2, arrow.y + height / 2)`.
```json
{
  "type": "text",
  "id": "arrow1-label",
  "x": 305, "y": 137.5,
  "width": 61, "height": 15,
  "text": "on error",
  "originalText": "on error",
  "fontSize": 12,
  "fontFamily": 8,
  "textAlign": "center",
  "verticalAlign": "middle",
  "strokeColor": "#868e96",
  "backgroundColor": "transparent",
  "fillStyle": "solid",
  "strokeWidth": 1,
  "strokeStyle": "solid",
  "roughness": 0,
  "opacity": 100,
  "angle": 0,
  "seed": 55555,
  "version": 1,
  "versionNonce": 66666,
  "isDeleted": false,
  "groupIds": [],
  "boundElements": null,
  "link": null,
  "locked": false,
  "containerId": "arrow1",
  "lineHeight": 1.25
}
```
