// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Running a fenced code block in a message so the result is shared: unlike
//! `POST /modules/{moduleId}/commands/{command}`, which answers only the
//! caller, this stores the result against the block and broadcasts it, so
//! everyone viewing the message sees the latest run inline without rerunning
//! it (a long job runs once for all).
//!
//! It reuses the exact module gating and execution of `module_commands`
//! (`execute_command`); the only thing added here is the message-scoped
//! authorization (mirroring `reactions.rs`: VIEW_CHANNEL, masked as 404) and
//! the store-plus-broadcast that makes the output shared. slim still has no
//! notion of what any command does.
//!
//! `req.module_id == CODE_RUNNER_MODULE_ID` is the one exception, handled the
//! same way the generic run route does: `execute_code_runner` in place of
//! `execute_command`, gated on `RUN_CODE` evaluated with the exact
//! `permissions` this route already resolved for its own `VIEW_CHANNEL`
//! check - so unlike the module-permission path, a code-runner invocation
//! here is channel-scoped and can be overwritten per channel.
//!
//! `execute_command`'s gate is "does the caller hold a permission for the
//! module they named", not "is the module they named the one this message
//! actually launched". A message that carries an `app_surfaces` row owns its
//! entire code-run surface - `record_code_run` overwrites the same row
//! regardless of which block a request names, and `app_surfaces` has no
//! `block_index` of its own - so before ever reaching `execute_command` or
//! `execute_code_runner`, this route checks the request's `module_id` and
//! `command` against that row when one exists and refuses a mismatch. The
//! refusal is `Forbidden`, not the probe-defense `NotFound` above: that mask
//! exists to hide whether a message a caller cannot even view exists at all,
//! but a caller reaching this check has already cleared `VIEW_CHANNEL` and
//! the surface's `module_id`/`command` are already visible to them on the
//! message DTO, so there is nothing left to hide - this is an ordinary
//! authorization refusal.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::routing::post;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::code_fences::code_block;
use super::error::ApiError;
use super::extract::{AuthedLimited, Json, MODULE};
use super::hidden_chars::is_hidden_char;
use super::messages::parse_uuid;
use super::module_commands::{
    CODE_RUNNER_MODULE_ID, CommandOutcome, execute_code_runner, execute_command,
};
use crate::hub::Event;
use crate::ids::MessageId;
use crate::permissions::Permissions;
use crate::store::{MAX_SHARED_OUTPUT_BYTES, clamp_output};

/// A code block's input is a whole snippet, so this matches the run route's
/// own generous cap rather than the small write bodies elsewhere.
const BODY_LIMIT: usize = 256 * 1024;

/// A message cannot hold anything like this many fenced blocks; the bound just
/// keeps a caller from writing rows at arbitrary indices.
const MAX_BLOCK_INDEX: i64 = 1000;

const HIDDEN_CHARACTERS_REFUSAL: &str =
    "this block contains hidden text-direction or zero-width characters, so it will not run";

/// True when [`text`] carries a control, text-direction or zero-width
/// character that changes what a reader sees without changing what runs
/// (trojan source, CVE-2021-42574). Tab and line breaks are ordinary code.
fn has_hidden_characters(text: &str) -> bool {
    text.chars()
        .any(|c| !matches!(c, '\t' | '\n' | '\r') && is_hidden_char(c))
}

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/messages/{message_id}/blocks/{block_index}/run", post(run))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Deserialize)]
struct RunRequest {
    module_id: String,
    command: String,
    input: String,
}

/// The same `{ok, output}` / `{ok, error}` shape the generic run route answers
/// with; the run is also stored and broadcast so other viewers get it too.
#[derive(Serialize)]
struct RunResponse {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    output: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

async fn run(
    AuthedLimited(ctx): AuthedLimited<MODULE>,
    State(state): State<AppState>,
    Path((message_id, block_index)): Path<(String, i64)>,
    Json(req): Json<RunRequest>,
) -> Result<Json<RunResponse>, ApiError> {
    if !(0..=MAX_BLOCK_INDEX).contains(&block_index) {
        return Err(ApiError::BadRequest("invalid block index"));
    }
    let message_id = MessageId(parse_uuid(&message_id)?);

    // See it before running in it, answering a hidden message as a missing one - the probe defense reactions.rs uses.
    let Some(message) = state.store.message(message_id).await? else {
        return Err(ApiError::NotFound("no such message"));
    };
    let permissions = state
        .store
        .permissions_in_channel(ctx.user_id, message.channel_id)
        .await?;
    if !permissions.contains(Permissions::VIEW_CHANNEL) {
        return Err(ApiError::NotFound("no such message"));
    }
    // The run is stored and shown to the whole channel, so a timeout bars it like a message.
    if state.store.timed_out_until(ctx.user_id).await?.is_some() {
        return Err(ApiError::Forbidden);
    }

    // An app surface owns its whole code-run surface; see this file's doc comment.
    let surface = state.store.app_surface_for_message(message_id).await?;
    if let Some(surface) = &surface
        && (surface.module_id != req.module_id || surface.command != req.command)
    {
        return Err(ApiError::Forbidden);
    }

    // A surface's input is the module's own; a plain message runs only its own stored block, never the caller's claim of it.
    let code = match surface {
        Some(_) => req.input.clone(),
        None => usize::try_from(block_index)
            .ok()
            .and_then(|index| code_block(&message.content, index))
            .ok_or(ApiError::Conflict(
                "this message has no code block at that index",
            ))?,
    };
    if has_hidden_characters(&code) {
        return Err(ApiError::ForbiddenBecause(HIDDEN_CHARACTERS_REFUSAL));
    }

    // Gating happens inside execute_command / execute_code_runner below.
    let outcome = if req.module_id == CODE_RUNNER_MODULE_ID {
        execute_code_runner(&state, permissions, ctx.user_id, &req.command, &code).await?
    } else {
        execute_command(&state, ctx.user_id, &req.module_id, &req.command, &code).await?
    };
    let (ok, stored) = stored_payload(req.module_id == CODE_RUNNER_MODULE_ID, outcome);
    let ran_at = state
        .store
        .record_code_run(
            message_id,
            block_index,
            &req.module_id,
            &req.command,
            ok,
            &stored,
            ctx.user_id,
        )
        .await?;

    state.hub.publish(Event::CodeRunChanged {
        channel_id: message.channel_id,
        message_id,
        block_index,
        module_id: req.module_id,
        command: req.command,
        ok,
        output: stored.clone(),
        ran_by: Some(ctx.user_id),
        ran_at,
    });

    let response = if ok {
        RunResponse {
            ok: true,
            output: Some(stored),
            error: None,
        }
    } else {
        RunResponse {
            ok: false,
            output: None,
            error: Some(stored),
        }
    };
    Ok(Json(response))
}

/// Text may be byte-clamped; a scene is JSON, and a cut scene is garbage the
/// client cannot parse, so an over-ceiling scene is refused whole instead.
fn stored_payload(is_text: bool, outcome: CommandOutcome) -> (bool, String) {
    if is_text {
        return (outcome.ok, clamp_output(&outcome.payload));
    }
    if outcome.payload.len() > MAX_SHARED_OUTPUT_BYTES {
        let message = format!(
            "scene refused: {} bytes is over the {} byte ceiling",
            outcome.payload.len(),
            MAX_SHARED_OUTPUT_BYTES
        );
        return (false, message);
    }
    (
        outcome.ok,
        super::scene_limits::clamp_sweeps(&outcome.payload),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hidden_characters_are_told_apart_from_ordinary_code() {
        assert!(has_hidden_characters("a\u{202E}b"));
        assert!(has_hidden_characters("a\u{200B}b"));
        assert!(has_hidden_characters("a\u{061C}b"));
        assert!(has_hidden_characters("a\u{0}b"));
        assert!(!has_hidden_characters("if (x) {\r\n\tf(\"caf\u{e9}\");\n}"));
    }

    fn outcome(payload: String) -> CommandOutcome {
        CommandOutcome { ok: true, payload }
    }

    #[test]
    fn text_over_the_ceiling_is_clamped_and_stays_ok() {
        let (ok, stored) = stored_payload(true, outcome("x".repeat(MAX_SHARED_OUTPUT_BYTES + 10)));
        assert!(ok);
        assert!(stored.ends_with("(output truncated)"));
    }

    #[test]
    fn a_scene_over_the_ceiling_is_refused_not_cut() {
        let big = format!("{{\"ops\":\"{}\"}}", "a".repeat(MAX_SHARED_OUTPUT_BYTES));
        let (ok, stored) = stored_payload(false, outcome(big));
        assert!(!ok);
        assert!(stored.starts_with("scene refused"));
    }

    #[test]
    fn a_scene_under_the_ceiling_is_stored_untouched() {
        let (ok, stored) = stored_payload(false, outcome("{\"ops\":[]}".into()));
        assert!(ok);
        assert_eq!(stored, "{\"ops\":[]}");
    }
}
