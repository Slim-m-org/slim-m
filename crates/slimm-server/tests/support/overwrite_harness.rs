// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Router, request and account helpers shared by the channel-overwrite test
//! binaries, so each builds the real app the same way.
//!
//! Allowed dead: `mod.rs` pulls this module into every integration test
//! binary and most never build the overwrite harness.
#![allow(dead_code, unused_imports)]

use slimm_server::store::Store;

pub use super::app::{app, general_channel_id, json_body, register_token_id as register, request};
pub use super::new_store;

/// The password [`register_with_password`] gives its account.
pub const KNOWN_PASSWORD: &str = "correct-horse-battery";

/// [`register`] with a real password hash, for the routes that ask the caller
/// to confirm their password (deleting an account, turning two-factor on).
pub async fn register_with_password(store: &Store, username: &str) -> (String, String) {
    let hash = slimm_server::auth::Auth::new(2)
        .unwrap()
        .hash_password(KNOWN_PASSWORD.to_owned())
        .await
        .unwrap();
    let account = store
        .create_account(username, username, &hash)
        .await
        .unwrap();
    store.bootstrap_deployment(account.id).await.unwrap();
    let tokens = store.open_session(account.id, "cli").await.unwrap();
    (tokens.access_token, account.id.to_string())
}
