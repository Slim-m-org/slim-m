// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The one check every route runs before it stores words under someone's
//! name: the deny-only message.send hook, then the interceptor chain over the
//! message's text and every other piece of free text it carries.

use std::collections::HashMap;

use super::chain::{Draft, Intercepted, Pass, Target};
use super::permission::{Action, check_permission};
use crate::http::AppState;
use crate::http::error::ApiError;

/// Free text a message stores besides its content: a caption, poll text, embed text or a label.
pub(crate) struct Field<'f> {
    text: &'f mut String,
    max_chars: usize,
}

impl<'f> Field<'f> {
    /// `text`, which a rewrite may replace with at most `max_chars` characters.
    pub(crate) fn new(text: &'f mut String, max_chars: usize) -> Self {
        Self { text, max_chars }
    }
}

/// Refuses the write when a module denies `draft.actor` sending in its channel, then runs the
/// chain over `draft.content` and each of `fields`, rewriting the fields in place.
pub(crate) async fn guard_write(
    state: &AppState,
    draft: &Draft<'_>,
    fields: &mut [Field<'_>],
) -> Result<Intercepted, ApiError> {
    check_permission(
        state,
        draft.actor,
        (Action::MessageSend, Some(draft.channel_id)),
    )
    .await?;
    let Some(pass) = Pass::open(state, draft).await else {
        return Ok(Intercepted::default());
    };
    let out = match draft.content {
        Some(content) => {
            let carries_more = draft.carries_more;
            pass.run(content, Target::Content { carries_more }).await?
        }
        None => Intercepted::default(),
    };
    // A label repeated across buttons or embeds is one question for the modules.
    let mut answered: HashMap<(String, usize), Option<String>> = HashMap::new();
    for field in fields.iter_mut().filter(|f| !f.text.trim().is_empty()) {
        let key = (field.text.clone(), field.max_chars);
        let rewrite = match answered.get(&key) {
            Some(known) => known.clone(),
            None => {
                let target = Target::Field {
                    max_chars: field.max_chars,
                };
                let fresh = pass.run(field.text, target).await?.content;
                answered.insert(key, fresh.clone());
                fresh
            }
        };
        if let Some(text) = rewrite {
            *field.text = text;
        }
    }
    Ok(out)
}
