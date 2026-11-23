// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The stable names a manifest uses for core permission bits, so a connector
//! asks for `send_messages` rather than a number an admin cannot read.

use super::Permissions;

/// Every named bit. A name is part of the add-on API: never rename or reuse one.
pub const NAMED: [(&str, Permissions); 22] = [
    ("administrator", Permissions::ADMINISTRATOR),
    ("view_channel", Permissions::VIEW_CHANNEL),
    ("send_messages", Permissions::SEND_MESSAGES),
    ("manage_messages", Permissions::MANAGE_MESSAGES),
    ("manage_channels", Permissions::MANAGE_CHANNELS),
    ("manage_roles", Permissions::MANAGE_ROLES),
    ("kick_members", Permissions::KICK_MEMBERS),
    ("ban_members", Permissions::BAN_MEMBERS),
    ("create_invite", Permissions::CREATE_INVITE),
    ("add_reactions", Permissions::ADD_REACTIONS),
    ("attach_files", Permissions::ATTACH_FILES),
    ("connect", Permissions::CONNECT),
    ("speak", Permissions::SPEAK),
    ("use_canvas", Permissions::USE_CANVAS),
    ("manage_canvas", Permissions::MANAGE_CANVAS),
    ("manage_server", Permissions::MANAGE_SERVER),
    ("mention_everyone", Permissions::MENTION_EVERYONE),
    ("run_code", Permissions::RUN_CODE),
    (
        "view_moderation_history",
        Permissions::VIEW_MODERATION_HISTORY,
    ),
    ("move_members", Permissions::MOVE_MEMBERS),
    ("view_transcripts", Permissions::VIEW_TRANSCRIPTS),
    ("use_soundboard", Permissions::USE_SOUNDBOARD),
];

/// The bit a manifest name stands for, or `None` for a name this server does not know.
pub fn by_name(name: &str) -> Option<Permissions> {
    NAMED.iter().find(|(n, _)| *n == name).map(|(_, p)| *p)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_bit_has_exactly_one_name() {
        let mut all = Permissions::NONE;
        for (name, bit) in NAMED {
            assert!(!all.intersects(bit), "{name} reuses a bit");
            all = all.union(bit);
            assert_eq!(by_name(name), Some(bit));
        }
        assert_eq!(all, Permissions::ALL);
        assert_eq!(by_name("VIEW_CHANNEL"), None);
    }
}
