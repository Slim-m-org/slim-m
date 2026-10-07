// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Drops push recipients who have already seen a message on another device.
//!
//! Runs after [`super::message_recipients`] so its permission, block,
//! preference and schedule rules stay untouched; this only ever removes
//! people, never adds one. Three independent signals, any is enough:
//!
//! - the recipient's account-level read marker already covers the message,
//!   which is what a device that read it, or a send from another device,
//!   leaves behind; and
//! - one of their connections reports the channel open and focused right now
//!   (`ViewingTracker`), which covers the window before that device has had a
//!   chance to advance the marker for a message that has only just landed; or
//! - they used one of their devices within `viewing::ACTIVE_WINDOW`, so the
//!   message is already in front of them there and a phone push only repeats it.
//!   Calls and security alerts take other paths and are never narrowed here.
//!
//! Neither is exposed to anyone else: the result only shortens this one push.

use crate::ids::{ChannelId, UserId};
use crate::store::Store;
use crate::viewing::ViewingTracker;

/// `seq` is the message's own seq in `channel_id`.
pub async fn narrow_for_attention(
    store: &Store,
    channel_id: ChannelId,
    seq: crate::ids::Seq,
    viewing: &ViewingTracker,
    recipients: Vec<UserId>,
) -> anyhow::Result<Vec<UserId>> {
    if recipients.is_empty() {
        return Ok(recipients);
    }
    let read = store.last_read_seqs(channel_id, &recipients).await?;
    Ok(recipients
        .into_iter()
        .filter(|user_id| {
            let covered = read.get(user_id).is_some_and(|last| *last >= seq.0);
            !covered
                && !viewing.is_viewing(*user_id, channel_id)
                && !viewing.is_recently_active(*user_id)
        })
        .collect())
}
