// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The documented refusals, driven on purpose.
//!
//! Everything else in this directory drives an operation to its success
//! status. `verdict::judge` used to treat any non-2xx as a bug in the script
//! and return before the schema was ever consulted, so the entire documented
//! error surface - 401 on 158 operations, 403 on 103, 400 on 87, 404 on 50,
//! 409 on 23 - was validated by nothing. A handler answering a 409 whose body
//! had drifted from `Error` passed every gate this repository has.
//!
//! A representative case per status rather than one per operation. The shape
//! being checked is `Error` itself - that the body is that object, under the
//! status the schema documents, with the content type it documents - and that
//! is the same object on every route, so driving one of each buys the whole
//! surface. What a per-operation sweep would add is the status-to-condition
//! mapping, which is a much larger job and is not what this closes.
//!
//! These calls deliberately do not count toward coverage; see
//! [`crate::response_contract::world::Contract::refuses`].

use serde_json::json;

use crate::response_contract::world::{Contract, Payload};

/// Drives one case per documented error status.
///
/// `invite` is load-bearing and was missing at first: the deployment is
/// invite-gated by the time the script reaches here, so a registration
/// without a code is refused for *that* and never reaches the username check.
/// The 409 case was a second 400 wearing a 409's comment until the statuses
/// were read back rather than assumed.
pub(super) async fn refusal_calls(c: &mut Contract, member: &str, admin_id: &str, invite: &str) {
    // 401: a token that never existed; unauthenticated_refusal.rs sweeps every operation.
    c.refuses(
        "getMe",
        "GET",
        "/me",
        Some("not-a-real-token"),
        Payload::None,
    )
    .await;

    // 403: an ordinary member reaching an ADMINISTRATOR-only route.
    c.refuses(
        "issueResetCode",
        "POST",
        &format!("/admin/users/{admin_id}/reset-code"),
        Some(member),
        Payload::None,
    )
    .await;

    // 404: a well-formed id belonging to nobody, so the handler refuses.
    c.refuses(
        "getUser",
        "GET",
        "/users/00000000-0000-0000-0000-000000000000",
        Some(member),
        Payload::None,
    )
    .await;

    // 400: a password under the floor, unauthenticated so it reaches validation.
    c.refuses(
        "register",
        "POST",
        "/auth/register",
        None,
        Payload::Json(json!({
            "username": "shortpw",
            "display_name": "Short",
            "password": "no",
            "device_name": "cli",
        })),
    )
    .await;

    // 409: a username somebody already holds; see this function's doc on the code.
    c.refuses(
        "register",
        "POST",
        "/auth/register",
        None,
        Payload::Json(json!({
            "username": "admin",
            "display_name": "Impostor",
            "password": "hunter2hunter2",
            "device_name": "cli",
            "invite_code": invite,
        })),
    )
    .await;
}
