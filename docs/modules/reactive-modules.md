# Building a reactive module

This guide covers the module platform's phase 1 contracts: a module that reacts to events, keeps structured data, reads durable logs, has settings an admin edits, and shows content on member profiles.
Read [building-modules.md](building-modules.md) first for the ABI, the command protocol and the base manifest; everything here is additive to it.
The contracts are fixed in decision [0091](../decisions/0091-module-platform-phase-1-contracts.md), and the reference module is `modules/xp` in [slim-addons](https://github.com/Slim-m-org/slim-addons).

A module that uses none of this behaves as before.
A manifest that uses any of it sets `"addon_api": 1`.
A server that supports a lower `addon_api` refuses the module with a clear reason, and an older server that does not know the field ignores it.

## The pieces

| piece | manifest | needs approval |
| --- | --- | --- |
| Events pushed to the module | `subscriptions` and capability `events` | yes |
| A structured data store | `data` and capability `data.store` | yes |
| Durable logs read with a cursor | capability `log.read` | yes |
| Values an admin sets | `settings` | no |
| Content on profiles and next to names | `slots` | no |

The approvable capabilities are `kv.store`, `message.post`, `net.fetch`, `schedule`, `events`, `data.store` and `log.read`.
`events`, `data.store` and `log.read` are asked again at the install screen after a new build of the wasm, like `schedule`.
The consent screen lists each in plain words, including which events, which logs and the size cap.

## Two commands the host calls

Events and slots reach the module as ordinary runs with a reserved command name.
They are not declared as extension points, and the module routes on `command` like any other:

| command | when | `input` |
| --- | --- | --- |
| `@event` | a subscribed event happened | the JSON text `{"event","id","at_ms","data"}` |
| `@slot` | a member opened a profile or a list that shows a badge | the JSON text `{"slot","name","user_ids","viewer_id"}` |

A module with `subscriptions` that returns `{ok:false}` for `@event` counts every event as a failed run, so route it.
Return `{ok:true}` for an event you choose to ignore.

Every run also carries `settings` (see [Settings](#settings)) beside `command`, `input`, `caller`, `entropy` and `now_ms`.

## Events

```json
"capabilities": ["events"],
"subscriptions": [{ "event": "voice.session.closed" }, { "event": "message.created" }]
```

At most 8 entries, each event once, and `subscriptions` needs the `events` capability.
The events:

| event | `data` fields | `id` |
| --- | --- | --- |
| `message.created` | `message_id`, `channel_id`, `author_id` (null when there is none), `content` (the stored text), `created_at_ms`, `is_bot` | `message:<message id>` |
| `message.deleted` | `message_id`, `channel_id` | `message-deleted:<message id>` |
| `reaction.changed` | `message_id`, `channel_id`, `emoji`, `count` | `reaction:<message id>:<emoji>:<ms>` |
| `member.joined` | `user_id` | `member-join:<user id>:<ms>` |
| `member.left` | `user_id` | `member-leave:<user id>:<ms>` |
| `voice.session.closed` | `session_id`, `user_id`, `channel_id`, `joined_at_ms`, `left_at_ms`, `alone_ms` | `voice-session:<session id>` |

`reaction.changed` is sent once for each emoji whose count moved, with the new count (0 when the last reaction was removed).
`id` is minted once per delivered event and the host never redelivers, so it names that delivery.
`at_ms` is the occurrence time where the event has one and the time the host saw it otherwise.

Who receives what:

- An event in a channel the module's own principal cannot view is not delivered, so a module only hears about a private channel its principal has view access to.
- Direct message content is never delivered.
- `caller.id` in an event run is the module's own principal, never the author of the event.
- An event run that calls `message.post` posts as that principal into the channel the admin chose on the module's Dock screen, the one scheduled runs use.
  With no channel chosen, `message.post` is refused.

How delivery behaves:

- Each module has its own queue of 256 events.
- Access is checked again when an event is delivered, so one for a channel the bot can no longer view, or a new message deleted while it waited, is dropped.
- A module is not sent the messages its own bot wrote.
  When it is full the oldest event is dropped and the drop is counted.
- A module gets one event at a time, in the order queued.
  Events and schedules share a lane of 2 concurrent runs across all modules, separate from the 4 slots members' commands use.
  Slot answers have their own lane of 2.
- After 5 failed runs in a row (a trap, a timeout, running out of fuel, or `{ok:false}`) the module is disabled with a reason the admin sees.
  A success resets the count.
  Scheduled runs count toward the same streak.
  Slot runs never do, because a member viewing a profile must not be able to turn a module off.
  A run the host turned away because it was busy does not count.

**Treat a push as a trigger, not as the data.**
Delivery is best-effort: events can be missed across a server restart, dropped from a full queue, or never sent while the module was disabled.
A module that must not lose or double count anything should, on each event and on a timer, reconcile from a durable log (next section) and make every write idempotent.

## Durable logs: `log.read`

```json
{ "capability": "log.read", "log": "voice.sessions", "after": 0, "limit": 100 }
```

The reply is `{ "ok": true, "rows": [...], "next": 123 }`.
Send `next` as `after` on the next read; when there are no rows, `next` is the `after` you sent.
`limit` defaults to 100 and is at most 200, and `after` defaults to 0.
Store the cursor yourself, in `data.store` or `kv.store`, and move it only after the work for those rows succeeded.

Phase 1 has one log, `voice.sessions`, with one row per closed voice session, in the order they closed:

```json
{ "id": 41, "user_id": "...", "channel_id": "...", "joined_at_ms": 1760000000000, "left_at_ms": 1760000600000, "alone_ms": 120000 }
```

- `id` is the same number as `session_id` in the `voice.session.closed` event, so an event and the log agree about which session is which.
- Only closed sessions are returned.
  A session left open by a missed leave is closed when its room finishes, when its heartbeat goes stale, or at server startup, which caps its length.
- Rows are returned in the order they closed, whatever order they opened in.
  A long call that is still open never holds back sessions that closed after it opened.
  A session that closes later is numbered later, so a cursor is always safe to advance to `next` and never skips or repeats a row.
- `next` is a close-order cursor, not a session `id`.
- Closed sessions are kept 90 days, and a member's sessions are removed when their account is deleted.
- Only a module with an approved `log.read` can read them, and the consent line says it can see when members are in calls.

### `alone_ms`

`alone_ms` is how much of the member's session was spent with nobody else in the same call.
It is the part of `joined_at_ms` to `left_at_ms` that no other member's session in that channel overlapped, in milliseconds.
A member who was alone the whole time has `alone_ms` equal to `left_at_ms - joined_at_ms`, and one who was never alone has 0.
Other members count whatever they are, so a bot sitting in the call is company.
To count only time with others, use `left_at_ms - joined_at_ms - alone_ms`.

## Structured data: `data.store`

Declare the tables, and the host builds and runs every statement itself.

```json
"capabilities": ["data.store"],
"data": {
  "max_mb": 8,
  "tables": [{
    "name": "xp",
    "columns": [
      { "name": "user_id", "type": "text", "unique": true },
      { "name": "points", "type": "int", "index": true }
    ]
  }]
}
```

- Column types are `int`, `real`, `text` and `bool`.
  `unique` and `index` add an index of that kind.
- At most 8 tables and 16 columns per table.
  `max_mb` is the file cap, 1 to 64, default 8.
- `data` needs the `data.store` capability.
- The host adds an integer primary key `_id` to every table, so you cannot declare a column of that name.
- The store is one SQLite file per module (`<modules dir>/<module id>.db`), so no module can reach another's.
  Uninstalling keeps it unless the admin asks to delete the data, and a reinstall or upgrade keeps it too.
- A newer manifest may add tables and columns.
  In the first version it may not remove or retype one.

### Names

A table or column name is 1 to 32 lowercase letters, digits or underscores, and starts with a letter.
It must not be reserved.
A reserved name makes the whole manifest invalid, so the module cannot be read or installed from the Dock, and the module detail route answers 502 with the reason.
The reserved names are every SQLite keyword the host lists, `rowid`, `oid`, and any name starting with `sqlite`:

```text
abort action add after all alter always analyze and as asc attach autoincrement
before begin between by cascade case cast check collate column commit conflict
constraint create cross current current_date current_time current_timestamp
database default deferrable deferred delete desc detach distinct do drop each
else end escape except exclude exclusive exists explain fail filter first
following for foreign from full generated glob group groups having if ignore
immediate in index indexed initially inner insert instead intersect into is
isnull join key last left like limit match materialized natural no not nothing
notnull null nulls of offset on or order others outer over partition plan
pragma preceding primary query raise range recursive references regexp reindex
release rename replace restrict returning right rollback row rows savepoint
select set table temp temporary then ties to transaction trigger unbounded
union unique update using vacuum values view virtual when where window with
without rowid oid
```

The usual traps are `key`, `index`, `order`, `values`, `group`, `limit`, `offset`, `from`, `to`, `end`, `first`, `last`, `row`, `set` and `table`.
A key-value table is `name` and `val`, not `key` and `value`.
Settings keys are a different namespace and have no such list.

### Operations

Every call names `"capability": "data.store"`, an `op` and a `table`.

| `op` | other fields | returns |
| --- | --- | --- |
| `insert` | `values`, or `rows` (up to 50, all setting the same columns) | `rows: [{_id}]`, one per row in order |
| `upsert` | `values`, `on` (one unique column, which `values` must include), optionally `add` | `changed`, and the resulting row in `rows` when `add` is used |
| `update` | `values`, `add`, or both, and `where` | `changed` |
| `delete` | `where` | `changed` |
| `get` | `where`, `order` | `rows` with the first match, or none |
| `query` | `where`, `order`, `limit`, `offset` | `rows` |
| `count` | `where` | the number in `count` |
| `sum` | `col` (int or real), `where` | the total in `count` |
| `increment` | `col` (int or real), `by`, `where` | `changed` |

`add` is a map of `{column: number}` over `int` or `real` columns, and a column cannot be in both `values` and `add`.
On an `upsert` a new row gets the added amounts and an existing one gets `column = column + n`, in one atomic statement.
On an `update` it runs `column = column + n` in the same statement as any `values`.
A multi-row `insert` or an `add` is still one call of the run's budget.

Replies are `{ "ok": true, "rows": [...], "changed": n, "count": n }` or `{ "ok": false, "error": "..." }`.
Rows carry `_id` and every declared column.

```json
{ "capability": "data.store", "op": "query", "table": "xp",
  "where": [{ "col": "points", "op": "gt", "val": 100 }],
  "order": [{ "col": "points", "dir": "desc" }], "limit": 10, "offset": 0 }
```

- `where` is a list of conditions ANDed together, at most 16.
  The operators are `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `in` (a list of at most 100 values) and `like` (text columns only, with `\` as the escape).
  A condition value cannot be null.
- `update` and `delete` with no `where` affect every row.
- `order` has at most 4 entries, each `{col, dir}` with `dir` of `asc` or `desc`.
- `limit` is 1 to 200 and defaults to 200, and `offset` is at most 10,000.
- A `like` pattern is at most 256 bytes, and one statement carries at most 1 KB of them.
- A statement is interrupted after 250 ms, or sooner when the run has less wall clock left, and the call returns `{ok:false,error:"data call took too long"}`.
- A `text` value is at most 4 KB, a `bool` column takes `true` or `false`, and a value must match its column's type.
- `increment` adds `by` (default 1 for an int column, within plus or minus 2^53) and treats an empty value as 0.
  It is atomic, so use it instead of read, add, write.
- A unique column that already holds a value refuses an `insert` or `update` with `a unique column already holds that value`.
  That is how a module claims something once.
- `_id` can be filtered, ordered and read, and cannot be set.
- When the file reaches `max_mb` writes are refused with `data.store is full for this module`.

## Call budgets

A run is held to these host-call budgets, and they combine:

| budget | limit |
| --- | --- |
| host calls of any kind, refused ones included | 128 |
| `kv.store` and `data.store` calls together | 64 |
| `net.fetch` requests | 4 |
| `message.post` posts attempted | 3 |

`log.read` has no budget of its own: it spends only from the 128.
So a run can make at most 64 store calls and at most 128 calls in all, and a run that reads a log, writes 64 rows and fetches four pages has used 69 of the 128.
The 64 is the number to plan around, because most work is store calls.
Give a run a cost model, stop before the budget is spent, and carry the rest to the next run through your cursor, as `modules/xp` does.

## Settings

Values an admin sets on the module's Dock screen, so a rate or a name is not baked into the wasm.

```json
"settings": [
  { "key": "xp_per_minute", "type": "int", "label": "XP per minute", "help": "Earned while in a call.", "default": 5, "min": 0, "max": 100 },
  { "key": "curve", "type": "choice", "label": "Level curve", "default": "standard",
    "choices": [{ "value": "gentle", "label": "Gentle" }, { "value": "standard", "label": "Standard" }] },
  { "key": "api_key", "type": "secret", "label": "API key" }
]
```

- Types are `bool`, `int`, `string`, `choice` and `secret`.
- At most 32 entries and each `key` once.
  A key is lowercase letters, digits and underscores, up to 64.
- `label` is a few words (at most 40 characters) and `help` one short sentence (at most 140).
- Only an `int` has `min` and `max`.
  Only a `choice` has `choices` (1 to 16, each with a unique `value`), and a `choice` needs them.
  A `secret` cannot have a `default`.
- A `default` must satisfy the setting's own type and range.

Every run receives the current values as `settings: {key: value}`, with the manifest's defaults filled in.
Secrets are never in it, and `settings` is left out when there are no values.
A setting with no stored value and no `default` is absent from `settings`, so fall back to your own default and clamp what you read.
A change applies from the next run and is not retroactive: the module decides whether it touches work already done.

An admin edits them with `GET` and `PUT /space/dock/modules/{id}/settings`, both behind `MANAGE_SERVER`.
`PUT` takes `{values: {key: value}}`, where `null` clears a value, and checks each against the schema.
`GET` shows a secret as only `{set: true|false}`.

### Secrets

A secret reaches the network and nothing else.
In a `net.fetch` header, a value of `{"secret": "api_key"}` is replaced by the host with the stored value, for a host the module is approved to reach:

```json
{ "capability": "net.fetch", "url": "https://api.example.org/v1/me", "headers": { "Authorization": { "secret": "api_key" } } }
```

The module never sees the value.
A `secret` key that is not set is refused with `net.fetch names a secret that is not set: api_key`.
The object must hold exactly the one key `secret`.

## Slots

A slot is a place in slim's own UI where a module may show a small piece of content.
Slots need no capability.

```json
"slots": [
  { "kind": "profile.section", "name": "xp", "title": "Level" },
  { "kind": "member.badge", "name": "level" }
]
```

- The kinds are `profile.section` (a section on a member's profile) and `member.badge` (a short badge next to a name).
- At most 4 slots, each `kind` and `name` pair once, `name` at most 64 characters and `title` at most 40.
- Only an enabled module with `"addon_api": 1` is asked.

The host asks by running the module with `command: "@slot"` and `input` of `{"slot","name","user_ids","viewer_id"}`.
`slot` is the kind, `name` is the slot's name, `user_ids` are the members to answer for (one run covers every member the cache lacks, up to 100), and `viewer_id` is the member looking.
`caller.id` is the viewer's, the same as for any command that member runs.
Answer with an output string of:

```json
{ "$slim": "slot/1", "items": { "<user_id>": { "nodes": [ ... ], "fallback": "Level 4" } } }
```

Leave a member out of `items` to show nothing for them.
A run that fails, or an output that is not `slot/1`, shows nothing and counts as a failed run.

**The 30 second cache.**
The host remembers the answer for 30 seconds for each module, slot, viewer and member.
That includes the empty answer: a member you left out stays empty for 30 seconds even if they earn something a moment later.
Updating, disabling, uninstalling or changing the settings of the module drops its cache.
Do not expect a slot to change faster than that, and do not do work in a slot run that you cannot afford once per viewer per half minute.
Slot runs use a lane of their own (2 at a time, 2 seconds of waiting), one fill per member at a time, and a failed one never counts toward the circuit breaker.

### The `slot/1` vocabulary

| `type` | fields |
| --- | --- |
| `text` | `text` (at most 120 characters), `tone` (`normal`, `muted` or `accent`) |
| `icon` | `name`, from the closed list the bot UI already uses |
| `badge` | `text` (at most 24 characters), `icon`, `tone` |
| `progress` | `value`, `max`, `label` |
| `row` | `children` |
| `stack` | `children` |

An item has at most 40 nodes and a depth of 4.
A client that does not know a `type` skips that node, and shows `fallback` when it skipped every node, so always send a plain `fallback`.
The vocabulary only grows: fields are added and never repurposed.
There are no actions in phase 1, so a slot shows content and cannot be clicked into the module.

## A worked example: XP for time in calls

`modules/xp` in slim-addons is the reference.
It pays XP for time in voice calls and shows a level on the profile.
Its shape is the pattern to copy.

The manifest declares `events`, `data.store`, `log.read` and `schedule`, subscribes to `voice.session.closed`, has two tables, five settings and two slots, and one `catchup` command on a 5 minute schedule:

```json
"data": { "max_mb": 8, "tables": [
  { "name": "xp", "columns": [
    { "name": "user_id", "type": "text", "unique": true },
    { "name": "xp", "type": "int", "index": true },
    { "name": "last_session", "type": "int" } ] },
  { "name": "meta", "columns": [
    { "name": "name", "type": "text", "unique": true },
    { "name": "val", "type": "int" } ] } ] }
```

The `meta` table holds the cursor, with `name` rather than `key` because `key` is reserved.

One entry point routes the three ways in:

```text
@event  voice.session.closed  -> catch_up()
catchup (the schedule)        -> catch_up()
@slot                         -> read totals, return slot/1
```

The event is only a trigger.
`catch_up` does the work from the log:

1. Read the cursor: `data.store` `get` on `meta` where `name` is `voice_cursor`.
2. Read `log.read` `voice.sessions` after that cursor.
3. For each member in the rows, make their row if it is missing (`insert`, treating `a unique column already holds that value` as success).
4. Claim the member's newest session with a conditional `update`: set `last_session` to the session id where `user_id` matches and `last_session` is less than it.
   If `changed` is 0, an earlier run already took it, so skip the member.
5. Only after the claim, `increment` the member's `xp` by the sessions' worth.
6. Write the cursor with `upsert` on `name`, using the id of the last row handled.

The claim is what makes it safe to run twice: two overlapping runs, a lost cursor write or a repeated event cannot pay one session twice.
A crash between the claim and the `increment` loses that payment instead of doubling it, which is the right side to fail on.
The cursor is moved last and only for rows that were handled, so a failed run reads the same rows again.

It also counts its calls.
The 64-call budget covers up to 5 calls per member plus 2 for the pass (the log read and the cursor write), so one run handles about a dozen members and moves the cursor to just before the next, and the schedule finishes a backlog over several runs.

Time with others is `left_at_ms - joined_at_ms - alone_ms`, and the `only_with_others` setting decides whether time alone is paid.

The slot answer reads the totals for the asked `user_ids` with one `query` using `in`, and returns an item only for members with XP:

```json
{ "$slim": "slot/1", "items": { "<user_id>": {
  "nodes": [{ "type": "stack", "children": [
    { "type": "text", "text": "Level 4", "tone": "accent" },
    { "type": "progress", "value": 80, "max": 400, "label": "80 / 400 XP" } ] }],
  "fallback": "Level 4" } } }
```

## Testing a reactive module

`run-module` in slim-addons simulates `kv.store`, `net.fetch`, `message.post` and the clock.
It does not simulate `data.store`, `log.read`, events or slots.
Keep the host behind a small trait in your module, run the logic against an in-memory fake in unit tests, and cover the real thing by installing on a dev deployment (see Testing in [building-modules.md](building-modules.md)).
`modules/xp` does both, with `fake.rs` for the unit tests and an end-to-end script that plays signed webhooks against a real server.
Test the case that matters most for a reactive module: the event is missed, and the next pass still gets it exactly once.
