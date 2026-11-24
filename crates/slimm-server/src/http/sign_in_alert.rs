// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Telling an account's other devices when an unfamiliar one signs in.
//!
//! A connected device hears it over the account-private hub path, an offline
//! one through a `security` push (`push::security`), and the devices list
//! shows it either way.

use super::AppState;
use crate::hub::Event;
use crate::push::NewDeviceSignIn;
use crate::ratelimit::Class;
use crate::store::{IssuedTokens, now_ms};

/// Best-effort: the sign-in already succeeded, so nothing here may fail it.
pub(super) async fn announce(
    state: &AppState,
    tokens: &IssuedTokens,
    device_name: &str,
    client_kind: Option<&str>,
) {
    if tokens.known_install {
        return;
    }
    let unfamiliar = state
        .store
        .is_unfamiliar_sign_in(tokens.user_id, tokens.device_id)
        .await;
    match unfamiliar {
        Ok(true) => {}
        Ok(false) => return,
        Err(err) => {
            tracing::warn!(error = %err, "failed to decide whether a sign-in is unfamiliar");
            return;
        }
    }
    if !state
        .limiter
        .check(Class::SignInAlert, &format!("u:{}", tokens.user_id))
    {
        return;
    }
    let signed_in_at = now_ms();
    state.hub.publish(Event::NewDeviceSignIn {
        user_id: tokens.user_id,
        device_id: tokens.device_id,
        device_name: device_name.to_owned(),
        client_kind: client_kind.map(str::to_owned),
        signed_in_at,
    });
    // A device that is asleep never sees the live event above.
    state.push.notify_new_device_sign_in(
        state.store.clone(),
        NewDeviceSignIn {
            user_id: tokens.user_id,
            device_id: tokens.device_id,
            device_name: device_name.to_owned(),
            signed_in_at,
        },
    );
}
