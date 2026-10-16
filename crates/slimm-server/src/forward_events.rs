// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Telling live clients that a forward lost its snapshot.
//!
//! A `MessageEdited` frame already carries the whole message and its
//! `forwarded` block, and clients write what the frame gives them, so this
//! needs no event type of its own. Shared by the delete routes and the
//! retention sweep, which are the two places a snapshot is removed.

use std::sync::Arc;

use crate::hub::{Event, Hub};
use crate::store::{DetachedForward, Store};

/// Publishes one `MessageEdited` per detached forward, best-effort: the change
/// is already committed and sync carries it, so a failed read only costs the
/// live frame.
pub(crate) async fn publish_detached(store: &Store, hub: &Hub, detached: &[DetachedForward]) {
    for forward in detached {
        let message = match store.message(forward.message_id).await {
            Ok(Some(message)) => message,
            Ok(None) => continue,
            Err(err) => {
                tracing::warn!(error = %err, "failed to read a forward whose original was removed");
                continue;
            }
        };
        let forwarded = match store.forwards_for_messages(&[forward.message_id]).await {
            Ok(rows) => rows.into_iter().next().map(|(_, summary)| summary),
            Err(err) => {
                tracing::warn!(error = %err, "failed to read a forward's removed marker");
                continue;
            }
        };
        hub.publish(Event::MessageEdited {
            message: Arc::new(message),
            op_seq: forward.op_seq,
            forwarded: forwarded.map(Arc::new),
        });
    }
}
