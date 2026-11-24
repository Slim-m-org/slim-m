// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What only the deleted account owned: its credentials, which go the moment
//! it closes, and the rest of its own settings and records, which go last.

use sqlx::{Sqlite, Transaction};

use crate::ids::UserId;
use crate::store::Store;
use crate::store::dropped_refresh::{DropCause, keep_dropped_refresh_tokens};

/// Everything that could still sign the account in or act as it.
pub(super) async fn purge_credentials(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: UserId,
) -> anyhow::Result<()> {
    // Deleting devices cascades sessions and their tokens.
    keep_dropped_refresh_tokens(tx, user_id, None, DropCause::AccountDeleted).await?;
    sqlx::query!("DELETE FROM devices WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    // A deleted bot's credential goes with it, or its hash outlives the account.
    sqlx::query!("DELETE FROM bot_tokens WHERE bot_user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    // Same shape as bot_tokens.bot_user_id above: its own data, purged with it.
    sqlx::query!("DELETE FROM webhooks WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query!(
        "DELETE FROM password_reset_codes WHERE user_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!("DELETE FROM login_throttle WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    // The factor row holds its secret in the clear; a tombstone fires no cascade.
    sqlx::query!("DELETE FROM totp_challenges WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query!("DELETE FROM totp_recovery_codes WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query!("DELETE FROM user_totp_factors WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    Ok(())
}

/// The account's own settings and records, each small enough for one statement.
pub(super) async fn purge_personal_data(
    tx: &mut Transaction<'_, Sqlite>,
    user_id: UserId,
) -> anyhow::Result<()> {
    sqlx::query!("DELETE FROM read_states WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    // A slot names the participant, not who arranged it - nothing to anonymize once they are gone.
    sqlx::query!("DELETE FROM canvas_media_slots WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query!("DELETE FROM member_roles WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    // A note is the author's own data, so it leaves with them; the subject's own deletion never touches it.
    sqlx::query!("DELETE FROM user_notes WHERE author_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    // Which DMs this account had closed out of its own sidebar is its own preference, not the other side's.
    sqlx::query!("DELETE FROM dm_hides WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    // No group should keep naming a tombstone; the rest of each group keeps its history.
    Store::leave_all_group_dms(tx, user_id).await?;
    sqlx::query!("DELETE FROM linked_accounts WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query!("DELETE FROM link_states WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query!("DELETE FROM link_handoffs WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query!("DELETE FROM pending_members WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query!(
        "DELETE FROM call_transcript_marks WHERE author_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!("DELETE FROM voice_sessions WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query!("DELETE FROM saved_messages WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query!("DELETE FROM user_favorites WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    // Their own list only: a block on them is the blocker's, and keeps hiding what they left behind.
    sqlx::query!("DELETE FROM user_blocks WHERE blocker_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    // A real DELETE, so notification_schedule_days genuinely cascades from it.
    sqlx::query!(
        "DELETE FROM notification_schedules WHERE user_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    // Both directions: being let through someone's quiet hours names a person who is gone.
    sqlx::query!(
        "DELETE FROM notification_schedule_allowed_users WHERE user_id = ? OR allowed_user_id = ?",
        user_id,
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "DELETE FROM notification_schedule_allowed_channels WHERE user_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "DELETE FROM channel_notification_prefs WHERE user_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!("DELETE FROM category_mutes WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query!("DELETE FROM voice_notify_prefs WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    // Which inviter's code this account joined with is theirs to forget too; the tombstone never fires its CASCADE.
    sqlx::query!("DELETE FROM invite_redemptions WHERE user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    // A deleted bot's own registration: its own data, nobody else's, purged with it.
    sqlx::query!("DELETE FROM bot_commands WHERE bot_user_id = ?", user_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query!(
        "DELETE FROM bot_command_registrations WHERE bot_user_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    // A press still waiting on a bot names who pressed it, and a deleted bot never answers.
    sqlx::query!(
        "DELETE FROM interactions WHERE clicker_id = ? OR bot_id = ?",
        user_id,
        user_id
    )
    .execute(&mut **tx)
    .await?;
    // Their archives go with the rows; the export sweep removes the files.
    sqlx::query("DELETE FROM data_exports WHERE user_id = ?")
        .bind(user_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM debug_logs WHERE user_id = ?")
        .bind(user_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM bot_ui_entries WHERE bot_user_id = ?")
        .bind(user_id)
        .execute(&mut **tx)
        .await?;
    sqlx::query("DELETE FROM watch_sessions WHERE bot_user_id = ?")
        .bind(user_id)
        .execute(&mut **tx)
        .await?;
    // A controller hint naming a departed member would outlive them for the session's life.
    sqlx::query("UPDATE watch_sessions SET controller_user_id = NULL WHERE controller_user_id = ?")
        .bind(user_id)
        .execute(&mut **tx)
        .await?;
    // The role itself stays; it may be shared with a human.
    sqlx::query!(
        "UPDATE roles SET managed_bot_id = NULL WHERE managed_bot_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "DELETE FROM channel_overwrites WHERE target_type = 'member' AND target_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "DELETE FROM category_overwrites WHERE target_type = 'member' AND target_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "DELETE FROM username_collision_renames WHERE user_id = ?",
        user_id
    )
    .execute(&mut **tx)
    .await?;
    Ok(())
}
