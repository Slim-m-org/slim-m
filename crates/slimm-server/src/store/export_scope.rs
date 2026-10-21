// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The channel scope shared by the export queries: a thread is its own `text` channel row, judged by the channel and message it hangs from, so one left by a deleted parent or under a direct message does not pass for a live channel.

/// Joins the parent message `tpm` and parent channel `tpc` of a channel aliased `c`.
macro_rules! parent_joins {
    () => {
        "LEFT JOIN messages tpm ON tpm.id = c.parent_message_id \
         LEFT JOIN channels tpc ON tpc.id = tpm.channel_id"
    };
}

/// A channel `c` (and the parent a thread hangs from) that has not been deleted.
macro_rules! live_channel {
    () => {
        "c.deleted_at IS NULL AND (c.parent_message_id IS NULL OR \
           (tpm.deleted_at IS NULL AND tpc.id IS NOT NULL AND tpc.deleted_at IS NULL))"
    };
}

/// A live channel that belongs to the community: no direct message, no temporary room.
macro_rules! community_channel {
    () => {
        concat!(
            $crate::store::export_scope::live_channel!(),
            " AND c.kind <> 'dm' AND c.room_owner_id IS NULL AND (c.parent_message_id IS NULL \
             OR (tpc.kind <> 'dm' AND tpc.room_owner_id IS NULL))"
        )
    };
}

pub(super) use {community_channel, live_channel, parent_joins};
