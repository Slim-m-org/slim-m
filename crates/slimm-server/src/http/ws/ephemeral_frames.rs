// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Authorizing a bot's private message for one connection, split out of
//! [`super::authorization::authorize`] to keep that file's match focused.

use super::authorization::Authorization;
use super::frames::ServerFrame;
use crate::ephemeral::EphemeralMessage;
use crate::http::ephemeral_messages::EphemeralMessageDto;
use crate::ids::UserId;
use crate::permissions::Permissions;
use crate::store::{SessionContext, Store};

/// Delivered to the recipient's own connections only, and only while they can
/// still view the channel and have not blocked the sender. A store error is
/// `Unknown`, never delivered: it has no catch-up path, so the connection resyncs.
pub(super) async fn authorize(
    store: &Store,
    ctx: &SessionContext,
    recipient_id: UserId,
    message: &EphemeralMessage,
) -> Authorization {
    if recipient_id != ctx.user_id {
        return Authorization::Withhold;
    }
    let can_view = store
        .has_permission(ctx.user_id, message.channel_id, Permissions::VIEW_CHANNEL)
        .await;
    let blocked = store.has_blocked(ctx.user_id, message.author_id).await;
    match allowed(can_view, blocked) {
        Some(true) => {}
        Some(false) => return Authorization::Withhold,
        None => return Authorization::Unknown,
    }
    Authorization::Deliver(Box::new(ServerFrame::MessageEphemeral {
        channel_id: message.channel_id.to_string(),
        message: EphemeralMessageDto::from(message),
    }))
}

/// Whether the recipient may see the message, or `None` when either read failed.
fn allowed(can_view: anyhow::Result<bool>, blocked: anyhow::Result<bool>) -> Option<bool> {
    Some(can_view.ok()? && !blocked.ok()?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_store_error_on_either_read_resyncs() {
        let busy = || Err(anyhow::anyhow!("busy"));
        assert_eq!(allowed(busy(), Ok(false)), None);
        assert_eq!(allowed(Ok(true), busy()), None);
    }

    #[test]
    fn a_block_or_a_denied_view_withholds() {
        assert_eq!(allowed(Ok(true), Ok(true)), Some(false));
        assert_eq!(allowed(Ok(false), Ok(false)), Some(false));
        assert_eq!(allowed(Ok(true), Ok(false)), Some(true));
    }
}
