# 0022 - Module extensibility and evolution

Status: accepted
Date: 2026-09-07

## The ask

The module system should be able to grow to host whole classes of thing that do not exist yet - a theme, an app-like panel, a channel with its own UI (a podcast channel), a surface that appears in reaction to an event (a streamer's corner), an in-chat game - without a later redesign of slim's core.
The owner's framing: "we don't need to think about doing any of those, we just need to make sure the core supports it."

This record does not add any of those features.
It states the contracts that make each of them an *additive* change, the invariants that keep them additive, the guard tests that lock those invariants, and the one foundation that is deliberately deferred.

## The principle it rests on

A module extends slim through a bounded contract slim exposes; it never patches slim.
"Modify core functionality" therefore means "fill a richer extension point," not "reach into slim's code."
This is what keeps the system maintainable and is why a stock slim with no modules installed still works: an empty Dock, no runnable code blocks, no slash commands beyond the built-in text ones, and nothing to execute.
See decision 0021 for the module system itself; this record is only about how it evolves.

## The versioned contracts and how each one grows

Every seam between slim and a module is versioned, and each has a defined evolution rule.

- **Manifest envelope** (`schema`): a coordinated bump.
  A `schema` the server does not recognise is rejected cleanly ("unsupported manifest.json schema version"), not crashed on.
  Structural changes to the manifest itself ride a schema bump; everything below grows *within* schema 1 without one.
- **Extension-point kinds**: additive.
  A kind the server does not recognise is accepted, stored, and ignored, so a future `theme` / `panel` / `channel-surface` / `event-handler` kind installs on today's server and is simply invisible until a client understands it.
- **Capabilities**: additive.
  A capability string the server does not recognise is accepted and stored on the install record.
  Enforcement of a capability is a separate matter (see the deferred foundation below); declaring one is always additive.
- **Scene contract** (`$slim: "scene/N"`): a versioned envelope with additive ops.
  A client that does not recognise the version renders nothing rather than crashing; within a version, an op a client does not recognise is skipped, so a new op (`path`, `image`, `input`, a gradient) is additive.
- **Wire frames**: additive.
  A `ServerEvent` type an older client does not recognise is ignored, so a new broadcast (for an event-driven module, say) does not break existing clients.
- **Module ABI** (`alloc`/`run`, import-free): versioned as ABI v1.
  A different execution contract is a new ABI version, not an edit to this one.

## The invariants, and where they are locked

The additive behaviour above is only useful if it cannot silently regress into a hard rejection under a later refactor.
Each is now held by a guard test:

- An unknown extension-point kind and an unknown capability still parse: `crates/slimm-server/src/http/dock/manifest/tests.rs::accepts_an_unknown_extension_point_kind_and_capability`.
- An unknown scene op is skipped: `client/packages/app/test/features/modules/module_scene_test.dart` ("skips unknown ones").
- An unknown wire frame is ignored: `client/packages/api/test/code_run_event_test.dart` ("an unknown frame type is ignored, not thrown").

A change that makes any of these reject-or-throw instead of ignore is a breaking change to the extension contract and must fail one of these tests first.

## How each future class plugs in

None of these is built here; each is named so its shape as a bounded addition is on record.

- **A richer in-chat game or tool (a slot machine)**: already expressible today via the scene contract's interactive path (a scene plus controls plus opaque state, the Game of Life shape) - no new contract needed, at most richer scene ops.
- **A theme**: a `theme` extension-point kind whose module emits a design-token set the client applies through its existing token system - a bounded token override, never arbitrary styling.
- **An app-like panel**: a `panel` extension-point kind the client hosts as a full surface, rendered through the scene contract (or a richer UI contract) rather than inline in a message.
  The inline half of this shape already exists as the `app` kind (decision 0021, "The slash-command and app extension points"); `panel` would be the same command hosted as a full surface.
- **A channel with its own UI (a podcast channel)**: a `channel-surface` extension-point kind that supplies a channel body the client renders, with the server carrying a module-defined channel kind.
- **A surface that reacts to an event (a streamer's corner)**: the ambitious one, and the reason for the deferred foundation below - it needs a module to receive host events and manage a surface, not just answer a request.

Each is a new bounded contract plus a client renderer, reviewed on its own; none is a change to how modules already installed behave.

## The one deferred foundation

Everything above is additive on top of the current model, in which a module is **pure compute with zero host imports**: it receives an input and returns an output, and can reach nothing else.
That model is deliberate (maximum isolation) and is enough for commands, code runners, slash commands, scenes and in-chat games.

The classes that go beyond drawing-from-input - a module that posts a message, stores state, or reacts to an event (the streamer's corner) - need **mediated host capabilities and host-to-module events**: specific, capability-gated calls the host allows a module to make, and events the host pushes to a module that runs reactively rather than only on a user's request.
The slots for this are already pre-wired: capabilities are declared in the manifest and stored on install (`message.post`, `kv.store`, ... today declared but not enforced), and the permission-and-capability checks exist.
Wiring them is a future phase (a host import surface behind the capability gate, plus a reactive execution model), not a redesign - the contracts point at it.
That phase is now designed in decision 0023, which fixes the host-import ABI, the capability gating, and the phasing without building the surface.
Real-time or high-framerate rendering is a separate frontier again (a client-side wasm runtime), tracked in the backlog.

## Guardrails

The power to host these classes must not become the power to do anything.
Two rules keep it bounded:

- Growth happens by adding a bounded, reviewed contract, deliberately, one at a time - never by opening a general hole for arbitrary module code or UI to touch slim's internals.
- Each new contract carries its own security review, because the more a class can affect (a theme, a channel surface, a host call), the larger its trust surface; the isolation that makes a scene safe is not automatically the isolation a host call needs.
