// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a module is told about who ran it: an opaque id and the name members see.
//! See docs/decisions/0038-module-caller-id.md.

use crate::ids::UserId;
use crate::store::Store;

/// Stable per (module, user) and opaque: it never equals a user id and does
/// not match across modules, so it cannot be used to follow a person around.
///
/// Keyed with a secret only this deployment holds. Unkeyed, it was a hash of
/// two public values, and hashing the member list recovered the person.
pub(super) fn module_caller_id(key: &[u8; 32], module_id: &str, user_id: UserId) -> String {
    use hmac::{Hmac, Mac};
    use sha2::Sha256;
    let mut mac = <Hmac<Sha256>>::new_from_slice(key).expect("HMAC takes a key of any length");
    mac.update(b"slim-module-caller-v2\0");
    mac.update(module_id.as_bytes());
    mac.update(b"\0");
    mac.update(user_id.to_string().as_bytes());
    crate::media::to_hex(&mac.finalize().into_bytes())
}

/// The name members see for `user` here: the nickname set in this space, else the display name,
/// else the username. `None` when the account cannot be read.
pub(super) async fn caller_name(store: &Store, user: UserId) -> Option<String> {
    let profile = store
        .user_profiles(&[user])
        .await
        .ok()?
        .into_iter()
        .next()?;
    let nickname = store.nicknames_for(&[user]).await.ok()?.remove(&user);
    Some(shown_name(
        nickname.as_deref(),
        &profile.display_name,
        &profile.username,
    ))
}

fn shown_name(nickname: Option<&str>, display_name: &str, username: &str) -> String {
    [nickname.unwrap_or(""), display_name, username]
        .into_iter()
        .map(str::trim)
        .find(|name| !name.is_empty())
        .unwrap_or(username)
        .to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_caller_id_changes_with_the_key_the_module_and_the_person() {
        let (ada, bob) = (UserId::generate(), UserId::generate());
        let id = module_caller_id(&[1; 32], "polls", ada);

        assert_eq!(id, module_caller_id(&[1; 32], "polls", ada));
        assert_ne!(
            id,
            module_caller_id(&[2; 32], "polls", ada),
            "another deployment"
        );
        assert_ne!(
            id,
            module_caller_id(&[1; 32], "notes", ada),
            "another module"
        );
        assert_ne!(
            id,
            module_caller_id(&[1; 32], "polls", bob),
            "another person"
        );
    }

    /// The separator keeps `("ab", "c...")` from colliding with `("a", "bc...")`.
    #[test]
    fn the_module_id_and_the_user_id_cannot_run_together() {
        let user = UserId::generate();
        let joined = format!("x\0{user}");
        assert_ne!(
            module_caller_id(&[1; 32], "polls", user),
            module_caller_id(&[1; 32], &format!("polls\0{joined}"), user)
        );
    }

    #[test]
    fn the_shown_name_is_the_nickname_then_the_display_name_then_the_username() {
        assert_eq!(shown_name(Some("Boss"), "Ada", "ada"), "Boss");
        assert_eq!(shown_name(None, "Ada", "ada"), "Ada");
        assert_eq!(shown_name(None, " ", "ada"), "ada");
        assert_eq!(shown_name(Some(""), "", "ada"), "ada");
    }
}
