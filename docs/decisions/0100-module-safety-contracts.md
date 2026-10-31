# 0100 - Module safety: API ranges, interceptors and the deny hook

Status: accepted; built
Date: 2026-10-31
Extends: 0090 (primitive 2, interceptors), 0091, 0099

## Why this exists

Decision 0090 promised interceptors and a deny-only permission hook, and fixed the shape of both.
This record fixes the exact contracts, and records four smaller safety decisions that landed with them: a versioned add-on API, purging module data when a member leaves, and binding a secret to hosts.

## The add-on API and its range

`addon_api` already exists in the manifest (0091, 0099).
It is the oldest level the module needs.
This record adds the other end and the rules around both.

- The host publishes its level as `addon_api` on `GET /version`. It is 3 here: 1 is the platform, 2 adds private scenes, 3 adds interceptors and the permission hook.
- A manifest may add `addon_api_max`, the newest level it declares it works with. It names no upper bound by default.
- A module runs only when the host's level is inside `[addon_api, addon_api_max]`. This is checked at install (the manifest is refused with the reason), when the server starts (an installed module outside the range is turned off, with the reason shown in the admin's health card), when an admin enables it (refused with the reason), and before every run (a module outside the range is never started, so it is never half-run).
- Levels only add. A level never removes a field or changes what one means. If a removal is ever needed it ships as a new level, announced in `docs/modules/api-changelog.md` at least 180 days and two server releases earlier, and the old behaviour keeps working through that window. A module that wants to be locked out of anything it has not been tested against sets `addon_api_max`.
- Each contract inside a level has its own version, written in the data it carries: `event/1` (`"$slim"` on the pushed event), `slot/1`, `interceptor/1` and `permission/1`. A change to one bumps only that contract, and the changelog says so.

## Module data about a member

A `text` column in a module's data schema may set `"member": true`.
When the member's account is deleted, by themselves or an administrator, the host deletes every row whose member column holds their id, in every module's file, installed or not.
The alternatives were to deliver `member.left` and trust the author (not enforced) and to put module rows in the member's data export.
The first is documentation, not a guarantee.
The second needs the export pipeline to read module files and is a separate piece of work.
A removal that can be undone does not purge.

## A secret setting bound to hosts

A `secret` setting may list `hosts`, a subset of the module's `network.hosts`.
`net.fetch` then refuses to substitute it into a request to any other host, even one the module is approved to reach.
The check runs before the secret is read.
No list means any approved host, as before.

## Interceptors

An interceptor runs before a message is stored and can reject it, annotate it or rewrite it.

### Where they run

Every way a member-authored text message is created or edited passes through one function, `module_hooks::run_send` and `run_edit`:

- the send and edit routes, which also carry bots, because a bot is a member with a token;
- incoming webhooks;
- a module posting with `message.post` (a module's own interceptors are skipped for its own post).

Not intercepted, on purpose, and listed in the gate test that fails when a new path appears: the welcome post (admin-written text), poll and call messages, bot interaction messages (structured, not free text), and forwards (a copy of a message that already passed on creation).
The gate test scans the server source for every call of the store's message write functions and fails if a file calls one without calling the chain, unless that file is on the list with a reason.

### What a module declares

```json
"capabilities": ["interceptors"],
"interceptors": [
  { "hook": "message.pre_send", "phase": "reject", "reads": ["content", "channel_id"] },
  { "hook": "message.pre_edit", "phase": "rewrite", "reads": ["content"] }
]
```

- `hook` is `message.pre_send` or `message.pre_edit`. `phase` is `reject`, `annotate` or `rewrite`. At most 4 entries, one per hook and phase.
- `reads` is a subset of `content`, `channel_id`, `is_bot` and `reply_to_id`. The module is sent those fields and no others. The consent screen shows each hook and what it reads, and an update that adds a hook or a field asks again.
- Who wrote the message is the run's `caller.id`, the per-module id of 0038, never the account id.

### What a module is sent and returns

The run is `command: "@intercept"`, with `input` the JSON text `{"$slim":"interceptor/1","hook","phase","message":{...declared fields},"annotations":{...}}`, where `annotations` are those earlier modules in the chain set.
The module's admin-set values arrive in `settings` as for any run, which is where a word list lives.
The module has no host calls: no network, no storage, no posting.

- `reject`: `{"action":"allow"}` or `{"action":"reject","reason":"<up to 200 characters>"}`.
- `annotate`: `{"annotations":{"<key>":"<text>"}}`, at most 8 keys of 256 characters. They are stored in a side table beside the message and delivered to the same module in its `message.created` event data as `annotations`. No client shows them yet.
- `rewrite`: `{"content":"<the new text>"}`. The result goes through the same length and hidden-character checks as a member's text; a result that fails them counts as a failed run.

### Order

Phases run in the fixed order reject, annotate, rewrite.
Within a phase, an integer priority orders modules, lowest first, ties broken by install time.
The admin edits priority and sees the order.
A rewrite is passed down the chain, so later modules see the rewritten text.
A reject stops the chain and the sender gets a `403` with the module's name and reason.

### Budget, failure and the breaker

- Each run is held to 100 ms of wall clock and 10 million fuel, whatever the manifest asks for, on a lane of its own (4 at a time, and a run that cannot get a slot in 50 ms counts as unavailable).
- The whole chain for one message has a cap of 250 ms. A hook that cannot start inside the cap is treated as unavailable.
- A trap, a timeout, exhausted fuel, `ok:false`, a malformed reply or an unavailable slot is a failure of that hook.
- Fail open is the default: a failed hook is skipped, the message goes through as it was, and the failure is counted. An admin can set a hook to fail closed, and then a failure refuses the message with a plain "could not be checked" error.
  The owner confirmed this default on 2026-10-31: a broken or slow module must not be able to stop a space from talking, and an admin who wants a filter to be strict sets that one hook to fail closed.
- A failure counts toward the same circuit breaker as background runs. Five in a row turn the module off with the reason and an audit row, and any success resets the count. A lane that is busy is the host's load and is not counted.
- With no interceptor installed the chain is one atomic load and a return; it reads no table and takes no lock. The registry is rebuilt in memory when a module is installed, removed, enabled, disabled or reconfigured.

## The deny-only permission hook

A module may subscribe to the permission check of a short list of actions: `message.send`, `attachment.upload`, `reaction.add` and `voice.join`.

```json
"capabilities": ["permission.hook"],
"permission_hooks": [{ "action": "message.send" }]
```

- The hook runs only after the core check has allowed the action. It never runs for an action the core refused, so a module cannot grant anything: the only thing it can do to an allow is turn it into a deny.
- The run is `command: "@allow"` with `input` `{"$slim":"permission/1","action","channel_id","member_joined_ms"}`; the reply is `{"allow":true}` or `{"allow":false,"reason":"..."}`. Anything other than a well-formed deny allows.
- Same budget, lane, fail-open default, fail-closed switch and circuit breaker as interceptors. The admin orders them with the same priority.
- Channel-scoped overwrites for module permissions stay a later extension (0090).

## The admin surface

`GET /space/dock/hooks` lists every interceptor and permission hook in chain order with its priority, fail mode, run and failure counts, fuel used, and last failure.
`PUT /space/dock/modules/{id}/hooks` changes one hook's priority or fail mode.
Both need `MANAGE_SERVER`.

## Not decided here

- Interceptors on polls, calls and structured bot messages.
- A client rendering of annotations (the message decoration slot of 0090).
- Putting module rows in the member data export.
