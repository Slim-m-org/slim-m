// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Admin-issued account recovery, in call order: a code is issued for somebody,
//! then redeemed.
//!
//! Order is the point. `resetPassword` needs a code that exists, and the only
//! way to have one is to have just issued it, so the two are one script rather
//! than two independent cases.
//!
//! Its own module to make room in `script.rs`, which sits at its hard line
//! ceiling; this block was the most self-contained thing in it.

use serde_json::json;

use crate::world::{Contract, Payload};

use super::text;

pub(crate) async fn recovery_calls(c: &mut Contract, root: &str, bob_id: &str) {
    let issued = c
        .json(
            "issueResetCode",
            "POST",
            &format!("/admin/users/{bob_id}/reset-code"),
            root,
            json!({ "password": super::PASSWORD }),
        )
        .await;
    c.call(
        "resetPassword",
        "POST",
        "/auth/reset",
        None,
        Payload::Json(json!({
            "code": text(&issued, "code"),
            "new_password": "an-entirely-new-password",
        })),
    )
    .await;
}
