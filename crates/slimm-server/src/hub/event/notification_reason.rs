// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The small reason and scope enums an [`Event`](super::Event) carries.

/// Why the server ended a member's call, as [`super::Event::VoiceRemoved`] carries it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VoiceRemovalReason {
    /// The member joined a call on another device.
    OtherDevice,
}

impl VoiceRemovalReason {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::OtherDevice => "other_device",
        }
    }
}

/// Which of an account's notification state [`super::Event::AccountNotificationsChanged`] says moved.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AccountNotificationScope {
    /// The weekly windows, off-hours mode, snooze or either allow-list.
    Schedule,
    /// The account-wide `everything` / `mentions` / `nothing` default.
    Preference,
}

impl AccountNotificationScope {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Schedule => "schedule",
            Self::Preference => "preference",
        }
    }
}
