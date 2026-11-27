// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Many `move`, `edit`, `remove` and `reorder` ops in one request, applied in one transaction.
//!
//! Each op is checked and fanned out exactly as it would be on its own, so a client needs
//! nothing new to follow a batch; the only difference is that one refusal rolls them all back.

use std::collections::HashSet;

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use serde::{Deserialize, Serialize};

use super::super::AppState;
use super::super::error::{ApiError, RefusedItem};
use super::super::extract::{AuthedLimited, CANVAS_BATCH, Json, enforce_weighted};
use super::super::messages::parse_uuid;
use super::canvas_batch::MAX_BATCH_OBJECTS;
use super::canvas_ops_write::{
    CanvasOpResultDto, SubmitOpParams, parse_request, publish_to, submit_error_api,
};
use super::canvas_write::canvas_access;
use crate::hub::Hub;
use crate::ids::{CanvasOpId, ChannelId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{CanvasOpRequest, OpBatchError, SubmitOpError, SubmittedOp};

#[derive(Deserialize)]
pub(in crate::http) struct OpBatchParams {
    ops: Vec<SubmitOpParams>,
}

#[derive(Serialize)]
pub(in crate::http) struct OpBatchDto {
    ops: Vec<CanvasOpResultDto>,
}

/// `POST /channels/{channel_id}/canvas/ops/batch`.
///
/// Charged [`Class::CanvasBatch`] by op count. Each op's `id` is its idempotency key, so a
/// retried batch answers with the stored ops and publishes nothing for them.
pub(in crate::http) async fn submit_op_batch(
    AuthedLimited(ctx): AuthedLimited<CANVAS_BATCH>,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(params): Json<OpBatchParams>,
) -> Result<(StatusCode, Json<OpBatchDto>), ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let count = params.ops.len();
    if count == 0 || count > MAX_BATCH_OBJECTS {
        return Err(ApiError::BadRequest("a batch holds 1 to 200 ops"));
    }
    // The extractor charged the first op before the body; the rest of the count follows.
    if count > 1 {
        enforce_weighted(&state, &parts, &ctx, Class::CanvasBatch, (count - 1) as f64)?;
    }
    let permissions = canvas_access(&state, ctx.user_id, channel_id).await?;
    let may_moderate = permissions.contains(Permissions::MANAGE_CANVAS);

    let ops = parse_ops(params.ops)?;
    // Only `remove` stays open under a timeout; see `canvas_ops_write`'s module doc.
    let pen_ops = ops
        .iter()
        .any(|(_, request)| !matches!(request, CanvasOpRequest::Remove(_)));
    if pen_ops && state.store.timed_out_until(ctx.user_id).await?.is_some() {
        return Err(ApiError::Forbidden);
    }

    let outcomes = state
        .store
        .submit_canvas_ops(channel_id, ctx.user_id, may_moderate, ops)
        .await
        .map_err(refused)?;

    // No await between the commit and this call; see `ws::permission_cache`.
    let fresh: Vec<_> = outcomes
        .iter()
        .filter(|outcome| outcome.fresh && outcome.affected > 0)
        .cloned()
        .collect();
    publish_paced(state.hub.clone(), channel_id, fresh);

    Ok((
        StatusCode::CREATED,
        Json(OpBatchDto {
            ops: outcomes.into_iter().map(CanvasOpResultDto::from).collect(),
        }),
    ))
}

/// Validates every op before the store is touched, so a malformed one names its index at once.
fn parse_ops(params: Vec<SubmitOpParams>) -> Result<Vec<(CanvasOpId, CanvasOpRequest)>, ApiError> {
    let mut seen = HashSet::with_capacity(params.len());
    let mut ops = Vec::with_capacity(params.len());
    for (index, op) in params.into_iter().enumerate() {
        let op_id = CanvasOpId(parse_uuid(op.id())?);
        if !seen.insert(op_id) {
            return Err(at_item(
                index,
                StatusCode::BAD_REQUEST,
                "repeated_id",
                "repeats an id in this batch",
            ));
        }
        if !matches!(op.kind(), "move" | "edit" | "remove" | "reorder") {
            return Err(at_item(
                index,
                StatusCode::BAD_REQUEST,
                "unsupported_kind",
                "a batch takes only move, edit, remove and reorder",
            ));
        }
        let request = parse_request(op).map_err(|error| match error {
            ApiError::BadRequest(message) => {
                at_item(index, StatusCode::BAD_REQUEST, "invalid", message)
            }
            other => other,
        })?;
        ops.push((op_id, request));
    }
    Ok(ops)
}

fn refused(OpBatchError { index, error }: OpBatchError) -> ApiError {
    let code = match &error {
        SubmitOpError::NotFound => "not_found",
        SubmitOpError::NotAuthorized => "forbidden",
        SubmitOpError::ChannelFull => "channel_full",
        SubmitOpError::OutOfBounds => "out_of_bounds",
        SubmitOpError::NotEditable => "not_editable",
        SubmitOpError::BadProps(_) => "invalid",
        SubmitOpError::Locked => "locked",
        SubmitOpError::EdgeLimit => "edge_limit",
        SubmitOpError::Internal(_) => return submit_error_api(error),
    };
    let (status, message) = match submit_error_api(error) {
        ApiError::NotFound(message) => (StatusCode::NOT_FOUND, message),
        ApiError::Forbidden => (StatusCode::FORBIDDEN, "insufficient permissions"),
        ApiError::BadRequest(message) => (StatusCode::BAD_REQUEST, message),
        ApiError::Conflict(message) => (StatusCode::CONFLICT, message),
        other => return other,
    };
    at_item(index, status, code, message)
}

fn at_item(index: usize, status: StatusCode, code: &'static str, message: &str) -> ApiError {
    let error = format!("op {index}: {message}");
    ApiError::AtItem {
        status,
        message: error.clone(),
        index,
        code,
        items: vec![RefusedItem { index, code, error }],
    }
}

/// Fans the ops out at once while subscribers keep up, and hands the rest to a detached paced
/// task once one falls behind, so a max-size batch cannot push a subscriber past the channel capacity.
fn publish_paced(hub: Hub, channel_id: ChannelId, ops: Vec<SubmittedOp>) {
    let mut ops = ops.into_iter();
    while !hub.publish_backlogged() {
        let Some(outcome) = ops.next() else {
            return;
        };
        publish_to(&hub, channel_id, outcome.id, &outcome);
    }
    tokio::spawn(async move {
        let mut paced = true;
        for outcome in ops {
            paced = paced && hub.wait_for_publish_headroom().await;
            publish_to(&hub, channel_id, outcome.id, &outcome);
        }
    });
}
