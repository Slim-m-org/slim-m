// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The deny-only permission hook. Callers run it after the core check has
//! allowed the action, so a module can turn an allow into a deny and nothing
//! else: a refused action never reaches it.

use std::time::Instant;

use serde_json::{Value, json};

use super::runner::{Verdict, run};
use super::{CHAIN_CAP, short};
use crate::http::AppState;
use crate::http::error::ApiError;
use crate::ids::{ChannelId, UserId};
use crate::module_runtime::PERMISSION_HOOK_CONTRACT;

const COMMAND: &str = "@allow";

/// The actions a module may stand in front of.
#[derive(Clone, Copy)]
pub(crate) enum Action {
    MessageSend,
    AttachmentUpload,
    ReactionAdd,
    VoiceJoin,
}

impl Action {
    fn name(self) -> &'static str {
        match self {
            Action::MessageSend => "message.send",
            Action::AttachmentUpload => "attachment.upload",
            Action::ReactionAdd => "reaction.add",
            Action::VoiceJoin => "voice.join",
        }
    }
}

/// Asks every module hooked on `action` whether `member` may go ahead. Call it
/// only once the core permission check has said yes.
pub(crate) async fn check_permission(
    state: &AppState,
    member: UserId,
    (action, channel): (Action, Option<ChannelId>),
) -> Result<(), ApiError> {
    let Some(snapshot) = state.dock.hooks().active(&state.store).await else {
        return Ok(());
    };
    let started = Instant::now();
    let hooked = || {
        snapshot
            .permissions
            .iter()
            .filter(|e| e.decl.hook == action.name())
    };
    let joined = match hooked().any(|e| e.decl.reads.iter().any(|r| r == "member_joined_ms")) {
        true => member_joined_ms(state, member).await,
        false => None,
    };
    for entry in hooked() {
        let sent = input(action, channel, joined, &entry.decl.reads);
        let remaining = CHAIN_CAP.saturating_sub(started.elapsed());
        let verdict = run(state, entry, (COMMAND, member, &sent), remaining).await;
        match denial(verdict) {
            Ok(None) => {}
            Ok(Some(reason)) => {
                return Err(ApiError::ForbiddenDetail(format!(
                    "{} does not allow this: {reason}",
                    entry.module.name
                )));
            }
            Err(why) => {
                tracing::info!(module = %entry.module.id, action = action.name(), %why, "permission hook failed");
                if entry.fail_closed {
                    return Err(ApiError::ForbiddenDetail(format!(
                        "{} could not check this, so it was not allowed",
                        entry.module.name
                    )));
                }
            }
        }
    }
    Ok(())
}

/// A well-formed deny is the only answer that changes anything.
fn denial(verdict: Verdict) -> Result<Option<String>, String> {
    let reply = match verdict {
        Verdict::Unavailable => return Err("no time left to run it".into()),
        Verdict::Failed(why) => return Err(why),
        Verdict::Reply(reply) => reply,
    };
    let value: Value = serde_json::from_str(&reply).map_err(|_| "reply is not JSON")?;
    match value.get("allow").and_then(Value::as_bool) {
        Some(true) => Ok(None),
        Some(false) => {
            let reason = value.get("reason").and_then(Value::as_str).unwrap_or("");
            Ok(Some(short(reason)))
        }
        None => Err("reply has no allow".into()),
    }
}

async fn member_joined_ms(state: &AppState, member: UserId) -> Option<i64> {
    let profile = state.store.user_profile(member).await.ok().flatten()?;
    Some(profile.created_at)
}

fn input(
    action: Action,
    channel: Option<ChannelId>,
    joined: Option<i64>,
    reads: &[String],
) -> String {
    let mut body = json!({
        "$slim": format!("permission/{PERMISSION_HOOK_CONTRACT}"),
        "action": action.name(),
        "channel_id": channel.map(|c| c.to_string()),
    });
    if reads.iter().any(|r| r == "member_joined_ms") {
        body["member_joined_ms"] = json!(joined);
    }
    body.to_string()
}
