// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Placing up to [`MAX_BATCH_OBJECTS`] objects in one request, for bots that draw many.
//!
//! Every object passes the checks a single place does, the whole batch lands in one
//! transaction or not at all, and each placed object fans out as the same
//! `ObjectPlaced` event, so a client needs nothing new to draw it.

use std::collections::HashSet;
use std::sync::Arc;

use axum::extract::{Path, State};
use axum::http::request::Parts;
use serde::{Deserialize, Serialize};

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{Authed, Json, enforce, enforce_weighted};
use super::super::messages::parse_uuid;
use super::CanvasObjectDto;
use super::canvas_write::{PlaceParams, ensure_may_draw, place_error_api, validate_place};
use crate::hub::{CanvasEvent, Event};
use crate::ids::{CanvasObjectId, ChannelId};
use crate::ratelimit::Class;
use crate::store::{BatchError, BatchItem};

/// Most objects one batch may carry.
pub(in crate::http) const MAX_BATCH_OBJECTS: usize = 200;

/// The whole batch body: 200 objects at the props ceiling plus their envelopes.
pub(in crate::http) const MAX_BATCH_BODY_BYTES: usize = 1024 * 1024;

#[derive(Deserialize)]
pub(in crate::http) struct BatchParams {
    objects: Vec<PlaceParams>,
}

#[derive(Serialize)]
pub(in crate::http) struct BatchDto {
    objects: Vec<CanvasObjectDto>,
}

/// `POST /channels/{channel_id}/canvas/objects/batch`.
///
/// Charged [`Class::CanvasBatch`] by object count. Idempotent per object id: a retried
/// batch answers with the stored rows and publishes nothing for them.
pub(in crate::http) async fn place_batch(
    Authed(ctx): Authed,
    parts: Parts,
    Path(channel_id): Path<String>,
    State(state): State<AppState>,
    Json(params): Json<BatchParams>,
) -> Result<(axum::http::StatusCode, Json<BatchDto>), ApiError> {
    let channel_id = ChannelId(parse_uuid(&channel_id)?);
    let count = params.objects.len();
    if count == 0 || count > MAX_BATCH_OBJECTS {
        return Err(ApiError::BadRequest("a batch holds 1 to 200 objects"));
    }
    // The request pays for its first object, and the rest of the count follows.
    enforce(&state, &parts, Some(&ctx), Class::CanvasBatch)?;
    if count > 1 {
        enforce_weighted(&state, &parts, &ctx, Class::CanvasBatch, (count - 1) as f64)?;
    }
    ensure_may_draw(&state, ctx.user_id, channel_id).await?;

    let mut seen = HashSet::with_capacity(count);
    let mut ids = Vec::with_capacity(count);
    let mut validated = Vec::with_capacity(count);
    for (index, object) in params.objects.into_iter().enumerate() {
        let id = CanvasObjectId(parse_uuid(&object.id)?);
        if !seen.insert(id) {
            return Err(ApiError::BadRequestDetail(format!(
                "object {index} repeats an id in this batch"
            )));
        }
        let place = validate_place(object).map_err(|error| indexed(error, index))?;
        ids.push(id);
        validated.push(place);
    }
    let items: Vec<BatchItem<'_>> = ids
        .iter()
        .zip(&validated)
        .map(|(&id, place)| BatchItem {
            id,
            request: place.request(),
        })
        .collect();

    let placed = state
        .store
        .place_canvas_objects(channel_id, ctx.user_id, &items)
        .await
        .map_err(|BatchError { index, error }| indexed(place_error_api(error), index))?;

    // No await between the commit and these calls; see `ws::permission_cache`.
    for placement in placed.iter().filter(|placement| placement.fresh) {
        state.hub.publish(Event::Canvas(CanvasEvent::ObjectPlaced {
            channel_id,
            object: Arc::new(placement.object.clone()),
        }));
    }
    Ok((
        axum::http::StatusCode::CREATED,
        Json(BatchDto {
            objects: placed
                .into_iter()
                .map(|placement| CanvasObjectDto::from(placement.object))
                .collect(),
        }),
    ))
}

/// Names the object a refusal is about, keeping its status.
fn indexed(error: ApiError, index: usize) -> ApiError {
    match error {
        ApiError::BadRequest(message) => {
            ApiError::BadRequestDetail(format!("object {index}: {message}"))
        }
        ApiError::Conflict(message) => {
            ApiError::ConflictDetail(format!("object {index}: {message}"))
        }
        other => other,
    }
}
