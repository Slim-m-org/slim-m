// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The send half of the message write paths: idempotent insert, attachment linking, and the
//! in-transaction slow-mode check. Edit and delete live in [`super`].

use super::row::{IdProbe, NewRow, insert_message_row, probe_id};
use super::{NewMessage, SendError, Sent};
use crate::ids::ChannelId;
use crate::store::attachments::link_attachments;
use crate::store::{Store, now_ms};

impl Store {
    /// Sends a message. Idempotent by `id` within its `(channel, author)` scope;
    /// the per-scope `seq` is allocated in the same transaction as the insert. A
    /// reused id that belongs to a different channel or author is rejected rather
    /// than returned, so the idempotency path cannot leak a foreign message.
    ///
    /// [`Sent::fresh`] is what separates a first send from a retry of one, so
    /// the caller can run the once-per-message side effects (fan-out, a push
    /// wake) only for a message that is genuinely new.
    ///
    /// `attachment_ids` (sha256 hashes of already-uploaded attachments) are
    /// linked inside this same transaction, so a message is never visible
    /// with only some of its attachments recorded: either every id resolves
    /// and the whole send commits, or none of it does.
    ///
    /// Uses [`Store::begin_write`] (`BEGIN IMMEDIATE`) rather than a deferred
    /// transaction, because this reads the id before it writes. A deferred
    /// transaction that has already taken a read snapshot cannot promote
    /// itself to a writer once another connection holds the write lock;
    /// SQLite answers that with SQLITE_BUSY straight away, ignoring
    /// `busy_timeout`, because waiting could deadlock. Taking the write lock
    /// up front makes concurrent sends queue instead.
    pub async fn send_message(&self, msg: NewMessage<'_>) -> Result<Sent, SendError> {
        self.send_message_stamped(msg, None, None).await
    }

    /// [`Store::send_message`] that also refuses a fresh send inside `slow_mode_window_ms`
    /// of the author's last message in the channel, checked under the write lock so
    /// concurrent sends cannot all pass. The caller resolves the window and any exemption.
    pub async fn send_message_with_slow_mode(
        &self,
        msg: NewMessage<'_>,
        slow_mode_window_ms: Option<i64>,
    ) -> Result<Sent, SendError> {
        self.send_message_stamped(msg, None, slow_mode_window_ms)
            .await
    }

    /// [`Store::send_message`] for a message a module posted: the origin row and
    /// the footer embed commit in the same transaction as the message, so a
    /// failure leaves either all three or none. A retry of an id that already
    /// landed returns the stored message without stamping it again.
    pub async fn send_module_message(
        &self,
        msg: NewMessage<'_>,
        module_id: &str,
        footer: &str,
    ) -> Result<Sent, SendError> {
        self.send_message_stamped(msg, Some((module_id, footer)), None)
            .await
    }

    /// [`Store::send_module_message`] with the in-transaction slow-mode check of
    /// [`Store::send_message_with_slow_mode`].
    pub async fn send_module_message_with_slow_mode(
        &self,
        msg: NewMessage<'_>,
        module_id: &str,
        footer: &str,
        slow_mode_window_ms: Option<i64>,
    ) -> Result<Sent, SendError> {
        self.send_message_stamped(msg, Some((module_id, footer)), slow_mode_window_ms)
            .await
    }

    async fn send_message_stamped(
        &self,
        msg: NewMessage<'_>,
        stamp: Option<(&str, &str)>,
        slow_mode_window_ms: Option<i64>,
    ) -> Result<Sent, SendError> {
        let NewMessage {
            channel_id,
            author_id,
            id,
            content,
            attachment_ids,
            reply_to_id,
            forward,
        } = msg;

        // Authorized before the write lock, never inside it; see `may_link`.
        for sha256 in attachment_ids {
            if !crate::store::attachments::may_link(self, author_id, sha256).await? {
                return Err(SendError::AttachmentNotFound);
            }
        }

        // BEGIN IMMEDIATE, never deferred; see the note on this function.
        let mut tx = self.begin_write().await?;

        match probe_id(&mut tx, channel_id, author_id, id).await? {
            IdProbe::Free => {}
            IdProbe::Replay(message) => {
                tx.commit().await?;
                return Ok(Sent {
                    message,
                    fresh: false,
                });
            }
            IdProbe::Conflict => {
                tx.commit().await?;
                return Err(SendError::IdConflict);
            }
        }

        let now = now_ms();
        if let Some(window_ms) = slow_mode_window_ms
            && let Some(retry_after_seconds) = crate::store::channel_slow_mode::retry_after_in_tx(
                &mut tx, channel_id, author_id, window_ms, now,
            )
            .await?
        {
            tx.commit().await?;
            return Err(SendError::SlowMode {
                retry_after_seconds,
            });
        }

        // The FK only proves the parent exists somewhere, so its channel is checked by hand; a soft-deleted parent still passes.
        if let Some(parent_id) = reply_to_id {
            let parent_channel = sqlx::query_scalar!(
                r#"SELECT channel_id AS "channel_id!: ChannelId" FROM messages WHERE id = ?"#,
                parent_id
            )
            .fetch_optional(&mut *tx)
            .await?;
            if parent_channel != Some(channel_id) {
                tx.commit().await?;
                return Err(SendError::InvalidReplyTarget);
            }
        }

        let message = insert_message_row(
            &mut tx,
            &NewRow {
                channel_id,
                author_id,
                id,
                content,
                reply_to_id,
                now,
            },
        )
        .await?;

        if !attachment_ids.is_empty() {
            link_attachments(&mut tx, id, author_id, attachment_ids).await?;
        }

        if let Some(origin) = &forward {
            crate::store::message_forwards::insert_forward(&mut tx, id, origin).await?;
        }

        if let Some((module_id, footer)) = stamp {
            sqlx::query!(
                "INSERT INTO module_message_origins (message_id, module_id) VALUES (?, ?)",
                id,
                module_id
            )
            .execute(&mut *tx)
            .await?;
            let embed = crate::store::NewEmbed {
                footer_text: Some(footer.to_owned()),
                ..crate::store::NewEmbed::default()
            };
            crate::store::message_embeds::insert_embeds(&mut tx, id, &[embed]).await?;
        }

        tx.commit().await?;
        Ok(Sent {
            message,
            fresh: true,
        })
    }
}
