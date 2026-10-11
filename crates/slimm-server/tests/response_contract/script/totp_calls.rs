// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The second factor, in call order: enrol, confirm, reissue, sign in through a
//! challenge, disable, re-enrol, and have an administrator clear it.
//!
//! One script rather than independent cases, because every call here needs the
//! state the one before it left: a confirmation needs a pending enrolment, a
//! challenge needs a live factor, and a clear needs something to clear.
//!
//! It runs against its own account. Enrolling changes what `/auth/login`
//! answers for that account from 200 to 202, so doing this to an account the
//! rest of the script still signs in as would break it somewhere else entirely.
//!
//! Every TOTP code comes from a strictly later counter step than the last,
//! because the replay guard refuses a step already spent. The recovery codes
//! carry the calls where no fresh step is left.

use serde_json::json;
use slimm_server::totp;

use crate::world::{Contract, Payload};

use super::{signup, text};

/// Milliseconds in one counter step.
const STEP_MS: i64 = 30 * 1000;

pub(crate) async fn totp_calls(c: &mut Contract, root: &str, invite: &str) {
    wait_for_mid_step().await;
    let signed_up = c
        .call(
            "register",
            "POST",
            "/auth/register",
            None,
            Payload::Json(signup("grace", "desktop", Some(invite))),
        )
        .await;
    let token = text(&signed_up, "access_token");
    let user_id = text(&signed_up, "user_id");

    c.get("getTotpStatus", "/auth/totp", &token).await;

    let enrolment = c
        .json(
            "beginTotpEnrolment",
            "POST",
            "/auth/totp/enrol",
            &token,
            json!({ "password": super::PASSWORD }),
        )
        .await;
    let secret = text(&enrolment, "secret");

    // The previous step, inside the skew window, so the current one is left for the sign-in below.
    let confirmed = c
        .json(
            "confirmTotpEnrolment",
            "POST",
            "/auth/totp/confirm",
            &token,
            json!({ "code": code(&secret, -STEP_MS), "password": super::PASSWORD }),
        )
        .await;
    let first_set = recovery_codes(&confirmed);

    let reissued = c
        .json(
            "reissueTotpRecoveryCodes",
            "POST",
            "/auth/totp/recovery-codes",
            &token,
            json!({ "code": first_set[0] }),
        )
        .await;
    let second_set = recovery_codes(&reissued);

    // 202 rather than 200 now, which is the shape this validates.
    let challenge = c
        .call(
            "login",
            "POST",
            "/auth/login",
            None,
            Payload::Json(json!({
                "username": "grace",
                "password": super::PASSWORD,
                "device_name": "phone",
            })),
        )
        .await;
    c.call(
        "verifyTotpChallenge",
        "POST",
        "/auth/totp/verify",
        None,
        Payload::Json(json!({
            "challenge": text(&challenge, "totp_challenge"),
            "code": code(&secret, 0),
        })),
    )
    .await;

    c.json(
        "disableTotp",
        "POST",
        "/auth/totp/disable",
        &token,
        json!({ "code": second_set[0] }),
    )
    .await;

    // A fresh factor to clear: its own row, so the spent-step guard starts over and an earlier code works again.
    let again = c
        .json(
            "beginTotpEnrolment",
            "POST",
            "/auth/totp/enrol",
            &token,
            json!({ "password": super::PASSWORD }),
        )
        .await;
    c.json(
        "confirmTotpEnrolment",
        "POST",
        "/auth/totp/confirm",
        &token,
        json!({ "code": code(&text(&again, "secret"), -STEP_MS), "password": super::PASSWORD }),
    )
    .await;
    c.json(
        "clearTotpFactor",
        "DELETE",
        &format!("/admin/users/{user_id}/totp"),
        root,
        json!({ "password": super::PASSWORD }),
    )
    .await;
}

/// Sleeps until the clock is well inside a step, so codes made for one step are not read by the server in the next.
async fn wait_for_mid_step() {
    let into_step = now_ms().rem_euclid(STEP_MS);
    if !(5_000..=15_000).contains(&into_step) {
        let wait = (STEP_MS - into_step + 5_000).rem_euclid(STEP_MS);
        tokio::time::sleep(std::time::Duration::from_millis(wait as u64)).await;
    }
}

fn code(secret: &str, offset_ms: i64) -> String {
    totp::code_at(secret, now_ms() + offset_ms).expect("a valid secret")
}

fn recovery_codes(response: &serde_json::Value) -> Vec<String> {
    response["recovery_codes"]
        .as_array()
        .expect("a recovery_codes array")
        .iter()
        .map(|value| value.as_str().expect("a code string").to_owned())
        .collect()
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}
