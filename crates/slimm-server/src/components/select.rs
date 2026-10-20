// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A select menu on a bot message: one row, one menu, a bounded list of
//! choices. See docs/decisions/0082-bot-token-reissue-select-menus-and-forms.md.

use serde::{Deserialize, Serialize};

pub const MAX_OPTIONS: usize = 25;
pub const MAX_PLACEHOLDER_CHARS: usize = 100;
pub const MAX_DESCRIPTION_CHARS: usize = 100;

fn one() -> u8 {
    1
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SelectOption {
    pub label: String,
    /// What the bot receives when this option is chosen.
    pub value: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Select {
    pub custom_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub placeholder: Option<String>,
    pub options: Vec<SelectOption>,
    /// How few options a choice may hold. Zero lets a member clear the menu.
    #[serde(default = "one")]
    pub min_values: u8,
    #[serde(default = "one")]
    pub max_values: u8,
    #[serde(default)]
    pub disabled: bool,
}

/// Checks a menu against the caps and trims its text. `hidden` is the
/// deployment's spoofing-character test.
pub(super) fn validate(select: &mut Select, hidden: fn(char) -> bool) -> Result<(), &'static str> {
    super::check_custom_id(&select.custom_id, hidden)?;
    if let Some(text) = select.placeholder.as_mut() {
        *text = text.trim().to_owned();
        if text.chars().count() > MAX_PLACEHOLDER_CHARS {
            return Err("select placeholder is too long");
        }
        if text.chars().any(hidden) {
            return Err("a select placeholder cannot hold control or invisible characters");
        }
    }
    if select.options.is_empty() || select.options.len() > MAX_OPTIONS {
        return Err("a select needs 1 to 25 options");
    }
    let mut values = std::collections::HashSet::new();
    for option in &mut select.options {
        validate_option(option, hidden)?;
        if !values.insert(option.value.clone()) {
            return Err("select option values must be unique");
        }
    }
    let choices = select.options.len();
    if select.max_values == 0 || usize::from(select.max_values) > choices {
        return Err("max_values must be between 1 and the number of options");
    }
    if select.min_values > select.max_values {
        return Err("min_values cannot exceed max_values");
    }
    Ok(())
}

fn validate_option(
    option: &mut SelectOption,
    hidden: fn(char) -> bool,
) -> Result<(), &'static str> {
    option.label = option.label.trim().to_owned();
    if option.label.is_empty() || option.label.chars().count() > super::MAX_LABEL_CHARS {
        return Err("an option label must be 1 to 80 characters");
    }
    if option.label.chars().any(hidden) {
        return Err("an option label cannot hold control or invisible characters");
    }
    super::check_custom_id(&option.value, hidden)
        .map_err(|_| "an option value must be 1 to 100 visible characters")?;
    if let Some(text) = option.description.as_mut() {
        *text = text.trim().to_owned();
        if text.chars().count() > MAX_DESCRIPTION_CHARS {
            return Err("an option description is too long");
        }
        if text.chars().any(hidden) {
            return Err("an option description cannot hold control or invisible characters");
        }
    }
    Ok(())
}

impl Select {
    /// Whether `chosen` is a legal answer: each value offered, none twice, and
    /// a count inside the menu's bounds.
    pub fn accepts(&self, chosen: &[String]) -> bool {
        let count = chosen.len();
        let distinct = chosen
            .iter()
            .collect::<std::collections::HashSet<_>>()
            .len()
            == count;
        distinct
            && (usize::from(self.min_values)..=usize::from(self.max_values)).contains(&count)
            && chosen
                .iter()
                .all(|v| self.options.iter().any(|o| &o.value == v))
    }
}
