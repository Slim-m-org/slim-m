# 0007 - Extensions, and why untrusted execution can only ever live behind one

Status: superseded by [0021](0021-modules-and-the-dock.md), 2026-08-03.
Raised by the owner in the `backlog` channel: first as "is it possible to let people run code, like how jupyter notebooks function", declined as a built-in, then as "perhaps we can backlog a plan for it, like a plugins marketplace and they could choose to configure code execution blocks etc".

## Why the direct version was declined

The ask was a containerised runner on the server that executes code from a message and renders the output.
Nothing about that is technically out of reach.
What makes it wrong *as a built-in* is where it lands: this project ships one server binary that a person runs on a box at home, and a feature in that binary is a feature on every deployment.

Untrusted execution needs container escape hardening, a per-user CPU and memory budget, a network egress policy, a filesystem with nothing of ours mounted into it, and an operator-reachable off switch.
That is more security surface than the rest of slim-m combined, and every self-hoster would inherit it whether or not they wanted it.
The owner's own framing of the product is small self-hosted friend groups with no automated scanning; a general-purpose code runner is a different product with a different threat model.

So the answer is not "no forever".
It is that the *unit of opt-in is wrong*: a built-in is opt-out per operator, and this needs to be opt-in per operator, per deployment, per install.
That unit is an extension.

## The shape

**An extension is a separate process the server talks to, never code loaded into it.**
This is not a preference, it is the whole safety property.
The server process holds the SQLite file, the media root, the LiveKit API secret and every session token; anything sharing that address space has all of it.
There is an existing precedent in the repo for exactly this seam: the push relay is already a separate stateless service the server speaks a defined protocol to, and `PushSender` models its absence as a two-state thing rather than an error path, because a LAN-only self-host has nowhere for a relay to reach.
Extensions get the same treatment - absent is a normal state, not a degraded one.

**The server brokers, it never executes.**
An extension declares what it wants; the server decides what it gets and enforces it at the boundary.
The server's job is authorization, scoping and ceilings, and it should be possible to read the whole security story out of the broker without reading any extension.

**Data reaching an extension is scoped to what invoked it, never to the deployment.**
This is the constraint most likely to be got wrong, because the easy implementation hands an extension a token that can read the API.
Security here is transport-only by owner decision, which means the server holds plaintext for everybody - so an extension with a general read capability can read every message in the deployment.
An invocation should carry the message that triggered it and nothing else, with any wider read being a separate, separately-granted capability that an operator has to mean.

**Ceilings are the server's, not the extension's.**
A wall-clock timeout, an output byte ceiling, and a rate-limit class, set and enforced by the server, in the same style as `MAX_PROPS_BYTES`, `SYNC_RESPONSE_BYTES` and the existing rate-limit classes.
An extension that misbehaves must fail its own invocation and nothing else.
Note the existing precedent that a ceiling refused *before* work starts leaves nothing to reclaim, and that two callers racing a ceiling landing slightly over is the right trade against serialising everything.

**Permission is a bit, and it is not `@everyone` by default.**
The canvas is the cautionary example in this repo: `USE_CANVAS` shipped to `@everyone` with no removal path at all, which is why that slice needed three separate hard ceilings before it could be merged.
An extension invocation bit should default to nobody and be granted deliberately.

**A marketplace is a directory, not an app store.**
At this scale the discovery problem is a list of things an operator can choose to run, with what each one asks for stated plainly.
It must never become a channel that pushes code onto a running deployment: an operator installs an extension the way they add a service to their compose file, deliberately and visibly.
Anything that auto-installs reintroduces exactly the every-deployment-inherits-it problem this whole record exists to avoid.

**Advertising which extensions a deployment runs should reuse the capability handshake.**
`GET /version` already carries a `capabilities` array derived by probing the real router rather than from a hand-kept list, precisely so a safety claim cannot rest on somebody remembering to update it.
Whatever answers "what does this deployment support" for extensions should be derived the same way, for the same reason.

## This does not reopen the client-plugin decline

`docs/BACKLOG.md` already lists "Client plugin or scripting system" as deliberately out of scope, and that stands.
The two are different things and the reasons do not transfer.
A client plugin is sideloaded code running inside the app on somebody's phone, which has no viable story under App Store rules and puts arbitrary code next to the user's own session.
An extension here is a process the *operator* runs on their own server, next to the server they already run, reached over a protocol - the same relationship the push relay already has.
Nothing in this record proposes loading anything into the client.

Two other existing entries are absorbed rather than contradicted.
"Server-side link previews and URL unfurling" is already recorded as acceptable only as an opt-in, egress-sandboxed fetcher, which is exactly an extension.
"Slash-command registration framework" was declined as platform scope creep on its own; behind a broker that already exists for other reasons it is a much smaller ask, though still not automatically worth doing.

## What this buys, beyond code execution

Code execution is one extension, and probably not the first worth building.
The same broker covers webhook and bot authorship, which `CLAUDE.md` already records as deliberately unbuilt with a UI marker left standing for it; slash commands; and link or media unfurling, which has the same "a server reaches out to a URL a user chose" hazard and would otherwise need its own bespoke sandboxing argument.
Building the broker once and putting three things behind it is a better trade than three special cases.

## Not decided here

The wire protocol, whether extensions are discovered at startup or registered at runtime, whether an extension can write messages or only answer with a rendered result, and how a rendered result is carried on a wire that is additive-only and hand-written on both sides.
None of that is worth settling until something is actually being built against it.

## Status of the original ask

Declined as a built-in and marked as such in the `backlog` channel.
Recorded here as the shape it would take if it is ever picked up, so the decline is a design position rather than a shrug.
It was picked up as the Dock, a module system an admin opts into per install, which is decision 0021; the broker shape described here is not what shipped.
