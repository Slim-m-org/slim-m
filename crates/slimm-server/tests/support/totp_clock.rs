// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The wall clock as the TOTP verifier reads it, shared by every suite that mints codes.

use std::time::Duration;

/// Milliseconds in one counter step.
pub const STEP_MS: i64 = 30 * 1000;

pub fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64
}

/// Sleeps until the clock is well inside a step, so codes made for one step are not read by the server in the next.
pub async fn wait_for_mid_step() {
    let into_step = now_ms().rem_euclid(STEP_MS);
    if !(5_000..=15_000).contains(&into_step) {
        let wait = (STEP_MS - into_step + 5_000).rem_euclid(STEP_MS);
        tokio::time::sleep(Duration::from_millis(wait as u64)).await;
    }
}
