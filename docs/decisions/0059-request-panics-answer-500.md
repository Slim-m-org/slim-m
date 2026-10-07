# 0059 - A panic in a request handler answers 500; any other panic still ends the process

Status: accepted, 2026-10-07.

## The problem

The release profile set `panic = "abort"`, so any panic reached from a request ended the whole server until Docker restarted it, and cut every in-flight write.
The 2026-09-30 audit proved it: a module scene with a sweep delay of 9.9 s or more panicked in `scene_limits::clamp_one`, which made one member's bad input an outage for everyone.
That bug was fixed in #1538, but the next handler bug would do the same thing.

Abort did have one property worth keeping.
Background sweeps, socket connection tasks and work spawned off a request have nothing watching them, so with plain unwinding a panic there would end that task silently and leave the process running without it.
Abort turned those panics into a restart, which brings every sweep back.

## Decision

The release profile unwinds, and the server separates the two cases (`crates/slimm-server/src/http/panic_guard.rs`):

- `http::guard_panics` wraps the router. A middleware marks the request's own task with a task-local, and tower-http's `CatchPanicLayer` turns a caught panic into the same 500 body an `ApiError::Internal` sends. The process keeps serving.
- `panic_guard::install_hook`, installed at the top of `run`, keeps the default panic report and then aborts unless the panic happened on a marked request task. Sweeps, socket tasks and anything a handler spawns are not marked, because a task-local does not cross `tokio::spawn`, so their panics still end the process and Docker restarts it, as before.

Tests and debug builds always unwound, so their behavior does not change.

## Cost

Measured on 2026-10-07 with the release profile on the same tree:

- Binary: 9.73 MiB with abort, 11.37 MiB with unwind, +1.64 MiB (17%), against the 20 MiB budget in `server-ci`.
- Idle RSS after 200 requests: about 14.6 MB with abort and 15.2 MB with unwind, three runs each.

## Poisoned locks

A panic while a handler holds a `std::sync::Mutex` poisons it, so a caught panic could leave later requests failing on that lock.
Checked on 2026-10-07: every std lock on the serving path (the rate limiter, presence, typing, viewing, ephemeral, route timing, the gif and link preview caches, the push debounce and the hub memory guard) already takes the guard back with `into_inner()` when poisoned.
The one `lock().unwrap()` left is `module_runtime::InMemoryKv`, the reference backend only tests use.
A new std lock on a request path should follow the same pattern.
