# canvas-align

Measures how far canvas objects land from where they should be on different screen sizes and clients.
Decisions 0073 and 0080 promise every client shows each object at the same board position.
This tool checks the promise end to end.

## The scene

`seed` places four objects through the real canvas API, all at known board coordinates (the 1920x1080 shared area, top-left at the origin):

- an image covering the whole board, with a flat cream field, a 100 unit grid and four coloured 80x80 corner markers
- a 300x300 square shape at (1300, 200)
- a diagonal stroke drawn inside that square
- a 10x10 square shape at the board centre (955, 535)

It writes a manifest JSON with every object and the colour and board centre of each marker.

## Steps

```bash
export CANVAS_ALIGN_PASSWORD=...

# 1. place the scene in an empty canvas channel and write the manifest
scripts/canvas-align/canvas-align.py seed --base-url https://host --username Claude \
    --channel my-private-channel --out manifest.json

# 2. screenshot the web client at 1920x1080, 1280x720, 1024x768, 390x844 and 844x390, then measure each
scripts/canvas-align/canvas-align.py capture-web --base-url https://host --web-url https://host/app/ \
    --username Claude --manifest manifest.json --out-dir shots

# 3. measure screenshots from any other client (a desktop window, a phone screenshot)
scripts/canvas-align/canvas-align.py measure --manifest manifest.json --annotate-dir diffs phone.png desktop.png
```

`measure` finds the board in the screenshot from the reference image's cream field (the image is the shared area, inside a larger board), maps each marker's centre to board coordinates, and prints its offset from the manifest in pixels and board units.
It exits non-zero when a marker is missing or more than 1 px away (`--tolerance` changes that), or when the board is too hidden to measure.
`--annotate-dir` saves each screenshot with the board outline, the expected marker positions (white crosses) and the found ones (red circles).
`capture-web` writes `web-<w>x<h>.png` and the annotated diffs under `diff/` in `--out-dir`.

How a screenshot is read:

- UI drawn over the pane edge (the focus ring) hides a pixel or two of the board, so the edge reading is checked against the four image corner markers.
  When they disagree by more than 0.75 px the frame comes from the corner markers instead, and the header line says so and prints the gap.
- A solid corner marker with less than 90% of its area showing (under the zoom pill, the header or the dock) is listed as covered and skipped.
- When the edges are no use (the two axes disagree on scale) and fewer than three corners show, the board is cut by the UI and the capture fails without positions.
  That is a finding in itself: part of the board sits under the header or the dock at that size.

## Notes and limits

- The board edge is quantised to a whole pixel because the client clips with hard edges, so an edge-based frame is good to about half a pixel.
- Marker centres are read to about 0.8 px at the smallest zoom (the line and the outlines are antialiased hairlines), so a 1 px tolerance has little headroom on a phone.
- Offsets are measured against the board as the image shows it.
  An image that is itself scaled wrongly would move the edge with it; the printed scale per axis (board px divided by 1920 or 1080) exposes that.
- `seed` refuses a canvas that already holds objects, so a second run does not stack a second scene.
  Test in a private channel with only the agent account and the owner, and remove the objects afterwards.
- `measure` needs Pillow and numpy.
  `seed` and `capture-web` need only the standard library and `chrome-devtools-axi` (`npx -y chrome-devtools-axi`), run headless in its own session.
- The unit tests are `scripts/lib/test_canvas_align.py`, part of the scripts/lib suite.
