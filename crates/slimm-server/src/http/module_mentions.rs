// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `{{mention:<caller id>}}` in a module's `message.post` content: the host turns it into a
//! real `@username` for the member that id stands for, so the ordinary mention rules apply.
//!
//! A caller id is an HMAC only this deployment can compute, so a module can name only members
//! it was handed as a caller. Anything else stays the literal text it wrote.

use std::collections::HashMap;

use super::AppState;
use super::module_caller::{caller_name, module_caller_id};
use crate::ids::{ChannelId, UserId};

/// Most tokens one message may turn into mentions; later ones stay literal.
pub(super) const MAX_TOKEN_MENTIONS: usize = 10;

const OPEN: &str = "{{mention:";
const CLOSE: &str = "}}";
/// A caller id is a SHA-256 HMAC as hex.
const ID_LEN: usize = 64;

/// `content` with each usable token written as `@username`.
pub(super) async fn expand(
    state: &AppState,
    module_id: &str,
    channel: ChannelId,
    content: &str,
) -> String {
    let tokens = find_tokens(content);
    if tokens.is_empty() {
        return content.to_owned();
    }
    let shown = match resolve(state, module_id, channel, &tokens).await {
        Ok(shown) => shown,
        Err(err) => {
            tracing::warn!(%err, "module post: could not expand mentions");
            return content.to_owned();
        }
    };
    splice(content, &tokens, &shown)
}

struct Token<'a> {
    start: usize,
    end: usize,
    id: &'a str,
}

fn find_tokens(content: &str) -> Vec<Token<'_>> {
    let mut tokens = Vec::new();
    let mut from = 0;
    while let Some(found) = content[from..].find(OPEN) {
        let start = from + found;
        let id_start = start + OPEN.len();
        let id_end = id_start + ID_LEN;
        let closed = content.get(id_end..id_end + CLOSE.len()) == Some(CLOSE);
        match content.get(id_start..id_end) {
            Some(id) if closed && id.bytes().all(|b| b.is_ascii_hexdigit()) => {
                tokens.push(Token {
                    start,
                    end: id_end + CLOSE.len(),
                    id,
                });
                from = id_end + CLOSE.len();
            }
            _ => from = id_start,
        }
    }
    tokens
}

/// How each token's id is to be written, for the ids that belong to a member who can see `channel`.
async fn resolve(
    state: &AppState,
    module_id: &str,
    channel: ChannelId,
    tokens: &[Token<'_>],
) -> anyhow::Result<HashMap<String, String>> {
    let key = state.store.module_caller_key().await?;
    let wanted: Vec<String> = tokens
        .iter()
        .take(MAX_TOKEN_MENTIONS)
        .map(|t| t.id.to_ascii_lowercase())
        .collect();
    let named: Vec<UserId> = state
        .store
        .all_live_user_ids()
        .await?
        .into_iter()
        .filter(|user| wanted.contains(&module_caller_id(&key, module_id, *user)))
        .collect();
    let viewers = state.store.viewers_among(channel, &named).await?;
    let profiles = state.store.user_profiles(&viewers).await?;
    let mut shown = HashMap::new();
    for profile in profiles {
        let id = module_caller_id(&key, module_id, profile.id);
        let text = if mentionable(&profile.username) {
            format!("@{}", profile.username)
        } else {
            caller_name(&state.store, profile.id)
                .await
                .unwrap_or(profile.username)
        };
        shown.insert(id, text);
    }
    Ok(shown)
}

/// The mention grammar drops a trailing `.` or `-`, so such a username cannot be written as one.
fn mentionable(username: &str) -> bool {
    !username.ends_with(['.', '-'])
}

fn splice(content: &str, tokens: &[Token<'_>], shown: &HashMap<String, String>) -> String {
    let mut out = String::with_capacity(content.len());
    let mut copied = 0;
    for (index, token) in tokens.iter().enumerate() {
        let Some(text) = (index < MAX_TOKEN_MENTIONS)
            .then(|| shown.get(&token.id.to_ascii_lowercase()))
            .flatten()
        else {
            continue;
        };
        out.push_str(&content[copied..token.start]);
        out.push_str(text);
        if runs_on(&content[token.end..]) {
            out.push(' ');
        }
        copied = token.end;
    }
    out.push_str(&content[copied..]);
    out
}

/// Whether the text after a mention would read as part of the username.
fn runs_on(rest: &str) -> bool {
    let mut chars = rest.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphanumeric() || c == '_' => true,
        Some('.' | '-') => chars
            .next()
            .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_'),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(c: char) -> String {
        c.to_string().repeat(ID_LEN)
    }

    #[test]
    fn only_well_formed_tokens_are_found() {
        let good = format!("a {{{{mention:{}}}}} b", id('a'));
        assert_eq!(find_tokens(&good).len(), 1);
        for bad in [
            "{{mention:abc}}".to_owned(),
            format!("{{{{mention:{}", id('a')),
            format!("{{{{mention:{}}}}}", id('g')),
            format!("{{{{mention:{}}}}}", "é".repeat(ID_LEN / 2)),
        ] {
            assert!(find_tokens(&bad).is_empty(), "{bad}");
        }
    }

    #[test]
    fn a_token_is_replaced_and_the_rest_stays_literal() {
        let text = format!(
            "{{{{mention:{}}}}} and {{{{mention:{}}}}}!",
            id('a'),
            id('b')
        );
        let tokens = find_tokens(&text);
        let shown = HashMap::from([(id('a'), "@ada".to_owned())]);
        assert_eq!(
            splice(&text, &tokens, &shown),
            format!("@ada and {{{{mention:{}}}}}!", id('b'))
        );
    }

    #[test]
    fn tokens_past_the_cap_stay_literal() {
        let one = format!("{{{{mention:{}}}}}", id('a'));
        let text = vec![one.clone(); MAX_TOKEN_MENTIONS + 2].join(",");
        let shown = HashMap::from([(id('a'), "@ada".to_owned())]);
        let out = splice(&text, &find_tokens(&text), &shown);
        assert_eq!(out.matches("@ada").count(), MAX_TOKEN_MENTIONS);
        assert_eq!(out.matches(&one).count(), 2);
    }

    #[test]
    fn text_that_would_join_the_name_gets_a_space() {
        let text = format!("{{{{mention:{}}}}}x {{{{mention:{}}}}}.", id('a'), id('a'));
        let shown = HashMap::from([(id('a'), "@ada".to_owned())]);
        assert_eq!(splice(&text, &find_tokens(&text), &shown), "@ada x @ada.");
    }
}
