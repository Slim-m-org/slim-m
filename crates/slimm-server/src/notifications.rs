// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A durable per-account choice: how much of a channel's traffic is worth
//! waking a device for.
//!
//! Persisted in `users.notification_preference` (migration 0032);
//! [`crate::store::Store::notification_preference`] reads it and
//! [`crate::push::recipients`] is the only place it is enforced - the same
//! "read where the audience is computed, not filtered after the fact" shape
//! [`crate::push::recipients::message_recipients`]'s own doc comment already
//! uses for blocking.
//!
//! This is the account-wide default; `store/channel_notification_prefs.rs`
//! is a per-channel override of it, resolving through this same enum at the
//! same one choke point in `push::recipients` this doc comment predicted -
//! the way a channel overwrite narrows a role's base permission today rather
//! than needing a second evaluator.

/// What a message has to be, for this account, before it is worth a push.
pub mod notification_schedule;
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum NotificationPreference {
    /// Every message in a channel this account can see. The default, and
    /// what every account already got before this preference existed.
    #[default]
    Everything,
    /// A direct `@`-mention, plus every message in a DM: see
    /// `push::recipients`'s own doc comment for why a DM always counts.
    Mentions,
    /// No push at all, ever, including a DM. The strongest of the three: an
    /// account that chose this is not waiting to be talked into an
    /// exception the way `Mentions`'s DM carve-out is.
    Nothing,
}

impl NotificationPreference {
    pub const fn as_str(self) -> &'static str {
        match self {
            NotificationPreference::Everything => "everything",
            NotificationPreference::Mentions => "mentions",
            NotificationPreference::Nothing => "nothing",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "everything" => NotificationPreference::Everything,
            "mentions" => NotificationPreference::Mentions,
            "nothing" => NotificationPreference::Nothing,
            _ => return None,
        })
    }
}

/// Minutes in a day, and the exclusive upper bound on a valid minute-of-day
/// value.
pub const MINUTES_PER_DAY: u16 = 1440;

/// What an account that never chose gets for push previews. The preview is
/// sealed to the device's own key, and the OS lock-screen setting still
/// applies on top; flip this one constant to make previews opt-in again
/// (`docs/decisions/0054-push-preview-default-on.md`).
pub const DEFAULT_PUSH_PREVIEW: bool = true;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_wire_spelling_round_trips() {
        for preference in [
            NotificationPreference::Everything,
            NotificationPreference::Mentions,
            NotificationPreference::Nothing,
        ] {
            assert_eq!(
                NotificationPreference::parse(preference.as_str()),
                Some(preference)
            );
        }
    }

    #[test]
    fn an_unrecognized_value_parses_to_none_rather_than_a_silent_guess() {
        assert_eq!(NotificationPreference::parse("silent"), None);
        assert_eq!(NotificationPreference::parse(""), None);
    }

    #[test]
    fn the_default_is_everything_so_an_existing_account_notices_nothing() {
        assert_eq!(
            NotificationPreference::default(),
            NotificationPreference::Everything
        );
    }
}
