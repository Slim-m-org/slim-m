// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The arguments a bot command declares, and the fixed choices of each.

use serde::{Deserialize, Serialize};

use crate::hidden_chars::is_hidden_char;

pub const MAX_BOT_COMMAND_OPTIONS: usize = 5;
pub const MAX_BOT_OPTION_CHOICES: usize = 25;
pub const MAX_BOT_OPTION_NAME_LEN: usize = 32;
pub const MAX_BOT_OPTION_CHOICE_LEN: usize = 100;

/// One positional argument of a command.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BotCommandOption {
    pub name: String,
    #[serde(default)]
    pub required: bool,
    /// Empty means free form: the member types the value.
    #[serde(default)]
    pub choices: Vec<String>,
}

/// Checks the options of one command; the message is shown to the bot's author.
pub fn validate_bot_options(options: &[BotCommandOption]) -> Result<(), &'static str> {
    if options.len() > MAX_BOT_COMMAND_OPTIONS {
        return Err("a command may declare at most 5 options");
    }
    let mut names = std::collections::HashSet::new();
    for option in options {
        validate_option(option)?;
        if !names.insert(option.name.to_lowercase()) {
            return Err("a command cannot declare the same option name twice");
        }
    }
    Ok(())
}

fn validate_option(option: &BotCommandOption) -> Result<(), &'static str> {
    let name_len = option.name.chars().count();
    if name_len == 0 || name_len > MAX_BOT_OPTION_NAME_LEN {
        return Err("an option name must be 1 to 32 characters");
    }
    if !option
        .name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        return Err("an option name may only hold letters, digits, - and _");
    }
    if option.choices.len() > MAX_BOT_OPTION_CHOICES {
        return Err("an option may offer at most 25 choices");
    }
    let mut seen = std::collections::HashSet::new();
    for choice in &option.choices {
        let len = choice.chars().count();
        if len == 0 || len > MAX_BOT_OPTION_CHOICE_LEN {
            return Err("an option choice must be 1 to 100 characters");
        }
        if choice
            .chars()
            .any(|c| c.is_whitespace() || is_hidden_char(c))
        {
            return Err("an option choice must not contain whitespace or invisible characters");
        }
        if !seen.insert(choice.to_lowercase()) {
            return Err("an option cannot offer the same choice twice");
        }
    }
    Ok(())
}

/// Options as stored: absent when a command declares none.
pub fn options_to_json(options: &[BotCommandOption]) -> Option<String> {
    (!options.is_empty()).then(|| serde_json::to_string(options).unwrap_or_default())
}

pub fn options_from_json(json: Option<&str>) -> Vec<BotCommandOption> {
    json.and_then(|j| serde_json::from_str(j).ok())
        .unwrap_or_default()
}
