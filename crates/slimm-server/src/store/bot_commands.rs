// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A bot's own registered prefix and command palette. See
//! docs/decisions/0031-bot-command-registration.md.

use std::collections::HashMap;

use crate::hidden_chars::is_hidden_char;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;

use super::bot_command_options::{
    BotCommandOption, options_from_json, options_to_json, validate_bot_options,
};
use super::{Store, now_ms};

/// Caps kept in prose in `schema/openapi.yaml` per this project's convention
/// for parameter constraints the additive-schema gate cannot express.
pub const MAX_BOT_COMMANDS: usize = 50;
pub const MAX_BOT_PREFIX_LEN: usize = 16;
pub const MAX_BOT_COMMAND_NAME_LEN: usize = 32;
pub const MAX_BOT_COMMAND_DESCRIPTION_LEN: usize = 100;
pub const MAX_BOT_COMMAND_USAGE_LEN: usize = 80;

/// Composer triggers a bot prefix may not claim; see decision 0031.
pub const RESERVED_BOT_PREFIXES: [&str; 3] = ["/", "@", ":"];

/// One command a bot advertises.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BotCommand {
    pub name: String,
    pub description: String,
    pub usage: Option<String>,
    /// A single [`Permissions`] bit; a composer hint only, never enforced.
    pub permission: Option<i64>,
    /// Positional arguments, with the fixed choices of each.
    pub options: Vec<BotCommandOption>,
}

/// A bot's whole registration: its own prefix, plus every command it
/// currently advertises, in the order it declared them.
#[derive(Debug, Clone)]
pub struct BotCommandRegistration {
    pub prefix: String,
    pub commands: Vec<BotCommand>,
}

/// Why a registration attempt was refused.
#[derive(Debug)]
pub enum SetBotCommandsError {
    TooManyCommands,
    InvalidPrefix(&'static str),
    InvalidCommand(&'static str),
    /// The bot was assigned a different prefix when it was created.
    PrefixNotAssigned {
        assigned: String,
    },
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for SetBotCommandsError {
    fn from(err: sqlx::Error) -> Self {
        SetBotCommandsError::Internal(err.into())
    }
}

/// One command a viewer of a channel may currently be offered, with the bot
/// that registered it.
#[derive(Debug, Clone)]
pub struct VisibleBotCommand {
    pub bot_user_id: UserId,
    pub bot_username: String,
    pub bot_display_name: String,
    pub prefix: String,
    pub command: BotCommand,
}

/// A prefix must be short, whitespace-free, and not one of the composer's own
/// reserved triggers.
pub fn validate_bot_prefix(prefix: &str) -> Result<(), &'static str> {
    if prefix.is_empty() || prefix.chars().count() > MAX_BOT_PREFIX_LEN {
        return Err("a bot's prefix must be 1 to 16 characters");
    }
    if prefix
        .chars()
        .any(|c| c.is_whitespace() || is_hidden_char(c))
    {
        return Err("a bot's prefix must not contain whitespace");
    }
    if RESERVED_BOT_PREFIXES.contains(&prefix) {
        return Err("a bot's prefix must not be one of the reserved composer triggers / @ :");
    }
    Ok(())
}

/// A command name is a bare keyword (no leading punctuation - the prefix
/// supplies that), matching the charset a module's own slash-command name
/// already keeps to.
fn validate_bot_command(command: &BotCommand) -> Result<(), &'static str> {
    if command.name.is_empty() || command.name.chars().count() > MAX_BOT_COMMAND_NAME_LEN {
        return Err("a command name must be 1 to 32 characters");
    }
    if !command
        .name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err("a command name may only hold letters, digits, - and _");
    }
    if command.description.is_empty()
        || command.description.chars().count() > MAX_BOT_COMMAND_DESCRIPTION_LEN
    {
        return Err("a command description must be 1 to 100 characters");
    }
    if let Some(usage) = &command.usage
        && usage.chars().count() > MAX_BOT_COMMAND_USAGE_LEN
    {
        return Err("a command's usage hint must be at most 80 characters");
    }
    let usage = command.usage.as_deref().unwrap_or("");
    if command
        .description
        .chars()
        .chain(usage.chars())
        .any(is_hidden_char)
    {
        return Err(
            "a command's description and usage must not hold control or invisible characters",
        );
    }
    validate_bot_options(&command.options)?;
    if let Some(bit) = command.permission {
        let perm = Permissions::from_bits(bit);
        let single_bit = bit > 0 && (bit & (bit - 1)) == 0;
        if !single_bit || !Permissions::ALL.contains(perm) {
            return Err("a command's permission must be exactly one known permission bit");
        }
    }
    Ok(())
}

impl Store {
    /// Replaces a bot's whole registration in one transaction, all or
    /// nothing on a validation failure. Returns the newly added names dropped
    /// because another live bot already answers to them.
    pub async fn set_bot_commands(
        &self,
        bot_user_id: UserId,
        prefix: &str,
        commands: &[BotCommand],
    ) -> Result<Vec<String>, SetBotCommandsError> {
        validate_bot_prefix(prefix).map_err(SetBotCommandsError::InvalidPrefix)?;
        if commands.len() > MAX_BOT_COMMANDS {
            return Err(SetBotCommandsError::TooManyCommands);
        }
        let mut seen = std::collections::HashSet::with_capacity(commands.len());
        for command in commands {
            validate_bot_command(command).map_err(SetBotCommandsError::InvalidCommand)?;
            if !seen.insert(command.name.to_lowercase()) {
                return Err(SetBotCommandsError::InvalidCommand(
                    "a bot cannot register the same command name twice",
                ));
            }
        }

        let now = now_ms();
        let mut tx = self.begin_write().await?;
        let dropped =
            super::bot_prefix::claim_registration(&mut tx, bot_user_id, prefix, commands).await?;
        let commands: Vec<&BotCommand> = commands
            .iter()
            .filter(|c| !dropped.contains(&c.name.to_lowercase()))
            .collect();
        sqlx::query!(
            "INSERT INTO bot_command_registrations (bot_user_id, prefix, updated_at)
             VALUES (?, ?, ?)
             ON CONFLICT (bot_user_id) DO UPDATE SET prefix = excluded.prefix, updated_at = excluded.updated_at",
            bot_user_id,
            prefix,
            now
        )
        .execute(&mut *tx)
        .await?;
        sqlx::query!(
            "DELETE FROM bot_commands WHERE bot_user_id = ?",
            bot_user_id
        )
        .execute(&mut *tx)
        .await?;
        for (position, command) in commands.iter().enumerate() {
            let position = position as i64;
            let options = options_to_json(&command.options);
            sqlx::query!(
                "INSERT INTO bot_commands (bot_user_id, name, description, usage, permission, position, options)
                 VALUES (?, ?, ?, ?, ?, ?, ?)",
                bot_user_id,
                command.name,
                command.description,
                command.usage,
                command.permission,
                position,
                options
            )
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(dropped)
    }

    /// A bot's whole current registration, unfiltered - see
    /// [`Store::visible_bot_commands`] for the filtered discovery list.
    pub async fn bot_commands(
        &self,
        bot_user_id: UserId,
    ) -> anyhow::Result<Option<BotCommandRegistration>> {
        let Some(reg) = sqlx::query!(
            "SELECT prefix FROM bot_command_registrations WHERE bot_user_id = ?",
            bot_user_id
        )
        .fetch_optional(&self.pool)
        .await?
        else {
            return Ok(None);
        };
        let rows = sqlx::query!(
            "SELECT name, description, usage, permission, options
             FROM bot_commands WHERE bot_user_id = ? ORDER BY position ASC",
            bot_user_id
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(Some(BotCommandRegistration {
            prefix: reg.prefix,
            commands: rows
                .into_iter()
                .map(|r| BotCommand {
                    name: r.name,
                    description: r.description,
                    usage: r.usage,
                    permission: r.permission,
                    options: options_from_json(r.options.as_deref()),
                })
                .collect(),
        }))
    }

    /// The composer's discovery list: every command a caller may currently
    /// be offered in `channel_id`. See decision 0031 for the visibility and
    /// permission rules this applies.
    pub async fn visible_bot_commands(
        &self,
        channel_id: ChannelId,
        caller_permissions: Permissions,
    ) -> anyhow::Result<Vec<VisibleBotCommand>> {
        let rows = sqlx::query!(
            r#"SELECT u.id AS "bot_user_id!: UserId", u.username, u.display_name,
                      r.prefix, c.name, c.description, c.usage, c.permission, c.options
               FROM bot_command_registrations r
               JOIN users u ON u.id = r.bot_user_id
               JOIN bot_commands c ON c.bot_user_id = r.bot_user_id
               JOIN bot_tokens t ON t.bot_user_id = u.id AND t.revoked_at IS NULL
               WHERE u.is_bot = 1 AND u.deleted_at IS NULL
                 AND NOT EXISTS (SELECT 1 FROM space_removals sr WHERE sr.user_id = u.id)
               ORDER BY r.prefix ASC, r.updated_at ASC, u.created_at ASC, c.position ASC"#,
        )
        .fetch_all(&self.pool)
        .await?;

        // Registration refuses a clash now; this keeps rows registered before that from listing twice.
        let mut answered = std::collections::HashSet::new();
        let mut can_view: HashMap<UserId, bool> = HashMap::new();
        let mut visible = Vec::new();
        for row in rows {
            if let Some(bit) = row.permission
                && !caller_permissions.contains(Permissions::from_bits(bit))
            {
                continue;
            }
            let allowed = match can_view.get(&row.bot_user_id) {
                Some(allowed) => *allowed,
                None => {
                    let allowed = self
                        .permissions_in_channel(row.bot_user_id, channel_id)
                        .await?
                        .contains(Permissions::VIEW_CHANNEL);
                    can_view.insert(row.bot_user_id, allowed);
                    allowed
                }
            };
            if !allowed || !answered.insert((row.prefix.clone(), row.name.to_lowercase())) {
                continue;
            }
            visible.push(VisibleBotCommand {
                bot_user_id: row.bot_user_id,
                bot_username: row.username,
                bot_display_name: row.display_name,
                prefix: row.prefix,
                command: BotCommand {
                    name: row.name,
                    description: row.description,
                    usage: row.usage,
                    permission: row.permission,
                    options: options_from_json(row.options.as_deref()),
                },
            });
        }
        Ok(visible)
    }
}
