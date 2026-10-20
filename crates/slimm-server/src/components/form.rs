// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A small form a bot opens for the member who pressed its button or chose
//! from its menu. See docs/decisions/0083-bot-token-reissue-select-menus-and-forms.md.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

pub const MAX_FIELDS: usize = 5;
pub const MAX_TITLE_CHARS: usize = 80;
pub const MAX_LABEL_CHARS: usize = 80;
pub const MAX_PLACEHOLDER_CHARS: usize = 100;
/// The longest a field may be allowed to run; a form is for a few words.
pub const MAX_FIELD_CHARS: usize = 1000;
const DEFAULT_FIELD_CHARS: usize = 200;

fn yes() -> bool {
    true
}

fn default_max_length() -> usize {
    DEFAULT_FIELD_CHARS
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FormField {
    pub custom_id: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub placeholder: Option<String>,
    /// Prefilled text the member may change.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub value: Option<String>,
    #[serde(default = "yes")]
    pub required: bool,
    #[serde(default)]
    pub multiline: bool,
    #[serde(default = "default_max_length")]
    pub max_length: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Form {
    /// Names the submission to the bot, like a button's `custom_id`.
    pub custom_id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub submit_label: Option<String>,
    pub fields: Vec<FormField>,
}

fn visible_text(
    text: &mut String,
    limit: usize,
    hidden: fn(char) -> bool,
    what: &'static str,
) -> Result<(), &'static str> {
    *text = text.trim().to_owned();
    if text.is_empty() || text.chars().count() > limit || text.chars().any(hidden) {
        return Err(what);
    }
    Ok(())
}

/// Checks a form against the caps and trims its text.
pub fn validate(form: &mut Form, hidden: fn(char) -> bool) -> Result<(), &'static str> {
    super::check_custom_id(&form.custom_id, hidden)?;
    visible_text(
        &mut form.title,
        MAX_TITLE_CHARS,
        hidden,
        "a form title must be 1 to 80 visible characters",
    )?;
    if let Some(label) = form.submit_label.as_mut() {
        visible_text(
            label,
            MAX_LABEL_CHARS,
            hidden,
            "a submit label must be 1 to 80 visible characters",
        )?;
    }
    if form.fields.is_empty() || form.fields.len() > MAX_FIELDS {
        return Err("a form needs 1 to 5 fields");
    }
    let mut seen = std::collections::HashSet::new();
    for field in &mut form.fields {
        validate_field(field, hidden)?;
        if !seen.insert(field.custom_id.clone()) {
            return Err("field custom_id must be unique within a form");
        }
    }
    Ok(())
}

fn validate_field(field: &mut FormField, hidden: fn(char) -> bool) -> Result<(), &'static str> {
    super::check_custom_id(&field.custom_id, hidden)?;
    visible_text(
        &mut field.label,
        MAX_LABEL_CHARS,
        hidden,
        "a field label must be 1 to 80 visible characters",
    )?;
    if field.max_length == 0 || field.max_length > MAX_FIELD_CHARS {
        return Err("a field max_length must be 1 to 1000");
    }
    if let Some(text) = field.placeholder.as_mut() {
        *text = text.trim().to_owned();
        if text.chars().count() > MAX_PLACEHOLDER_CHARS || text.chars().any(hidden) {
            return Err("a field placeholder must be at most 100 visible characters");
        }
    }
    if let Some(text) = &field.value
        && !field.accepts(text, hidden)
    {
        return Err("a field's prefilled value does not fit the field");
    }
    Ok(())
}

impl FormField {
    fn accepts(&self, text: &str, hidden: fn(char) -> bool) -> bool {
        let visible = |c: char| !(self.multiline && c == '\n') && hidden(c);
        text.chars().count() <= self.max_length && !text.chars().any(visible)
    }
}

impl Form {
    /// The member's answers as the bot receives them: every field present,
    /// an unanswered optional one as empty text. `Err` is the wire-facing text.
    pub fn check_answers(
        &self,
        mut given: BTreeMap<String, String>,
        hidden: fn(char) -> bool,
    ) -> Result<BTreeMap<String, String>, &'static str> {
        let mut answers = BTreeMap::new();
        for field in &self.fields {
            let text = given.remove(&field.custom_id).unwrap_or_default();
            let text = if field.multiline {
                text.trim_end()
            } else {
                text.trim()
            };
            if field.required && text.trim().is_empty() {
                return Err("a required field was left empty");
            }
            if !field.accepts(text, hidden) {
                return Err("a field's answer is too long or holds invisible characters");
            }
            answers.insert(field.custom_id.clone(), text.to_owned());
        }
        if !given.is_empty() {
            return Err("an answer names a field the form does not have");
        }
        Ok(answers)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn invisible(c: char) -> bool {
        c.is_control() || c == '\u{202E}'
    }

    fn form() -> Form {
        Form {
            custom_id: "survey".into(),
            title: "Remind me".into(),
            submit_label: None,
            fields: vec![
                FormField {
                    custom_id: "what".into(),
                    label: "What".into(),
                    placeholder: None,
                    value: None,
                    required: true,
                    multiline: false,
                    max_length: 10,
                },
                FormField {
                    custom_id: "note".into(),
                    label: "Note".into(),
                    placeholder: None,
                    value: None,
                    required: false,
                    multiline: true,
                    max_length: 10,
                },
            ],
        }
    }

    fn answers(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect()
    }

    #[test]
    fn answers_are_checked_against_each_field() {
        let form = form();
        for (why, given) in [
            ("blank required", answers(&[("what", "  ")])),
            ("missing required", answers(&[("note", "n")])),
            ("too long", answers(&[("what", "12345678901")])),
            ("invisible", answers(&[("what", "a\u{202E}b")])),
            ("newline in a single line", answers(&[("what", "a\nb")])),
            ("unknown field", answers(&[("what", "x"), ("zzz", "y")])),
            (
                "too long multiline",
                answers(&[("what", "x"), ("note", "12345678901")]),
            ),
        ] {
            assert!(form.check_answers(given, invisible).is_err(), "{why}");
        }
        let ok = form
            .check_answers(answers(&[("what", " tea "), ("note", "a\nb")]), invisible)
            .unwrap();
        assert_eq!(ok, answers(&[("what", "tea"), ("note", "a\nb")]));
        let sparse = form
            .check_answers(answers(&[("what", "tea")]), invisible)
            .unwrap();
        assert_eq!(
            sparse["note"], "",
            "an unanswered optional field is present and empty"
        );
    }

    #[test]
    fn a_form_is_bounded() {
        let mut f = form();
        assert!(validate(&mut f, invisible).is_ok());
        f.fields.clear();
        assert!(validate(&mut f, invisible).is_err());
        let mut f = form();
        f.fields[1].custom_id = "what".into();
        assert!(validate(&mut f, invisible).is_err(), "duplicate field id");
        let mut f = form();
        f.fields[0].max_length = MAX_FIELD_CHARS + 1;
        assert!(validate(&mut f, invisible).is_err());
        let mut f = form();
        f.fields[0].value = Some("x".repeat(11));
        assert!(
            validate(&mut f, invisible).is_err(),
            "prefill past max_length"
        );
        let mut f = form();
        f.title = "t\u{202E}".into();
        assert!(validate(&mut f, invisible).is_err());
        let mut f = form();
        f.fields = (0..=MAX_FIELDS)
            .map(|n| FormField {
                custom_id: format!("f{n}"),
                ..form().fields[0].clone()
            })
            .collect();
        assert!(validate(&mut f, invisible).is_err(), "six fields");
    }
}
