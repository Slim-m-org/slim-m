// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who may read or attach an uploaded blob: the uploader, or anyone who can
//! view a channel that still references it.

use super::Store;
use super::attachments::LinkError;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;

impl Store {
    /// The name `user_id` may see on these bytes: their own upload's, else a live message's
    /// in a channel they can view. Never the row's first-uploader name, which is another
    /// person's choice and may come from a channel the caller cannot see.
    pub async fn attachment_display_filename(
        &self,
        user_id: UserId,
        sha256: &[u8],
    ) -> anyhow::Result<Option<String>> {
        let own = sqlx::query_scalar!(
            r#"SELECT filename FROM attachment_uploaders
               WHERE sha256 = ? AND uploaded_by = ? AND filename IS NOT NULL"#,
            sha256,
            user_id
        )
        .fetch_optional(&self.pool)
        .await?
        .flatten();
        if own.is_some() {
            return Ok(own);
        }
        let linked = sqlx::query!(
            r#"SELECT m.channel_id AS "channel_id!: ChannelId", ma.filename AS "filename!"
               FROM message_attachments ma
               JOIN messages m ON m.id = ma.message_id
               WHERE ma.sha256 = ? AND m.deleted_at IS NULL AND ma.filename IS NOT NULL
               ORDER BY m.id"#,
            sha256
        )
        .fetch_all(&self.pool)
        .await?;
        let channels: Vec<ChannelId> = linked.iter().map(|r| r.channel_id).collect();
        let perms = self.permissions_in_channels(user_id, &channels).await?;
        Ok(linked
            .into_iter()
            .find(|r| {
                perms
                    .get(&r.channel_id)
                    .is_some_and(|p| p.contains(Permissions::VIEW_CHANNEL))
            })
            .map(|r| r.filename))
    }

    /// Every channel with a live message, or a canvas object, referencing
    /// this attachment. Used only to decide the fetch permission: a caller
    /// may read the bytes if they hold VIEW_CHANNEL in *any* channel that has
    /// attached them, since content already visible to them in one channel
    /// does not become more sensitive for also being attached somewhere else.
    ///
    /// A canvas placement is not filtered on `deleted_at IS NULL` the way a
    /// message is: an erased canvas object can be un-erased by a `restore`
    /// op, so a channel's own VIEW_CHANNEL is still the right question to ask
    /// while it is soft-deleted, not a reason to withdraw fetch access. A
    /// board that is switched off counts for nothing, so a hidden board's
    /// images are not fetchable on its account (decision 0139).
    pub async fn channels_referencing_attachment(
        &self,
        sha256: &[u8],
    ) -> anyhow::Result<Vec<ChannelId>> {
        // Built, not a `query!`: the board filter is the shared `CANVAS_OPEN_SQL` fragment.
        let sql = format!(
            "SELECT DISTINCT m.channel_id AS channel_id \
             FROM message_attachments ma \
             JOIN messages m ON m.id = ma.message_id \
             WHERE ma.sha256 = ? AND m.deleted_at IS NULL \
             UNION \
             SELECT DISTINCT co.channel_id AS channel_id \
             FROM canvas_object_attachments coa \
             JOIN canvas_objects co ON co.id = coa.object_id \
             JOIN channels c ON c.id = co.channel_id \
             WHERE coa.sha256 = ? AND {}",
            super::CANVAS_OPEN_SQL
        );
        let rows: Vec<ChannelId> = sqlx::query_scalar(sqlx::AssertSqlSafe(sql))
            .bind(sha256)
            .bind(sha256)
            .fetch_all(&self.pool)
            .await?;
        Ok(rows)
    }

    /// Whether `user_id` uploaded `sha256` themselves, recorded in
    /// `attachment_uploaders`. The fetch handler uses this so someone can
    /// preview an attachment they just uploaded but have not yet put on a
    /// message - a GIF staged in the composer, most visibly - which
    /// [`may_link`] already lets them attach. The two must agree: the send
    /// path allowing what the fetch path refuses is exactly the mismatch that
    /// made a picked GIF fail to stage. Leaks nothing an uploader does not
    /// already have; a non-uploader still falls to the channel-reference
    /// check.
    pub async fn is_attachment_uploader(
        &self,
        user_id: UserId,
        sha256: &[u8],
    ) -> anyhow::Result<bool> {
        let row = sqlx::query_scalar!(
            r#"SELECT 1 AS "one!: i64" FROM attachment_uploaders
               WHERE sha256 = ? AND uploaded_by = ?"#,
            sha256,
            user_id
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.is_some())
    }

    /// Whether `user_id` could fetch `sha256` right now: they uploaded it, or
    /// can view a channel that has it attached. The same rule as the fetch route.
    pub async fn can_fetch_attachment(
        &self,
        user_id: UserId,
        sha256: &[u8],
    ) -> anyhow::Result<bool> {
        if self.is_attachment_uploader(user_id, sha256).await? {
            return Ok(true);
        }
        let channels = self.channels_referencing_attachment(sha256).await?;
        let perms = self.permissions_in_channels(user_id, &channels).await?;
        Ok(perms
            .values()
            .any(|p| p.contains(Permissions::VIEW_CHANNEL)))
    }
}

/// Whether `author_id` may attach `sha256` to a message: they uploaded it
/// themselves, or they can currently view some channel that already has it.
///
/// Existence alone used to be the whole check, which let anyone who learned an
/// attachment id (the content's own sha256) attach that content to a message in
/// any channel they could post in, uploaded or not, viewable or not. The common
/// case - the sender uploaded their own file - is one `EXISTS` against
/// `attachment_uploaders`. A miss falls back to the same shape
/// `http/attachments.rs`'s fetch handler already uses: any channel that still
/// has a live message referencing these bytes, checked for VIEW_CHANNEL, which
/// is what lets forwarding something you can already see keep working.
///
/// Returns a plain `bool` on purpose. A refusal has to be indistinguishable
/// from "never uploaded", or the oracle this closes simply moves into whatever
/// maps a richer error to a status, so there is nothing more specific here for a
/// caller to leak.
///
/// Called by [`Store::send_message`] *before* it takes the write lock, never
/// from inside the transaction. Every read in that transaction runs on `tx`
/// deliberately (see that function's own note on BEGIN IMMEDIATE); reaching the
/// pool for a second connection while holding the writer is how eight
/// concurrent sends stall each other on an eight-connection pool. The residual
/// is a caller whose view access is revoked between this check and the insert
/// microseconds later, which is not an escalation: they held it when they
/// started the send.
pub(super) async fn may_link(
    store: &Store,
    author_id: UserId,
    sha256: &[u8],
) -> Result<bool, LinkError> {
    Ok(store.can_fetch_attachment(author_id, sha256).await?)
}
