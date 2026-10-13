// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Buttons a bot attaches to its own message, and the caps that keep them
//! bounded. See docs/decisions/0039-bot-message-buttons.md.
//!
//! One shape serves the wire and storage: a bot sends it, the server checks it
//! once here, stores it as JSON and reads it back unchanged.

use serde::{Deserialize, Serialize};

/// Rows a message may carry. Discord's own ceiling, so its bots port cleanly.
pub const MAX_ROWS: usize = 5;
pub const MAX_BUTTONS_PER_ROW: usize = 5;
pub const MAX_LABEL_CHARS: usize = 80;
pub const MAX_CUSTOM_ID_CHARS: usize = 100;
pub const MAX_URL_CHARS: usize = 512;

/// How long a click can still be answered. Also the lifetime of its row.
pub const INTERACTION_WINDOW_MS: i64 = 15 * 60 * 1000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
/// How a button looks; a link opens a page instead of reaching the bot.
#[serde(rename_all = "snake_case")]
pub enum ButtonStyle {
    Primary,
    Secondary,
    Danger,
    Link,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Button {
    pub label: String,
    pub style: ButtonStyle,
    /// Present on every button except a link, which never reaches the bot.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_id: Option<String>,
    /// Present only on a link button.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default)]
    pub disabled: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ComponentRow {
    pub buttons: Vec<Button>,
}

/// Checks a bot's rows against the caps and returns them trimmed. The error is
/// the wire-facing text.
///
/// `hidden` is the deployment's spoofing-character test (zero-width, bidi and
/// control characters), applied to every label and `custom_id`.
pub fn validate(
    mut rows: Vec<ComponentRow>,
    hidden: fn(char) -> bool,
) -> Result<Vec<ComponentRow>, &'static str> {
    if rows.len() > MAX_ROWS {
        return Err("too many component rows");
    }
    let mut seen = std::collections::HashSet::new();
    for row in &mut rows {
        if row.buttons.is_empty() {
            return Err("a component row must hold at least one button");
        }
        if row.buttons.len() > MAX_BUTTONS_PER_ROW {
            return Err("too many buttons in a row");
        }
        for button in &mut row.buttons {
            validate_button(button, hidden)?;
            if let Some(id) = &button.custom_id
                && !seen.insert(id.clone())
            {
                return Err("custom_id must be unique within a message");
            }
        }
    }
    Ok(rows)
}

fn validate_button(button: &mut Button, hidden: fn(char) -> bool) -> Result<(), &'static str> {
    button.label = button.label.trim().to_owned();
    if button.label.is_empty() {
        return Err("a button needs a label");
    }
    if button.label.chars().count() > MAX_LABEL_CHARS {
        return Err("button label is too long");
    }
    if button.label.chars().any(hidden) {
        return Err("a button label cannot hold control or invisible characters");
    }
    if button.style == ButtonStyle::Link {
        return validate_link(button, hidden);
    }
    if button.url.is_some() {
        return Err("only a link button takes a url");
    }
    let id = button
        .custom_id
        .as_deref()
        .ok_or("a button needs a custom_id")?;
    if id.is_empty() || id.chars().count() > MAX_CUSTOM_ID_CHARS {
        return Err("custom_id must be 1 to 100 characters");
    }
    if id.chars().any(hidden) {
        return Err("custom_id cannot hold control or invisible characters");
    }
    Ok(())
}

fn validate_link(button: &mut Button, hidden: fn(char) -> bool) -> Result<(), &'static str> {
    if button.custom_id.is_some() {
        return Err("a link button takes a url, not a custom_id");
    }
    let raw = button.url.as_deref().ok_or("a link button needs a url")?;
    let url = checked_link(raw, hidden).map_err(|problem| match problem {
        LinkProblem::TooLong => "button url is too long",
        LinkProblem::Hidden => "a button url cannot hold spaces, control or invisible characters",
        LinkProblem::Unreadable => "a button url could not be read",
        LinkProblem::Scheme => "a button url must be http or https",
        LinkProblem::NoHost => "a button url needs a host",
        LinkProblem::Credentials => "a button url cannot carry a username or password",
    })?;
    button.url = Some(url);
    Ok(())
}

/// Why [`checked_link`] refused a link.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LinkProblem {
    TooLong,
    Hidden,
    Unreadable,
    Scheme,
    NoHost,
    Credentials,
}

/// A link a client may show as clickable: http or https, a plain host, no
/// credentials, at most [`MAX_URL_CHARS`]. Returns it as the parser writes it.
pub fn checked_link(raw: &str, hidden: fn(char) -> bool) -> Result<String, LinkProblem> {
    if raw.chars().count() > MAX_URL_CHARS {
        return Err(LinkProblem::TooLong);
    }
    // Checked on the raw text: the parser silently drops tabs and newlines and trims spaces.
    if raw.chars().any(|c| c.is_whitespace() || hidden(c)) {
        return Err(LinkProblem::Hidden);
    }
    let url = url::Url::parse(raw).map_err(|_| LinkProblem::Unreadable)?;
    if !matches!(url.scheme(), "http" | "https") {
        return Err(LinkProblem::Scheme);
    }
    // The parser forgives `https:///host` and `https:\\host`; a link that needs forgiving is not shown as written.
    let authority_start = format!("{}://", url.scheme());
    let plain_authority = raw
        .get(..authority_start.len())
        .is_some_and(|head| head.eq_ignore_ascii_case(&authority_start))
        && !raw[authority_start.len()..].starts_with(['/', '\\', '?', '#']);
    if !plain_authority || url.host_str().is_none_or(str::is_empty) {
        return Err(LinkProblem::NoHost);
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err(LinkProblem::Credentials);
    }
    if url.as_str().chars().count() > MAX_URL_CHARS {
        return Err(LinkProblem::TooLong);
    }
    Ok(url.into())
}

/// The enabled, non-link button carrying `custom_id`, if any.
pub fn clickable<'a>(rows: &'a [ComponentRow], custom_id: &str) -> Option<&'a Button> {
    rows.iter()
        .flat_map(|row| &row.buttons)
        .find(|b| b.custom_id.as_deref() == Some(custom_id) && !b.disabled)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn button(id: &str) -> Button {
        Button {
            label: "Hit".into(),
            style: ButtonStyle::Primary,
            custom_id: Some(id.into()),
            url: None,
            disabled: false,
        }
    }

    fn row(buttons: Vec<Button>) -> ComponentRow {
        ComponentRow { buttons }
    }

    fn no_hidden(_: char) -> bool {
        false
    }

    fn zero_width(c: char) -> bool {
        c.is_control() || c == '\u{200B}' || c == '\u{202E}'
    }

    fn link(url: &str) -> Button {
        Button {
            label: "Docs".into(),
            style: ButtonStyle::Link,
            custom_id: None,
            url: Some(url.into()),
            disabled: false,
        }
    }

    fn checked_url(url: &str) -> Result<String, &'static str> {
        let rows = validate(vec![row(vec![link(url)])], zero_width)?;
        Ok(rows[0].buttons[0].url.clone().unwrap())
    }

    #[test]
    fn a_link_must_be_a_plain_http_url_with_a_host_and_no_userinfo() {
        assert_eq!(
            checked_url("https://Example.com").unwrap(),
            "https://example.com/"
        );
        for bad in [
            "https://user:pw@example.com/",
            "https://example.com@evil.example/x",
            "https:///nohost",
            "ftp://example.com/",
            "https://exa mple.com/",
            " https://example.com/",
            "https://example.com/\tpath",
            "https://example.com/\u{202E}gpj",
            "https://example.com/\u{200B}",
            "not a url",
        ] {
            assert!(checked_url(bad).is_err(), "{bad:?} must be refused");
        }
    }

    #[test]
    fn invisible_characters_are_refused_in_a_label_and_a_custom_id() {
        let mut b = button("ok");
        b.label = "Hit\u{202E}".into();
        assert!(validate(vec![row(vec![b])], zero_width).is_err());
        let b = button("a\u{200B}b");
        assert!(validate(vec![row(vec![b])], zero_width).is_err());
        assert!(validate(vec![row(vec![button("fine")])], zero_width).is_ok());
    }

    #[test]
    fn a_full_five_by_five_grid_passes() {
        let rows = (0..5)
            .map(|r| row((0..5).map(|c| button(&format!("b{r}{c}"))).collect()))
            .collect();
        assert!(validate(rows, no_hidden).is_ok());
    }

    #[test]
    fn a_sixth_row_or_button_is_refused() {
        let rows = (0..6)
            .map(|r| row(vec![button(&format!("r{r}"))]))
            .collect();
        assert!(validate(rows, no_hidden).is_err());
        let wide = vec![row((0..6).map(|c| button(&format!("c{c}"))).collect())];
        assert!(validate(wide, no_hidden).is_err());
    }

    #[test]
    fn duplicate_custom_ids_are_refused() {
        assert!(validate(vec![row(vec![button("a"), button("a")])], no_hidden).is_err());
    }

    #[test]
    fn a_link_needs_an_http_url_and_no_custom_id() {
        let mut link = button("x");
        link.style = ButtonStyle::Link;
        assert!(validate(vec![row(vec![link.clone()])], no_hidden).is_err());
        link.custom_id = None;
        link.url = Some("javascript:alert(1)".into());
        assert!(validate(vec![row(vec![link.clone()])], no_hidden).is_err());
        link.url = Some("https://example.com".into());
        assert!(validate(vec![row(vec![link])], no_hidden).is_ok());
    }

    #[test]
    fn a_blank_or_oversize_label_is_refused() {
        let mut b = button("a");
        b.label = "   ".into();
        assert!(validate(vec![row(vec![b.clone()])], no_hidden).is_err());
        b.label = "x".repeat(MAX_LABEL_CHARS + 1);
        assert!(validate(vec![row(vec![b])], no_hidden).is_err());
    }

    #[test]
    fn a_disabled_button_is_not_clickable() {
        let mut b = button("a");
        b.disabled = true;
        assert!(clickable(&[row(vec![b])], "a").is_none());
    }
}
