# Wire protocol schema

`openapi.yaml` is the single source of record for the slim-m client-server wire protocol.

No types are generated from this file: the Rust DTOs and the Dart client models are both hand-written.
CI still gates real drift, just narrower than a codegen story would need: `crates/slimm-server/tests/openapi_contract.rs` fails if the router and the documented paths and methods disagree, `crates/slimm-server/tests/response_contract/` drives the operations here for real and checks the server's response bodies against the schema, and `crates/slimm-server/tests/ws_frame_contract.rs` does the same for the WebSocket frame set.
None of the three checks request bodies, and none checks the Dart models at all, so a client-side field can still drift from this file silently.
The schema evolves additive-only; an oasdiff breaking-change gate blocks incompatible changes on pull requests, and `redocly lint` gates valid OpenAPI.

The server-to-relay push envelope is a separate versioned contract that lives in the relay repository.

This directory is under the same license as the rest of the repository, see `LICENSING.md`.
