// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Discarding a hidden voice canvas, together with the settings change that rides in the same request (decision 0139).

use super::super::canvas::canvas_clear::{ClearInTx, clear_in_tx};
use super::super::canvas::canvas_ops_apply::current_canvas_seq;
use super::super::{Channel, ClearScope, Store, SubmitOpError, SubmittedOp, VOICE_CHANNEL_KIND};
use super::channel_create::fetch_channel_by_id;
use super::channel_settings::{ChannelPatch, settings_update};
use crate::ids::{CanvasOpId, ChannelId, UserId};

/// What a discard did.
pub struct DiscardedCanvas {
    pub channel: Channel,
    /// The clear that emptied the board; `affected` is 0 for a board with nothing on it.
    pub op: SubmittedOp,
}

#[derive(Debug)]
pub enum DiscardError {
    /// The channel is missing, deleted, a DM or a thread.
    NotFound,
    /// The channel is not a voice channel whose canvas is off once the patch applies.
    NotHidden,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for DiscardError {
    fn from(err: sqlx::Error) -> Self {
        DiscardError::Internal(err.into())
    }
}

impl From<anyhow::Error> for DiscardError {
    fn from(err: anyhow::Error) -> Self {
        DiscardError::Internal(err)
    }
}

impl From<SubmitOpError> for DiscardError {
    fn from(err: SubmitOpError) -> Self {
        DiscardError::Internal(anyhow::anyhow!("discarding a canvas failed: {err:?}"))
    }
}

impl Store {
    /// Applies `patch`, then removes everything on the channel's board, locked objects included, in one write transaction.
    ///
    /// Refused unless the channel is a voice channel with its canvas off after the patch, judged inside the transaction so a racing toggle cannot slip a visible board through.
    pub async fn update_channel_discarding_canvas(
        &self,
        id: ChannelId,
        patch: ChannelPatch<'_>,
        actor_id: UserId,
    ) -> Result<DiscardedCanvas, DiscardError> {
        let mut tx = self.begin_write().await?;
        if !patch.is_empty() {
            let affected = settings_update(id, &patch)
                .build()
                .execute(&mut *tx)
                .await?
                .rows_affected();
            if affected == 0 {
                return Err(DiscardError::NotFound);
            }
        }
        let live = sqlx::query_scalar!(
            r#"SELECT 1 AS "live!: i64" FROM channels
               WHERE id = ? AND deleted_at IS NULL AND kind != 'dm' AND parent_message_id IS NULL"#,
            id
        )
        .fetch_optional(&mut *tx)
        .await?;
        let channel = match (live, fetch_channel_by_id(&mut *tx, id).await?) {
            (Some(_), Some(channel)) => channel,
            _ => return Err(DiscardError::NotFound),
        };
        if channel.kind != VOICE_CHANNEL_KIND || channel.canvas_open() {
            return Err(DiscardError::NotHidden);
        }
        let before_seq = current_canvas_seq(&mut tx, id).await?;
        let now = self.now_ms_unique(&mut tx).await?;
        let op = clear_in_tx(
            &mut tx,
            ClearInTx {
                channel_id: id,
                actor_id,
                op_id: CanvasOpId::generate(),
                before_seq,
                scope: &ClearScope::default(),
                spare_locks: false,
                now,
            },
        )
        .await?;
        tx.commit().await?;
        Ok(DiscardedCanvas { channel, op })
    }
}
