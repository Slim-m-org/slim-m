// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The record a finished DM call leaves in its transcript, shared by every path that ends a ring.

use std::sync::Arc;

use super::CallRingOutcome;
use crate::hub::{Event, Hub};
use crate::ids::{CallRingId, ChannelId, UserId};
use crate::push::{PushSender, SentMessage};
use crate::store::Store;

/// Writes the record a finished call leaves in its DM, wakes the callee's devices and fans it out live.
///
/// Best-effort on purpose: a call that happened is more important than its
/// record, and a store error here must not fail the request or sweep that
/// ended the ring. It is logged instead.
///
/// Every terminal outcome writes one, including `Answered` - the transcript is
/// the call history. `duration_ms` stays null even on an answered call: how
/// long it lasted is only known when the last participant leaves, which is the
/// voice roster's business rather than the ring's.
///
/// A ring the caller gave up on, or nobody answered, is a missed call to the
/// callee, so those two push through [`PushSender::notify_message`] rather than
/// a kind of their own: a missed call is a transcript row, so the message path
/// is already right about muting, blocks, sealed-envelope previews and bursts.
pub(crate) async fn record_finished_call(
    store: &Store,
    hub: &Hub,
    push: &PushSender,
    channel_id: ChannelId,
    ring_id: CallRingId,
    caller_id: UserId,
    outcome: CallRingOutcome,
) {
    push.notify_call_end(store.clone(), channel_id, ring_id, caller_id);
    let (sent, record) = match store
        .record_call(channel_id, caller_id, outcome.as_str(), None)
        .await
    {
        Ok(sent) => sent,
        Err(err) => {
            tracing::warn!(error = %err, %channel_id, "failed to record a finished call");
            return;
        }
    };
    if matches!(
        outcome,
        CallRingOutcome::Canceled | CallRingOutcome::TimedOut
    ) {
        push.notify_message(
            store.clone(),
            SentMessage {
                channel_id,
                author_id: caller_id,
                message_id: sent.message.id,
                seq: sent.message.seq,
                content: sent.message.content.clone(),
                presence: hub.presence(),
            },
        );
    }
    hub.publish(Event::MessageCreated {
        message: Arc::new(sent.message),
        attachments: Arc::new(Vec::new()),
        forwarded: None,
        app_surface: None,
        code_run: None,
        poll: None,
        embeds: Arc::new(Vec::new()),
        call: Some(Arc::new(record)),
        components: Arc::new(Vec::new()),
        lookups: Default::default(),
    });
}
