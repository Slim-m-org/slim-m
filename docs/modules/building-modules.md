# Building a slim module

This is the guide for writing a module that runs on a slim deployment.

A module is a small, sandboxed WebAssembly program.
It receives an input and returns an output, and it can reach nothing else - no network, no filesystem, no host state.
That single constraint is the whole of the v1 security model, and it is what lets a deployment run community-authored code at all.

Read `docs/decisions/0021-modules-and-the-dock.md` for why the system is shaped this way, and `docs/decisions/0022-module-extensibility-and-evolution.md` for how it grows.
This document is the practical how-to; those two are the reasoning.

Not sure whether your idea is a module or a bot? See `docs/decisions/0035-module-or-bot.md`.

## What a module can do

A module extends slim through a small set of bounded contracts.
It never patches slim, and slim never learns what any particular module does.
Everything a module offers is declared in its manifest as an *extension point*, and slim only ever routes a request to it and renders whatever comes back.

Today a module can:

- Register a **command** that runs on demand and returns text.
- Offer a **code-block runner** so a fenced code block in chat grows a Run button.
- Offer a **slash command** the composer surfaces as `/name`.
- Offer an **app** a member launches into a channel as a live, shared surface.
- Draw an interactive **scene** (a board, a chart, a small game) as its output, instead of plain text.

With an admin's approval a module can also store a little state on the host (`kv.store`) and post a message as the person who ran it (`message.post`).
A module cannot react to an event or post on its own; see [Host capabilities](#host-capabilities).

## Quickstart

A module is any wasm binary that follows the ABI below.
The examples here are Rust compiled to `wasm32-unknown-unknown`, which is the toolchain the reference modules in [slim-addons](https://github.com/Slim-m-org/slim-addons) use, but nothing in slim requires Rust.

A minimal module that echoes its input back:

```rust
// src/lib.rs
use std::alloc::{alloc as sys_alloc, Layout};

/// The host calls this once to get somewhere to write the request.
#[no_mangle]
pub extern "C" fn alloc(len: i32) -> i32 {
    let layout = Layout::from_size_align(len as usize, 1).unwrap();
    unsafe { sys_alloc(layout) as i32 }
}

/// The host writes the request at `in_ptr`/`in_len`, then calls this.
/// Return a packed `(out_ptr << 32) | out_len` pointing at the response.
#[no_mangle]
pub extern "C" fn run(in_ptr: i32, in_len: i32) -> i64 {
    let request = unsafe {
        std::slice::from_raw_parts(in_ptr as *const u8, in_len as usize)
    };
    // The request is {"command", "input", "caller": {"id"}, "entropy"} as UTF-8 JSON.
    // Echo a success response of the same shape the host expects.
    let response = br#"{"ok":true,"output":"hello from a module"}"#;
    let ptr = response.as_ptr() as i64;
    (ptr << 32) | (response.len() as i64)
}
```

```toml
# Cargo.toml
[package]
name = "echo"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib"]

[profile.release]
opt-level = "s"
lto = true
```

Build it:

```bash
cargo build --release --target wasm32-unknown-unknown
# -> target/wasm32-unknown-unknown/release/echo.wasm
```

That wasm plus a manifest (below) is a complete module.
The reference modules parse the request and build the response with `serde_json` rather than by hand; the raw version above is only to show that nothing magic is happening.

There is a ready-to-copy starter in `slim-addons/modules/_template/`, which is the fastest way to begin.

## The module ABI (v1)

A module is a wasm binary that **exports exactly two functions and one memory, and imports nothing at all**.
A single import of any kind is refused at install time rather than sandboxed, because the point of the model is that a module has no ambient authority to sandbox in the first place.

- `memory` - the module's exported linear memory.
- `alloc(len: i32) -> i32` - reserve `len` bytes inside the module's own memory and return a pointer to them.
  The host calls this once, before `run`, to get somewhere to write the request.
- `run(in_ptr: i32, in_len: i32) -> i64` - given the request the host just wrote at `in_ptr`/`in_len`, return a packed `(out_ptr << 32) | out_len` pointing at the response.
  The response may live anywhere the module likes: its own static data, a second `alloc`, or the input region reused in place.

The host writes a UTF-8 JSON request into the region `alloc` returned, calls `run`, and reads `out_len` bytes back at `out_ptr` as a UTF-8 JSON response.
The host only moves bytes; it has no opinion about what is inside them beyond the request/response shapes below.

The ABI is versioned as v1.
A different execution contract would be a new ABI version, not an edit to this one.

## The command protocol

Every extension point that runs is, underneath, a call to one of the module's commands.

The **request** the host writes is a JSON object:

```json
{ "command": "roll", "input": "2d20+3", "caller": { "id": "9f2c...e1" }, "entropy": "4b0d...a7" }
```

- `command` is the name of a `command` extension point the module declared.
- `input` is a string whose meaning is entirely the module's own - a code snippet, a dice notation, a JSON blob, whatever the command wants.
- `caller.id` is an opaque, stable id for whoever ran the command, and it is the only thing the module is told about them.
- `entropy` is 32 hex characters of fresh randomness, new for every run and unrelated to who ran it.
  A module has no clock or random source, so mix it into your seed when a command should vary, such as a die roll.

### Who is calling

A module is told who is asking by `caller.id` and nothing else.
There is no display name, no user id, no channel, no space, no roles and no permissions in the request.
The id is a lowercase hex string derived from the module and the user.
It is the same for one person across runs of the same module, differs between people, and differs between modules for the same person.
It is not a user id and cannot be turned back into one: it is keyed with a secret only the deployment holds, so it also differs between deployments.

Use it to dedupe against yourself, for example "one vote per person" in a poll.
Do not treat it as authentication or as a way to act as the person.
A module cannot post, read or spend anything on someone's behalf through it.
A module that runs at all was already allowed to by its permission, so "does the caller hold the permission" is always yes and is not sent.

The field is additive and the ABI stays v1.
Read the fields you need and ignore the rest, so a module built before `caller` existed keeps working.
A module cannot remember ids between runs unless an admin approved `kv.store` for it, so keep them in the state you round-trip through `input` or ask for that approval.

This is separate from the call context in [0023](../decisions/0023-mediated-host-capabilities.md).
That context (module, space, invoking user, channel) is what the host holds to gate a `host_call` capability, and it is never handed to the module.
The reasoning is in [0038](../decisions/0038-module-caller-id.md).

The **response** the module returns is a JSON object, one of two shapes:

```json
{ "ok": true,  "output": "..." }
{ "ok": false, "error": "..." }
```

- On success, `output` is the module's result as a string.
  If that string happens to be a [scene](#the-scene-contract), slim paints it; otherwise it is shown as text.
- On failure, `error` is a human-readable message.
  A failure here is the module's own "I could not do this" (a syntax error in the snippet, say) - not a host refusal.
  Host refusals (not installed, not enabled, no permission, out of fuel) never reach the module and are surfaced separately.

## The manifest

A module is described by a `manifest.json`.
This is what slim validates at install time and persists; it is the contract's source of truth.

```json
{
  "schema": 1,
  "id": "dice",
  "name": "Dice",
  "version": "0.3.0",
  "summary": "Roll dice notation like 2d20+3.",
  "description": "A longer explanation shown on the module's Dock page.",
  "author": "you",
  "homepage": "https://github.com/you/your-addons",
  "runtime": {
    "backend": "wasm",
    "limits": { "memory_mb": 64, "wall_ms": 2000, "fuel": 200000000 }
  },
  "artifact": {
    "kind": "wasm",
    "path": "modules/dice/0.3.0/module.wasm",
    "sha256": "<64 hex chars>"
  },
  "permissions": [
    { "key": "roll", "name": "Roll dice", "description": "Roll dice in this space." }
  ],
  "capabilities": ["command.register"],
  "extension_points": [
    { "kind": "command", "name": "roll", "permission": "roll", "description": "Roll dice." },
    { "kind": "slash-command", "name": "roll", "permission": "roll", "command": "roll", "description": "Roll dice like 2d20+3." }
  ]
}
```

Field by field:

- `schema` - the manifest envelope version, currently `1`.
  A version slim does not recognise is rejected cleanly.
- `id` - a safe slug (lowercase letters, digits, hyphens), unique in a registry, and stable across versions.
  It is also the natural `/id` keyword for an [app](#app) launch.
- `name`, `summary`, `description`, `author`, `homepage` - shown on the module's Dock page. `name` and `summary` are required.
- `version` - a version string; bumping it is how an upgrade is offered (see [Publishing](#publishing-a-module)).
- `runtime.backend` is `"wasm"`. `runtime.limits` is optional and each field within it is optional; see [Limits](#limits-and-the-security-model).
- `artifact.path` is the wasm's path within the registry, and `artifact.sha256` is its SHA-256, which slim pins - a mismatch refuses to run.
- `permissions` are the permission keys this module introduces.
  A deployment's admins grant these to roles; nobody, not even an administrator, holds a module's permission implicitly.
- `capabilities` are strings a module declares it wants.
  The host implements two, `kv.store` and `message.post`, and an admin approves each one per install; see [Host capabilities](#host-capabilities).
  Declare only what you actually intend to use.
- `extension_points` are what the module offers, covered next.

## Extension-point kinds

Each extension point has a `kind`, a `name`, and an optional `description`.
Every kind slim knows gates on a declared `permission`; the runner-like kinds also name the `command` they invoke.
A kind slim does **not** recognise is accepted and stored, then ignored - so a client that learns a future kind can use it while older servers simply carry it, and a module can target the future without waiting for every deployment.

### command

Runs on demand and returns text (or a scene).

```json
{ "kind": "command", "name": "roll", "permission": "roll", "description": "Roll dice." }
```

- `permission` (required) names one of this manifest's own `permissions[].key`.
- `name` is the command name the request's `command` field carries.

A bare `command` is not, by itself, visible anywhere in the UI - it is the thing the runner-like kinds below invoke.
A module that only wants a command reachable through the Dock's own run panel needs just this.

### code-block-runner

Grows a Run button on a fenced code block in chat.

```json
{ "kind": "code-block-runner", "name": "Run in chat", "permission": "run", "command": "run", "language": "javascript" }
```

- `command` (required) names a `command` extension point this manifest also declares.
- `language` (required in practice) is the fence tag this runner matches (`js`, `python`, ...).
  It is optional in the schema, but a runner that omits it now matches **nothing** rather than everything.
  That changed in #1211: a wildcard runner was handing a `python` block to a JavaScript engine, so a runner is offered only for a language it named.
  The client normalises case and applies a small alias map (`js` -> `javascript`) before comparing.

When a member runs a block, the result is stored against the message and broadcast, so everyone viewing sees the same output without rerunning it.

### slash-command

Offered in the composer as `/name`.

```json
{ "kind": "slash-command", "name": "roll", "permission": "roll", "command": "roll", "description": "Roll dice like 2d20+3." }
```

- `name` is the keyword the composer offers as `/name`; a member types `/roll 2d20+3`.
- Everything after the keyword is handed to the command as its `input`.

### app

Launched into a channel as a message that renders as the module's own interactive surface, shared across everyone viewing it.

```json
{ "kind": "app", "name": "Game of Life", "permission": "play", "command": "life", "description": "Launch a live board in the channel." }
```

- `name` is what the composer's apps menu shows.
- The launch also has a `/id` alias (the module's `id`), so `/game-of-life` launches it.
- A launch runs the command once with an empty `input`, so a well-behaved app returns its initial frame for empty input.
  From then on the surface is driven entirely by the [interactive scene](#interactive-scenes) protocol, shared through the same stored-and-broadcast mechanism a code-block runner uses.

## The scene contract

A command normally returns text.
If instead it returns a string that is a JSON object tagged `"$slim": "scene/1"`, slim paints it as a scene.
This is a client-side reading of an ordinary output string - there is no separate wire type and nothing to declare.
A module opts in simply by choosing to emit one, and any output that is not a valid scene falls back to plain text.

```json
{
  "$slim": "scene/1",
  "width": 100,
  "height": 100,
  "background": "surface",
  "ops": [
    { "op": "rect", "x": 10, "y": 10, "w": 80, "h": 30, "fill": "accent", "r": 6 },
    { "op": "text", "x": 50, "y": 25, "s": "hello", "fill": "text", "align": "center", "size": 8 }
  ],
  "status": "a caption under the scene",
  "controls": [],
  "live": false
}
```

- `width` and `height` are the scene's own logical units; the painter scales them to whatever box it is given.
- The ratio between the long and short axis is clamped to **4:1** at parse, by growing the short axis, so an op keeps the coordinates you wrote it at and the scene gains empty room instead of being squashed.
  That is the most a 390 point phone card can show while the short side stays tall enough to see and aim at (98 points); a 1000:1 scene would otherwise be a 3 point sliver.
- Inline in a transcript a scene is drawn at most at most 360 points tall, whatever units `width` and `height` use.
  Coordinates in ops are in these units.
- `background` is an optional fill for the whole scene.
- `status` is an optional one-line caption shown under the scene.
- `ops` is the list of drawing primitives, painted in order (first is bottom).

### Colours

A colour is either a literal `#rrggbb` or the name of a theme token, which the painter resolves against the viewer's theme so a scene looks native in light and dark alike:

`accent`, `surface`, `sunken`, `muted`, `text`, `border`, `danger`.

Prefer tokens; a module that hard-codes hex will look wrong in one theme or the other.

### Ops

| op | fields |
| --- | --- |
| `cells` | `cols`, `rows`, `data` (one char per cell, row-major, each a palette index `'0'`..), `palette` (list of colours), `gap`, `tap`, and optionally `x`, `y`, `w`, `h` |
| `rect` | `x`, `y`, `w`, `h`, `fill`, `stroke`, `sw` (stroke width), `r` (corner radius), `tap` |
| `circle` | `cx`, `cy`, `r`, `fill`, `stroke`, `sw`, `tap` |
| `line` | `x1`, `y1`, `x2`, `y2`, `stroke`, `sw` |
| `text` | `x`, `y`, `s` (the string), `fill`, `size`, `align` (`left`/`center`/`right`) |
| `path` | `d` (an SVG-style path string), `fill`, `stroke`, `sw`, `tap` |
| `input` | `submit` (the action name), `x`, `y`, `w`, `value`, `placeholder`, `max` |
| `image` | `x`, `y`, `w`, `h`, `b64` (a base64 raster image), `tap` |

`rect` and `circle` also take a `grad` instead of a flat `fill`; see below.

`cells` is the workhorse for boards, heatmaps, and automata: a grid of palette indices drawn in one op.
By default it fills the whole scene.
Give it `w` and `h` (and `x`, `y`, which default to the origin) to place it, so a grid can be one part of a scene next to labels, buttons or other art rather than the whole of it.
Both the painting and the tap reading follow the box, so a tap outside it falls through to whatever op is underneath.
A `w` or `h` that is missing or not positive describes nothing, so the grid falls back to filling the scene rather than disappearing.
`cols` and `rows` are each capped at **128** and clamped at parse, so a grid asking for more draws at the cap rather than not at all.
That is where a cell stops being something a person can see or aim at - about three points across on a phone - and where one paint stays inside a frame; the largest grid any shipped module uses is 48 by 48.
An op slim does not recognise is skipped rather than failing the scene, so a new op is an additive change a newer client can use.

### Arbitrary shapes with `path`

`path` takes a `d` string in a subset of SVG's path grammar, so anything you can describe with lines and curves you can draw.

```json
{ "op": "path", "d": "M 10 80 C 40 10 65 10 95 80 Z", "fill": "accent-soft", "stroke": "accent", "sw": 2 }
```

The commands are `M` (move), `L` (line), `H` and `V` (horizontal and vertical line), `Q` (quadratic curve), `C` (cubic curve) and `Z` (close).
Lowercase means relative to where the pen is.
Coordinates are in the scene's own logical units, the same as every other op.

Three things to know:

- Arcs (`A`) and smooth continuations (`S`, `T`) are not in the grammar. Express them with `Q` or `C`.
- A `d` that stops making sense is truncated at that point rather than failing, and whatever parsed before it is still drawn. A letter the grammar does not know ends the path there, so a stray `A` costs you the rest of the shape - it does not mangle what came before.
- A path may carry a `tap`, hit-tested against its filled interior. A `tap` on an unfilled outline has almost nothing to land in, so give a tappable path a `fill`.

One path is capped at 512 steps. A scene is a small drawing, not an illustration format.

### Images with `image`

`image` carries a raster image inside the scene as base64:

```json
{ "op": "image", "x": 10, "y": 10, "w": 40, "h": 40, "b64": "iVBORw0KGgo..." }
```

It draws stretched to the rectangle you gave, so you control the aspect by choosing `w` and `h`. It can carry a `tap` like a rect.

This is the one op whose cost you choose rather than slim, so it is the one with hard ceilings:

- **the base64 string is capped at 88k**, about 64k of image. That is a sprite, an icon, a small chart. It is deliberately far too small for a photograph: a scene sits next to message attachments rather than replacing them, and a module with a real picture to show should post one.
- **eight images per scene.** Each is a decode, and a decode is the most expensive thing a scene can ask a client to do. A scene wanting a hundred is a scene that should be one image.
- a payload over either ceiling, or one that is not valid base64, or one slim cannot decode as an image, is **skipped** - the rest of the scene still draws.

Decoding is asynchronous, so an image appears a frame or two after the rest of the scene rather than instantly. It still paints in op order, so a rect you draw after an image covers it, exactly as it would cover a circle.

If you re-emit the same image every frame, it is decoded once. Slim keys the decode on the bytes, so an unchanged picture costs nothing after the first frame.

### Gradient fills

`rect` and `circle` take a `grad` in place of a flat `fill`:

```json
{ "op": "rect", "x": 0, "y": 0, "w": 100, "h": 40, "grad": { "from": "accent", "to": "bg", "dir": "v" } }
```

`from` and `to` are colours like any other - a theme token or a `#hex`. `dir` is `v` (top to bottom, the default), `h` (left to right) or `d` (diagonal).

Two stops only. If you need a third, draw two shapes.

A gradient wins over `fill` when both are set. A gradient missing either stop is not a gradient at all, and the shape falls back to its `fill` rather than disappearing - a flourish should never be able to take the shape with it.

### Asking for words with `input`

`input` puts a real text field on the canvas, so a scene can be answered in words rather than only in taps.

```json
{ "op": "input", "x": 10, "y": 40, "w": 80, "submit": "guess", "placeholder": "your guess", "max": 20 }
```

A submission arrives as the action `"guess:otter"` - the same colon-separated shape a tapped cell already uses - with the text trimmed.

Four things to know:

- **You declare where and how wide; slim decides how tall.** A module cannot describe a control that looks native at an arbitrary height, and a field that does not match the rest of the app is worse than one you could not place to the pixel.
- **You own the value.** Whatever `value` you send back in the next scene is what the field shows, so you can correct, clear or reformat what somebody typed. The one exception is a field they currently have focused: a scene arriving mid-typing leaves it alone rather than overwriting under their cursor.
- **`submit` is required** and must be non-empty, because nothing could report a submission otherwise. An op without one is skipped.
- **`max` is clamped** to 512 characters. The text rides back to you on every submission, so a module cannot ask for an unbounded one.

An `input` op carries no `tap`. A tap in its area goes to the field, never to the scene underneath it.

### Motion

A `rect`, `circle`, `line` or `text` op may carry a `sweep`, and slim plays it locally with no further call to your module.

```json
{ "op": "rect", "x": 4, "y": 12, "w": 3, "h": 68, "sweep": { "dx": 149, "secs": 2 } }
```

- `dx` and `dy` move the op.
  `dw` and `dh` grow a rect's width and height, or a circle's radius (`dw`).
- `secs` is how long it takes and `delay` how long before it starts.
  Motion is linear, happens once, then holds.
- A scene stops moving after 10 seconds, delay included.
  Eight ops per scene may move, and later ones draw still.
- A new frame restarts the motion, which is how a playhead advances one step per frame.
- With reduced motion, or with the app in the background, the scene just shows where everything ends up.
- A `tap` on a moving op hits the place it was declared, not where it is now.

See decision 0043 for why this is declared motion and not a timer you control.

## Interactive scenes

A scene becomes interactive by offering `controls` and carrying `state`, and by drawing ops with a `tap`.

```json
{
  "$slim": "scene/1",
  "width": 3, "height": 3,
  "ops": [
    { "op": "cells", "cols": 3, "rows": 3, "data": "000010000", "palette": ["sunken", "accent"], "tap": "toggle" }
  ],
  "controls": ["step", "clear"],
  "state": "<opaque string the module hands itself back>",
  "live": true
}
```

- `controls` is a list of button labels shown under the scene.
  A label slim has an icon for gets the icon: `play`, `step`, `random`, `clear`, `reset`.
  Any other label is drawn as that label, and pressing it sends the label back as the action, so you can offer a verb slim has never heard of.
  Those five names are therefore reserved, and `play` is the one to watch: it drives slim's own animation loop, repeatedly sending `step` while the scene stays `live`, rather than sending you an action called `play`.
  If you want a button that plays something once, call it something else (`music-box` calls it `play tune`).
  The buttons wrap onto another line rather than being clipped, so offering several is safe on a phone.
- `state` is an opaque string slim stores and hands back on the next call - it is how a stateless module remembers the board between frames.
  Put whatever you need in it (packed cells, a generation counter, a seed); slim never looks inside.
- An op's `tap` makes it interactive.
  A `cells` op with `tap: "toggle"` reports a tapped cell as the action `"toggle:row,col"`.
  A `rect` or `circle` with `tap: "spin"` reports the bare action `"spin"`.
- `live` tells the client the scene can still change; a control press or tap while `live` re-invokes the module.

When a member presses a control or taps, slim calls the module's command again, with the `input` being a JSON object:

```json
{ "action": "step", "state": "<the state from the last scene>" }
```

The module reads `action` and `state`, computes the next frame, and returns a new scene (with a new `state`).
Return a scene with `live: false` to stop, or a non-scene/error to end with a message.
Because the frame is stored and broadcast, every viewer of the message sees the same evolving surface, and a long step runs once for everyone.

The Game of Life reference module (`slim-addons/modules/game-of-life`) is the worked example of this whole loop.

## Limits and the security model

A module that has no approved capability is pure compute with zero host imports.
It receives an input and returns an output and can reach nothing else - not the network, not the filesystem, not other modules, not slim's own state.
This is deliberate and is the base of the security model; [Host capabilities](#host-capabilities) says what an admin's approval adds.

Every `run` call is held to resource limits, taken from the manifest's `runtime.limits` or these defaults when unset:

| limit | default | meaning |
| --- | --- | --- |
| `memory_mb` | 16 | linear-memory ceiling for the call |
| `wall_ms` | 1000 | wall-clock deadline; a command is a synchronous request-response, not a background job |
| `fuel` | 50,000,000 | roughly one unit per executed instruction, so this bounds a runaway loop |

The `memory_mb` ceiling also bounds the rest of what the host allocates for the module before it runs a single instruction.
A module may declare one memory and one table, and is one instance; a second memory, table or instance is refused when the module loads.
Each table element is charged 16 bytes against `memory_mb`, so the default allows a table of one million elements and a module declaring `(table 400000000 funcref)` is refused at load instead of costing the server gigabytes.
A response may be at most 1 MiB (`MAX_RESPONSE_BYTES`) whatever the memory ceiling, and a larger one is refused.

Wasm runs in slices of about a million fuel and the deadline is checked between slices, so a run that passes `wall_ms` stops within a few milliseconds and stops using CPU, rather than returning to the caller while the module keeps running until its fuel is gone.

What the default fuel buys for text processing depends on how many times the module walks the input, not on how big the input is.
Measured on a release wasm built with `wasm32-unknown-unknown` (`opt-level = "s"`), ASCII input, default 50,000,000 fuel, the largest input that still completes is roughly:

| passes over the input | `.chars().count()` | `.chars().filter(..).count()` | `.chars().filter(..).map(..).collect::<String>()` |
| --- | --- | --- | --- |
| 1 | 14.1 MB | 950 KB | 580 KB |
| 3 | 6.4 MB | 320 KB | 195 KB |
| 8 | 2.7 MB | 120 KB | 73 KB |

Each row counts the UTF-8 validation of the input as one pass, so a module that parses its request is never at zero.
A pass that decodes characters and does a little work per character costs on the order of 50 fuel per input byte, and one that also builds a new string costs on the order of 90.
Non-ASCII text costs more per byte, and a different toolchain or optimisation level will move all of these numbers, so treat them as an order of magnitude and measure your own module.

The `code-block-runner` route accepts request bodies up to 256 KB, about three times what a few such passes can cover under the default.
A module that walks the input more than a couple of times should raise `runtime.limits.fuel` in its manifest rather than expect the default to reach the body limit.
The host caps a manifest at 2,000,000,000 fuel (`MAX_FUEL`), 40 times the default.
`wall_ms` is capped at 10,000 (`MAX_WALL_MS`) and `memory_mb` at 256 (`MAX_MEMORY_MB`); fuel and wall-clock are independent limits and either one ends the run.

Set them higher in the manifest if your module genuinely needs it (Game of Life uses 64 MB / 2 s), but a shared row that rides fan-out is capped well below whatever a module can produce, so enormous output is truncated regardless.

## Host capabilities

A module with no approved capability runs on the import-free ABI and can import nothing from the host.
The host implements two capabilities (`HOST_CAPABILITIES` in `crates/slimm-server/src/http/module_host.rs`), both in the module's `capabilities` list and both reached through `slim.host_call`.
A run may use a capability only when it is declared in the manifest, approved by an admin for that install, and implemented by the host.
Anything else gets a clean `{ "ok": false, "error": ... }` response, never a trap (`module_runtime/capabilities.rs`).

- `kv.store`: a key-value store private to the module, durable across runs.
  Keys are at most 256 bytes, values 4 KiB, a module holds at most 256 entries and 64 KiB, and one run makes at most 64 calls.
  Uninstalling the module wipes its data; a reinstall or upgrade keeps it.
- `message.post`: posts a message as the person who ran the module, into the channel they ran it from.
  The invoker needs view and send permission there, and slow mode and rate limits apply as for any send.
  A run may attempt three posts, and a message carries a `via <module name>` footer.
  Runs started from a code block (`code-block-runner`) get no `message.post`, because the input there is whoever wrote the message, not whoever clicked Run.

The Dock install screen lists each capability with a switch that starts off.
Approval is per install, and an update that names no approvals keeps the earlier ones.
The exception is `message.post`: a new build of the wasm has to be approved for it again, while `kv.store` carries over.
A module installed before the approval column existed started with none.
Decision [0023](../decisions/0023-mediated-host-capabilities.md) has the reasoning and its 2026-09-29 addendum has the details.
An unknown capability string is still accepted and ignored, so declare only the two above.

## Publishing a module

Modules are served from a registry: a static site (or repo) with an index and one directory per module.
The reference registry is [slim-addons](https://github.com/Slim-m-org/slim-addons), and its layout is the contract:

```text
index.json                         # the catalogue
modules/<id>/manifest.json         # the module's manifest (latest version)
modules/<id>/<version>/module.wasm # the pinned artifact for each version
```

`index.json` lists every module with just enough to browse:

```json
{
  "schema": 1,
  "modules": [
    { "id": "dice", "name": "Dice", "version": "0.3.0", "summary": "Roll dice notation like 2d20+3." }
  ]
}
```

To publish or update a module:

1. Build the wasm and put it at `modules/<id>/<version>/module.wasm`.
2. Compute its SHA-256 and set `artifact.sha256` and `artifact.path` in the manifest.
3. Bump `version` in both `manifest.json` and `index.json`.
4. Serve the registry over HTTPS and point a deployment's Dock at it.

A deployment installs a module by version, and slim records the manifest's extension points **at install time**.
That means changing a manifest in place does not change an installed module - a deployment must upgrade to the new version to pick up new extension points or permissions.
Bumping the version is therefore the deliberate act that offers an upgrade, even when the wasm itself is unchanged.

An installed module never runs a wasm whose SHA-256 does not match its manifest, so re-hosting a tampered artifact under the same version cannot take effect.

## Testing a module

Because a module is a pure `{command, input} -> {ok, output}` function, most of it can be tested as ordinary code in whatever language you wrote it in, before any wasm is involved.
The reference modules keep their logic (parsing, the automaton, the scene builder) in plain functions with unit tests, and keep the ABI `run`/`alloc` shim thin.

To test the whole thing end to end, install the built wasm on a dev deployment, grant yourself its permission, and exercise it from chat.
A scene is easiest to iterate on this way, since the interactive loop only exists once the client is painting it.

## Forward compatibility

The contracts here are versioned, and each grows additively (see decision 0022):

- An unknown extension-point kind, an unknown capability, and an unknown scene op are all accepted and ignored rather than rejected, so a module can target a newer client on an older server.
- The manifest envelope (`schema`) and the ABI (`v1`) are the two things a breaking change would bump; everything else grows within them.

Build against the contract, not against a particular client's current rendering, and your module keeps working as slim grows.

### Grid data is not re-strided when cols or rows are clamped

The client clamps `cols` and `rows` to 128, but it does not re-stride `data`.
A 200x200 grid therefore does not render as a cropped 128x128; its cells scatter along a repeating diagonal.
Lay `data` out at the stride you actually declare, and keep both within the clamp.

### An over-ceiling scene is refused, not cut

Plain-text output is truncated at the shared output ceiling with a marker.
A scene is JSON, so it cannot be truncated without becoming unparseable; a scene over the ceiling is refused as a failed run with a message saying so.
