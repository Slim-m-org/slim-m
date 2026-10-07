// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The message context menu entries and call controls a bot registers, and
//! the caps that keep them bounded. See docs/decisions/0045-bot-contributed-ui.md.
//!
//! One shape serves the wire and storage, and `validate` is the only writer of
//! the caps.

use serde::{Deserialize, Serialize};

/// Entries one bot may add to a message's menu. Discord's own ceiling.
pub const MAX_MENU_ENTRIES: usize = 5;
/// Controls one bot may show in a call.
pub const MAX_CALL_CONTROLS: usize = 8;
pub const MAX_LABEL_CHARS: usize = 32;
pub const MAX_ENTRY_ID_CHARS: usize = 64;
/// Choices one call control may offer; fewer than two is a plain button.
pub const MAX_CONTROL_OPTIONS: usize = 8;

/// Glyphs a call control may name. The client draws them from its own icon
/// set, so a bot chooses a picture but never supplies one.
pub const CALL_ICONS: [&str; 11] = [
    "play",
    "pause",
    "stop",
    "skip_next",
    "skip_previous",
    "volume",
    "volume_off",
    "repeat",
    "shuffle",
    "list",
    "settings",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
/// Where a registered entry shows.
#[serde(rename_all = "snake_case")]
pub enum Surface {
    MessageMenu,
    CallControl,
}

impl Surface {
    pub fn as_str(self) -> &'static str {
        match self {
            Surface::MessageMenu => "message_menu",
            Surface::CallControl => "call_control",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "message_menu" => Some(Surface::MessageMenu),
            "call_control" => Some(Surface::CallControl),
            _ => None,
        }
    }

    fn cap(self) -> usize {
        match self {
            Surface::MessageMenu => MAX_MENU_ENTRIES,
            Surface::CallControl => MAX_CALL_CONTROLS,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UiEntry {
    pub id: String,
    pub label: String,
    /// One of [`CALL_ICONS`]; call controls only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    /// A single `Permissions` bit the member must hold in the channel.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub permission: Option<i64>,
    /// The choices a call control offers; empty for a plain button.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub options: Vec<UiOption>,
}

/// One choice a call control offers. The member's pick reaches the bot as the
/// interaction's `option_id`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UiOption {
    pub id: String,
    pub label: String,
}

/// A bot's whole registration across both surfaces.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct UiRegistration {
    #[serde(default)]
    pub message_menu: Vec<UiEntry>,
    #[serde(default)]
    pub call_controls: Vec<UiEntry>,
}

/// Checks a registration against the caps and returns it with labels trimmed.
/// The error is the wire-facing text.
///
/// `hidden` is the deployment's spoofing-character test, applied to every
/// label.
pub fn validate(
    mut reg: UiRegistration,
    hidden: fn(char) -> bool,
) -> Result<UiRegistration, &'static str> {
    validate_surface(&mut reg.message_menu, Surface::MessageMenu, hidden)?;
    validate_surface(&mut reg.call_controls, Surface::CallControl, hidden)?;
    Ok(reg)
}

fn validate_surface(
    entries: &mut [UiEntry],
    surface: Surface,
    hidden: fn(char) -> bool,
) -> Result<(), &'static str> {
    if entries.len() > surface.cap() {
        return Err(match surface {
            Surface::MessageMenu => "too many message menu entries",
            Surface::CallControl => "too many call controls",
        });
    }
    let mut seen = std::collections::HashSet::new();
    for entry in entries {
        validate_entry(entry, surface, hidden)?;
        if !seen.insert(entry.id.clone()) {
            return Err("an entry id must be unique within its surface");
        }
    }
    Ok(())
}

fn validate_entry(
    entry: &mut UiEntry,
    surface: Surface,
    hidden: fn(char) -> bool,
) -> Result<(), &'static str> {
    entry.label = checked_label(&entry.label, hidden)?;
    check_id(&entry.id)?;
    match (&entry.icon, surface) {
        (Some(_), Surface::MessageMenu) => return Err("only a call control takes an icon"),
        (Some(icon), Surface::CallControl) if !CALL_ICONS.contains(&icon.as_str()) => {
            return Err("unknown call control icon");
        }
        _ => {}
    }
    if let Some(bit) = entry.permission {
        let known = crate::permissions::Permissions::from_bits(bit);
        let single_bit = bit > 0 && (bit & (bit - 1)) == 0;
        if !single_bit || !crate::permissions::Permissions::ALL.contains(known) {
            return Err("an entry's permission must be exactly one known permission bit");
        }
    }
    validate_options(&mut entry.options, surface, hidden)
}

fn validate_options(
    options: &mut [UiOption],
    surface: Surface,
    hidden: fn(char) -> bool,
) -> Result<(), &'static str> {
    if options.is_empty() {
        return Ok(());
    }
    if surface != Surface::CallControl {
        return Err("only a call control offers options");
    }
    if options.len() < 2 || options.len() > MAX_CONTROL_OPTIONS {
        return Err("a call control offers 2 to 8 options");
    }
    let mut seen = std::collections::HashSet::new();
    for option in options {
        option.label = checked_label(&option.label, hidden)?;
        check_id(&option.id)?;
        if !seen.insert(option.id.clone()) {
            return Err("an option id must be unique within its control");
        }
    }
    Ok(())
}

fn checked_label(label: &str, hidden: fn(char) -> bool) -> Result<String, &'static str> {
    let label = label.trim();
    if label.is_empty() {
        return Err("an entry needs a label");
    }
    if label.chars().count() > MAX_LABEL_CHARS {
        return Err("entry label is too long");
    }
    if label.chars().any(hidden) {
        return Err("an entry label cannot hold control or invisible characters");
    }
    Ok(label.to_owned())
}

fn check_id(id: &str) -> Result<(), &'static str> {
    if id.is_empty() || id.chars().count() > MAX_ENTRY_ID_CHARS {
        return Err("an entry id must be 1 to 64 characters");
    }
    if !id
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.')
    {
        return Err("an entry id may only hold letters, digits, - _ and .");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hidden(c: char) -> bool {
        c.is_control() || c == '\u{202E}' || c == '\u{200B}'
    }

    fn entry(id: &str, label: &str) -> UiEntry {
        UiEntry {
            id: id.into(),
            label: label.into(),
            icon: None,
            permission: None,
            options: Vec::new(),
        }
    }

    fn option(id: &str, label: &str) -> UiOption {
        UiOption {
            id: id.into(),
            label: label.into(),
        }
    }

    fn menu(entries: Vec<UiEntry>) -> UiRegistration {
        UiRegistration {
            message_menu: entries,
            call_controls: Vec::new(),
        }
    }

    fn controls(entries: Vec<UiEntry>) -> UiRegistration {
        UiRegistration {
            message_menu: Vec::new(),
            call_controls: entries,
        }
    }

    #[test]
    fn a_plain_registration_passes_and_trims_labels() {
        let reg = validate(menu(vec![entry("tr", "  Translate ")]), hidden).unwrap();
        assert_eq!(reg.message_menu[0].label, "Translate");
    }

    #[test]
    fn the_caps_are_enforced_per_surface() {
        let many = (0..=MAX_MENU_ENTRIES)
            .map(|i| entry(&format!("e{i}"), "x"))
            .collect();
        assert!(validate(menu(many), hidden).is_err());
        let many = (0..=MAX_CALL_CONTROLS)
            .map(|i| entry(&format!("c{i}"), "x"))
            .collect();
        assert!(validate(controls(many), hidden).is_err());
        let long = "x".repeat(MAX_LABEL_CHARS + 1);
        assert!(validate(menu(vec![entry("a", &long)]), hidden).is_err());
    }

    #[test]
    fn hidden_characters_and_duplicates_are_refused() {
        assert!(validate(menu(vec![entry("a", "Tran\u{202E}slate")]), hidden).is_err());
        assert!(validate(menu(vec![entry("a", "One"), entry("a", "Two")]), hidden).is_err());
        assert!(validate(menu(vec![entry("a b", "One")]), hidden).is_err());
        assert!(validate(menu(vec![entry("", "One")]), hidden).is_err());
    }

    #[test]
    fn icons_belong_to_call_controls_and_come_from_the_list() {
        let mut with_icon = entry("a", "Play");
        with_icon.icon = Some("play".into());
        assert!(validate(menu(vec![with_icon.clone()]), hidden).is_err());
        assert!(validate(controls(vec![with_icon.clone()]), hidden).is_ok());
        with_icon.icon = Some("skull".into());
        assert!(validate(controls(vec![with_icon]), hidden).is_err());
    }

    #[test]
    fn a_call_control_may_offer_two_to_eight_options() {
        let mut quality = entry("quality", "Quality");
        quality.icon = Some("settings".into());
        quality.options = vec![option("low", " Low 480p "), option("high", "High 1080p")];
        let reg = validate(controls(vec![quality.clone()]), hidden).unwrap();
        assert_eq!(reg.call_controls[0].options[0].label, "Low 480p");

        quality.options.truncate(1);
        assert!(validate(controls(vec![quality.clone()]), hidden).is_err());
        quality.options = (0..=MAX_CONTROL_OPTIONS)
            .map(|i| option(&format!("o{i}"), "x"))
            .collect();
        assert!(validate(controls(vec![quality]), hidden).is_err());
    }

    #[test]
    fn options_are_checked_like_entries_and_belong_to_call_controls() {
        let mut picker = entry("p", "Pick");
        picker.options = vec![option("a", "One"), option("b", "Two")];
        assert!(validate(menu(vec![picker.clone()]), hidden).is_err());
        picker.options = vec![option("a", "One"), option("a", "Two")];
        assert!(validate(controls(vec![picker.clone()]), hidden).is_err());
        picker.options = vec![option("a b", "One"), option("c", "Two")];
        assert!(validate(controls(vec![picker.clone()]), hidden).is_err());
        picker.options = vec![option("a", "On\u{202E}e"), option("c", "Two")];
        assert!(validate(controls(vec![picker]), hidden).is_err());
    }
}
