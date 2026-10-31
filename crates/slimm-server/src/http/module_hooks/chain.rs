// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The interceptor chain on a message before it is stored: reject, then
//! annotate, then rewrite, each phase ordered by the admin's priority.

use std::time::Instant;

use serde_json::{Map, Value, json};

use super::registry::Entry;
use super::runner::{Verdict, run};
use super::{CHAIN_CAP, short};
use crate::http::AppState;
use crate::http::dock::PHASES;
use crate::http::error::ApiError;
use crate::http::messages::validate_content;
use crate::ids::{ChannelId, MessageId, UserId};
use crate::module_runtime::INTERCEPTOR_CONTRACT;
use crate::store::HookDecl;

const COMMAND: &str = "@intercept";
const MAX_NOTE_KEYS: usize = 8;
const MAX_NOTE_KEY_CHARS: usize = 32;
const MAX_NOTE_VALUE_CHARS: usize = 256;

/// Where in a message's life the chain runs.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum HookPoint {
    PreSend,
    PreEdit,
}

impl HookPoint {
    fn name(self) -> &'static str {
        match self {
            HookPoint::PreSend => "message.pre_send",
            HookPoint::PreEdit => "message.pre_edit",
        }
    }
}

/// A message about to be stored, as the path that received it knows it.
pub(crate) struct Draft<'a> {
    pub(crate) point: HookPoint,
    pub(crate) channel_id: ChannelId,
    pub(crate) actor: UserId,
    pub(crate) reply_to: Option<MessageId>,
    pub(crate) content: &'a str,
    /// Whether the message may have no text (attachments or a forward carry it).
    pub(crate) carries_more: bool,
    /// A module that posts is not filtered by its own interceptors.
    pub(crate) own_module: Option<&'a str>,
}

/// What the chain decided; `content` is `Some` only when a rewrite changed it.
#[derive(Default)]
pub(crate) struct Intercepted {
    pub(crate) content: Option<String>,
    pub(crate) annotations: Vec<(String, Map<String, Value>)>,
}

impl Intercepted {
    /// The text to store: the rewrite if there was one, else the sender's own.
    pub(crate) fn text<'a>(&'a self, original: &'a str) -> &'a str {
        self.content.as_deref().unwrap_or(original)
    }

    /// Stores what modules annotated the message with; a failure is logged, never the sender's.
    pub(crate) async fn save_annotations(&self, state: &AppState, message: MessageId) {
        for (module_id, notes) in &self.annotations {
            let data = Value::Object(notes.clone()).to_string();
            if let Err(err) = state
                .store
                .save_message_annotations(message, module_id, &data)
                .await
            {
                tracing::warn!(%err, module = %module_id, "could not store a message annotation");
            }
        }
    }
}

/// Runs the chain for `draft`. An error refuses the message and says why.
pub(crate) async fn intercept(
    state: &AppState,
    draft: &Draft<'_>,
) -> Result<Intercepted, ApiError> {
    let Some(snapshot) = state.dock.hooks().active(&state.store).await else {
        return Ok(Intercepted::default());
    };
    let started = Instant::now();
    let is_bot = reads_bot(&snapshot.interceptors, draft.point)
        && state.store.is_bot(draft.actor).await.unwrap_or(false);
    let mut out = Intercepted::default();
    let mut text = draft.content.to_owned();
    for phase in PHASES {
        let stage = snapshot
            .interceptors
            .iter()
            .filter(|e| e.decl.hook == draft.point.name() && e.decl.phase == phase)
            .filter(|e| draft.own_module != Some(e.module.id.as_str()));
        for entry in stage {
            let sent = input((draft, is_bot), &entry.decl, &text, &out.annotations);
            let remaining = CHAIN_CAP.saturating_sub(started.elapsed());
            let verdict = run(state, entry, (COMMAND, draft.actor, &sent), remaining).await;
            let step = verdict_step(verdict, phase, draft.carries_more);
            match step {
                Ok(Step::Allow) => {}
                Ok(Step::Reject(reason)) => return Err(rejection(entry, &reason)),
                Ok(Step::Notes(notes)) => out.annotations.push((entry.module.id.clone(), notes)),
                Ok(Step::Rewrite(new)) => {
                    text = new;
                    out.content = Some(text.clone());
                }
                Err(why) => {
                    tracing::info!(module = %entry.module.id, hook = draft.point.name(), %why, "interceptor failed");
                    if entry.fail_closed {
                        return Err(ApiError::ForbiddenDetail(format!(
                            "{} could not check this message, so it was not sent",
                            entry.module.name
                        )));
                    }
                }
            }
        }
    }
    Ok(out)
}

/// Whether any interceptor at `point` asks to be told if the sender is a bot.
fn reads_bot(entries: &[Entry], point: HookPoint) -> bool {
    entries
        .iter()
        .any(|e| e.decl.hook == point.name() && e.decl.reads.iter().any(|r| r == "is_bot"))
}

fn rejection(entry: &Entry, reason: &str) -> ApiError {
    ApiError::ForbiddenDetail(format!(
        "{} blocked this message: {reason}",
        entry.module.name
    ))
}

/// What one module's reply asks the chain to do.
enum Step {
    Allow,
    Reject(String),
    Notes(Map<String, Value>),
    Rewrite(String),
}

fn verdict_step(verdict: Verdict, phase: &str, carries_more: bool) -> Result<Step, String> {
    match verdict {
        Verdict::Unavailable => Err("no time left to run it".into()),
        Verdict::Failed(why) => Err(why),
        Verdict::Reply(reply) => {
            let value: Value = serde_json::from_str(&reply).map_err(|_| "reply is not JSON")?;
            match phase {
                "reject" => reject_step(&value),
                "annotate" => notes_step(&value),
                _ => rewrite_step(&value, carries_more),
            }
        }
    }
}

fn reject_step(reply: &Value) -> Result<Step, String> {
    match reply.get("action").and_then(Value::as_str) {
        Some("allow") => Ok(Step::Allow),
        Some("reject") => {
            let reason = reply.get("reason").and_then(Value::as_str).unwrap_or("");
            Ok(Step::Reject(short(reason)))
        }
        _ => Err("reply has no action of allow or reject".into()),
    }
}

fn notes_step(reply: &Value) -> Result<Step, String> {
    let Some(notes) = reply.get("annotations").and_then(Value::as_object) else {
        return Err("reply has no annotations object".into());
    };
    if notes.len() > MAX_NOTE_KEYS {
        return Err("too many annotations".into());
    }
    let fits = notes.iter().all(|(k, v)| {
        k.chars().count() <= MAX_NOTE_KEY_CHARS
            && v.as_str()
                .is_some_and(|s| s.chars().count() <= MAX_NOTE_VALUE_CHARS)
    });
    if !fits {
        return Err("an annotation is not short text".into());
    }
    Ok(Step::Notes(notes.clone()))
}

fn rewrite_step(reply: &Value, carries_more: bool) -> Result<Step, String> {
    let Some(content) = reply.get("content") else {
        return Ok(Step::Allow);
    };
    let Some(content) = content.as_str() else {
        return Err("content is not text".into());
    };
    validate_content(content, carries_more).map_err(|_| "rewritten text is not allowed")?;
    if crate::http::module_host::hides_text(content) {
        return Err("rewritten text hides characters".into());
    }
    Ok(Step::Rewrite(content.to_owned()))
}

/// What the module is sent: only the fields its manifest declared.
fn input(
    (draft, is_bot): (&Draft<'_>, bool),
    decl: &HookDecl,
    text: &str,
    notes: &[(String, Map<String, Value>)],
) -> String {
    let mut message = Map::new();
    for field in &decl.reads {
        let value = match field.as_str() {
            "content" => json!(text),
            "channel_id" => json!(draft.channel_id.to_string()),
            "is_bot" => json!(is_bot),
            "reply_to_id" => json!(draft.reply_to.map(|id| id.to_string())),
            "annotations" => Value::Object(
                notes
                    .iter()
                    .map(|(module, n)| (module.clone(), Value::Object(n.clone())))
                    .collect(),
            ),
            _ => continue,
        };
        message.insert(field.clone(), value);
    }
    json!({
        "$slim": format!("interceptor/{INTERCEPTOR_CONTRACT}"),
        "hook": draft.point.name(),
        "phase": decl.phase,
        "message": message,
    })
    .to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::HookKind;

    fn draft() -> Draft<'static> {
        Draft {
            point: HookPoint::PreSend,
            channel_id: ChannelId::generate(),
            actor: UserId::generate(),
            reply_to: None,
            content: "the original",
            carries_more: false,
            own_module: None,
        }
    }

    fn decl(reads: &[&str]) -> HookDecl {
        HookDecl {
            kind: HookKind::Interceptor,
            hook: "message.pre_send".into(),
            phase: "reject".into(),
            reads: reads.iter().map(ToString::to_string).collect(),
        }
    }

    fn sent(reads: &[&str]) -> Value {
        let text = input((&draft(), true), &decl(reads), "now", &[]);
        serde_json::from_str(&text).unwrap()
    }

    #[test]
    fn a_module_is_sent_only_the_fields_it_declared() {
        let all = sent(&["content", "is_bot"]);
        assert_eq!(all["message"]["content"], json!("now"));
        assert_eq!(all["message"]["is_bot"], json!(true));
        assert!(all["message"].get("channel_id").is_none());
        let none = sent(&[]);
        assert_eq!(none["message"], json!({}));
        assert_eq!(none["$slim"], json!("interceptor/1"));
    }

    #[test]
    fn replies_are_read_by_the_phase_that_asked() {
        let ok = |text: &str| Verdict::Reply(text.into());
        assert!(matches!(
            verdict_step(ok(r#"{"action":"allow"}"#), "reject", false),
            Ok(Step::Allow)
        ));
        assert!(matches!(
            verdict_step(ok(r#"{"action":"reject","reason":"no"}"#), "reject", false),
            Ok(Step::Reject(reason)) if reason == "no"
        ));
        assert!(verdict_step(ok(r#"{"action":"maybe"}"#), "reject", false).is_err());
        assert!(verdict_step(ok("not json"), "reject", false).is_err());
        assert!(verdict_step(ok(r#"{"annotations":{"k":1}}"#), "annotate", false).is_err());
        assert!(verdict_step(ok(r#"{"content":""}"#), "rewrite", false).is_err());
        assert!(verdict_step(ok(r#"{"content":""}"#), "rewrite", true).is_ok());
        assert!(verdict_step(Verdict::Unavailable, "reject", false).is_err());
    }
}
