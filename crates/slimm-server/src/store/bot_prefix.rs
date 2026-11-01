// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which prefix each bot answers to. See docs/decisions/0069-bot-prefix-assignment.md.

use std::collections::HashSet;

use sqlx::SqliteConnection;

use super::bot_commands::{BotCommand, SetBotCommandsError};
use crate::ids::UserId;

use super::Store;
use super::now_ms;

/// Why changing a bot's prefix failed.
#[derive(Debug)]
pub enum SetBotPrefixError {
    /// No bot by that id.
    NoSuchBot,
    /// The commands the bot registered that another live bot already answers to under the new prefix.
    Overlap(Vec<String>),
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for SetBotPrefixError {
    fn from(err: sqlx::Error) -> Self {
        SetBotPrefixError::Internal(err.into())
    }
}

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

    /// Moves a bot to `prefix` (already validated by `http::bots`) and its registered commands with it.
    /// Two bots may share a prefix only when no command name is on both, the rule registration applies.
    pub async fn set_bot_prefix(
        &self,
        bot_user_id: UserId,
        prefix: &str,
    ) -> Result<(), SetBotPrefixError> {
        let mut tx = self.begin_write().await?;
        let exists = sqlx::query_scalar!(
            r#"SELECT id AS "id!: UserId" FROM users WHERE id = ? AND is_bot = 1 AND deleted_at IS NULL"#,
            bot_user_id
        )
        .fetch_optional(&mut *tx)
        .await?;
        if exists.is_none() {
            return Err(SetBotPrefixError::NoSuchBot);
        }
        let clashes = clashing_commands(&mut tx, bot_user_id, prefix).await?;
        if !clashes.is_empty() {
            return Err(SetBotPrefixError::Overlap(clashes));
        }
        sqlx::query!(
            "UPDATE users SET bot_prefix = ? WHERE id = ?",
            prefix,
            bot_user_id
        )
        .execute(&mut *tx)
        .await?;
        let now = now_ms();
        sqlx::query!(
            "UPDATE bot_command_registrations SET prefix = ?, updated_at = ? WHERE bot_user_id = ?",
            prefix,
            now,
            bot_user_id
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(())
    }
}

/// Names this bot has registered that a different live bot already answers to under `prefix`.
async fn clashing_commands(
    tx: &mut SqliteConnection,
    bot_user_id: UserId,
    prefix: &str,
) -> Result<Vec<String>, sqlx::Error> {
    let mine = sqlx::query_scalar!(
        "SELECT name FROM bot_commands WHERE bot_user_id = ?",
        bot_user_id
    )
    .fetch_all(&mut *tx)
    .await?;
    let theirs: HashSet<String> = live_commands_under(tx, prefix, bot_user_id).await?;
    let mut clashes: Vec<String> = mine
        .into_iter()
        .filter(|name| theirs.contains(&name.to_lowercase()))
        .collect();
    clashes.sort();
    Ok(clashes)
}

/// Lowercased command names other live bots have registered under `prefix`.
async fn live_commands_under(
    tx: &mut SqliteConnection,
    prefix: &str,
    except: UserId,
) -> Result<HashSet<String>, sqlx::Error> {
    let names = sqlx::query_scalar!(
        r#"SELECT c.name
           FROM bot_command_registrations r
           JOIN users u ON u.id = r.bot_user_id
           JOIN bot_commands c ON c.bot_user_id = r.bot_user_id
           JOIN bot_tokens t ON t.bot_user_id = u.id AND t.revoked_at IS NULL
           WHERE r.prefix = ? AND r.bot_user_id != ?
             AND u.is_bot = 1 AND u.deleted_at IS NULL
             AND NOT EXISTS (SELECT 1 FROM space_removals sr WHERE sr.user_id = u.id)"#,
        prefix,
        except
    )
    .fetch_all(&mut *tx)
    .await?;
    Ok(names.into_iter().map(|name| name.to_lowercase()).collect())
}

/// Runs inside the registration transaction: the prefix must be the one assigned
/// (or adopts it for a bot that has none). Returns the newly added command names
/// another live bot already answers to; a bot keeps every name it already held.
pub(super) async fn claim_registration(
    tx: &mut SqliteConnection,
    bot_user_id: UserId,
    prefix: &str,
    commands: &[BotCommand],
) -> Result<Vec<String>, SetBotCommandsError> {
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

    let held: HashSet<String> = sqlx::query_scalar!(
        "SELECT c.name FROM bot_commands c
         JOIN bot_command_registrations r ON r.bot_user_id = c.bot_user_id
         WHERE c.bot_user_id = ? AND r.prefix = ?",
        bot_user_id,
        prefix
    )
    .fetch_all(&mut *tx)
    .await?
    .into_iter()
    .map(|name| name.to_lowercase())
    .collect();
    let others = live_commands_under(tx, prefix, bot_user_id).await?;
    Ok(commands
        .iter()
        .map(|c| c.name.to_lowercase())
        .filter(|name| !held.contains(name) && others.contains(name))
        .collect())
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
