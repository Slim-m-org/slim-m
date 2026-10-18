// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which prefix each bot answers to. See docs/decisions/0069-bot-prefix-assignment.md.

use std::collections::HashSet;

use sqlx::SqliteConnection;

use super::bot_commands::{BotCommand, SetBotCommandsError};
use crate::ids::UserId;

use super::Store;

/// Single characters tried in order when suggesting a prefix, before doubled ones.
const SUGGESTED_PREFIXES: [&str; 12] = ["!", "?", "$", "%", "&", "~", "^", ".", ",", ";", "+", "="];

/// Picks the first candidate no live bot holds, doubling characters once singles run out.
fn first_free(taken: &HashSet<String>) -> Option<String> {
    let doubled = SUGGESTED_PREFIXES.iter().map(|p| p.repeat(2));
    let tripled = SUGGESTED_PREFIXES.iter().map(|p| p.repeat(3));
    SUGGESTED_PREFIXES
        .iter()
        .map(|p| (*p).to_owned())
        .chain(doubled)
        .chain(tripled)
        .find(|candidate| !taken.contains(candidate))
}

impl Store {
    /// Prefixes held by bots that can still act: not revoked, deleted or removed.
    pub async fn taken_bot_prefixes(&self) -> anyhow::Result<HashSet<String>> {
        let rows = sqlx::query_scalar!(
            r#"SELECT DISTINCT u.bot_prefix AS "prefix!: String"
               FROM users u
               JOIN bot_tokens t ON t.bot_user_id = u.id AND t.revoked_at IS NULL
               WHERE u.is_bot = 1 AND u.deleted_at IS NULL AND u.bot_prefix IS NOT NULL
                 AND NOT EXISTS (SELECT 1 FROM space_removals sr WHERE sr.user_id = u.id)"#
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows.into_iter().collect())
    }

    /// The prefix assigned to this account, or `None` for a person or a bot without one.
    pub async fn bot_prefix(&self, user_id: UserId) -> anyhow::Result<Option<String>> {
        Ok(
            sqlx::query_scalar!("SELECT bot_prefix FROM users WHERE id = ?", user_id)
                .fetch_optional(&self.pool)
                .await?
                .flatten(),
        )
    }

    /// A prefix no live bot holds, for the admin to accept when creating a bot.
    pub async fn suggest_bot_prefix(&self) -> anyhow::Result<String> {
        let taken = self.taken_bot_prefixes().await?;
        first_free(&taken).ok_or_else(|| anyhow::anyhow!("every suggested bot prefix is taken"))
    }
}

/// Runs inside the registration transaction: the prefix must be the one assigned
/// (or adopts it for a bot that has none), and no other live bot may already
/// answer to one of these command names under the same prefix.
pub(super) async fn claim_registration(
    tx: &mut SqliteConnection,
    bot_user_id: UserId,
    prefix: &str,
    commands: &[BotCommand],
) -> Result<(), SetBotCommandsError> {
    let assigned = sqlx::query_scalar!("SELECT bot_prefix FROM users WHERE id = ?", bot_user_id)
        .fetch_optional(&mut *tx)
        .await?
        .flatten();
    match assigned {
        Some(assigned) if assigned != prefix => {
            return Err(SetBotCommandsError::PrefixNotAssigned { assigned });
        }
        Some(_) => {}
        None => {
            sqlx::query!(
                "UPDATE users SET bot_prefix = ? WHERE id = ?",
                prefix,
                bot_user_id
            )
            .execute(&mut *tx)
            .await?;
        }
    }

    let others = sqlx::query!(
        r#"SELECT u.display_name, c.name
           FROM bot_command_registrations r
           JOIN users u ON u.id = r.bot_user_id
           JOIN bot_commands c ON c.bot_user_id = r.bot_user_id
           JOIN bot_tokens t ON t.bot_user_id = u.id AND t.revoked_at IS NULL
           WHERE r.prefix = ? AND r.bot_user_id != ?
             AND u.is_bot = 1 AND u.deleted_at IS NULL
             AND NOT EXISTS (SELECT 1 FROM space_removals sr WHERE sr.user_id = u.id)
           ORDER BY u.created_at ASC"#,
        prefix,
        bot_user_id
    )
    .fetch_all(&mut *tx)
    .await?;
    let mine: HashSet<String> = commands.iter().map(|c| c.name.to_lowercase()).collect();
    if let Some(clash) = others
        .into_iter()
        .find(|other| mine.contains(&other.name.to_lowercase()))
    {
        return Err(SetBotCommandsError::CommandTaken {
            bot_display_name: clash.display_name,
            prefix: prefix.to_owned(),
            command: clash.name,
        });
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_free_skips_taken_and_doubles_when_singles_run_out() {
        let mut taken = HashSet::new();
        assert_eq!(first_free(&taken).as_deref(), Some("!"));
        taken.insert("!".to_owned());
        assert_eq!(first_free(&taken).as_deref(), Some("?"));
        taken.extend(SUGGESTED_PREFIXES.iter().map(|p| (*p).to_owned()));
        assert_eq!(first_free(&taken).as_deref(), Some("!!"));
    }
}
