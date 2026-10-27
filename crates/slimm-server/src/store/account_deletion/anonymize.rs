// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Anonymizing what an account authored that stays visible to others.

use sqlx::{Sqlite, Transaction};

use crate::ids::UserId;
use crate::store::now_ms;

/// Clears the deleted account's id from rows others still see, so the content
/// survives without pointing at a person.
pub(super) async fn anonymize_authored_content(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: UserId,
) -> Result<(), sqlx::Error> {
    // Anonymize authored content that stays visible to others.
    sqlx::query!(
        "UPDATE messages SET author_id = NULL WHERE author_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    // A forward's snapshot stays visible to whoever it reached, so its author id goes the way a message's does.
    sqlx::query!(
        "UPDATE message_forwards SET origin_author_id = NULL WHERE origin_author_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "UPDATE canvas_objects SET author_id = NULL WHERE author_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "UPDATE canvas_ops SET actor_id = NULL WHERE actor_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "UPDATE canvas_object_locks SET locked_by = NULL WHERE locked_by = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "UPDATE canvas_audit_log SET actor_id = NULL WHERE actor_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "UPDATE moderation_audit_log SET actor_id = NULL WHERE actor_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "UPDATE admin_audit_log SET actor_id = NULL WHERE actor_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "UPDATE message_ops SET actor_id = NULL WHERE actor_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    let revoked_at = now_ms();
    sqlx::query!(
        "UPDATE invites SET revoked_at = ? WHERE created_by = ? AND revoked_at IS NULL",
        revoked_at,
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "UPDATE invites SET created_by = NULL WHERE created_by = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "UPDATE password_reset_codes SET issued_by = NULL WHERE issued_by = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "UPDATE reports SET reporter_id = NULL WHERE reporter_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "UPDATE reports SET resolved_by = NULL WHERE resolved_by = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "UPDATE reports SET snapshot_author_id = NULL WHERE snapshot_author_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "UPDATE member_timeouts SET issued_by = NULL WHERE issued_by = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!("DELETE FROM member_nicknames WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query!(
        "UPDATE member_nicknames SET set_by = NULL WHERE set_by = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "UPDATE space_removals SET removed_by = NULL WHERE removed_by = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "UPDATE polls SET created_by = NULL WHERE created_by = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    // A shared code-block run stays visible to everyone who can see the message; its runner id goes the way a message author's does. The FK's ON DELETE SET NULL never fires on a tombstone UPDATE, so this clears it by hand.
    sqlx::query!(
        "UPDATE code_runs SET ran_by = NULL WHERE ran_by = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    // A launched app surface stays visible to everyone in the channel; who launched it goes the way a poll's creator does, and for the same tombstone-UPDATE reason the FK never fires.
    sqlx::query!(
        "UPDATE app_surfaces SET created_by = NULL WHERE created_by = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    // Who provisioned a bot is the provisioner's own data; the bot itself is a separate account and keeps working.
    sqlx::query!(
        "UPDATE bot_tokens SET created_by = NULL WHERE created_by = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    // Same shape as bot_tokens.created_by: who minted a webhook is the minter's own data, and the webhook itself keeps delivering.
    sqlx::query!(
        "UPDATE webhooks SET created_by = NULL WHERE created_by = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    // A call stays in the transcript the way any other message does; who placed it goes the way a launched app surface's creator does.
    sqlx::query!(
        "UPDATE call_records SET caller_id = NULL WHERE caller_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    // schema/openapi.yaml promises both of these read null once the account is gone.
    sqlx::query!(
        "UPDATE pinned_messages SET pinned_by = NULL WHERE pinned_by = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "UPDATE custom_emoji SET uploader_id = NULL WHERE uploader_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    Ok(())
}
