// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Setting the deployment's channel order and category placement:
//! `PUT /channels/order` takes either the flat `channel_ids` list every
//! client before docs/decisions/0006-channel-categories.md already sent, or
//! the whole rail grouped by category that a cross-section drag produces.
//! Exactly one of the two must be present - additive-only means the old
//! shape keeps working, not that a second shape replaces it - so an old
//! client posting `channel_ids` alone still reorders positions and never
//! has any channel's `category_id` touched.

use std::collections::HashSet;
use std::sync::Arc;

use axum::Router;
use axum::extract::State;
use axum::http::request::Parts;
use axum::routing::put;
use serde::Deserialize;

use super::AppState;
use super::channels::ChannelDto;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::{ChannelCategoryId, ChannelId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{ChannelOrderGroup, ReorderChannelsError, ReorderOutcome};

/// The channel-ordering route, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new().route("/channels/order", put(reorder))
}

#[derive(Deserialize)]
struct ReorderGroupRequest {
    /// `null` for the implicit uncategorised section.
    category_id: Option<String>,
    channel_ids: Vec<String>,
}

/// Both fields are optional so either the pre-category flat shape or the
/// grouped one parses; [`reorder`] is what refuses a request naming neither
/// or both, since that decision needs a body-shaped 400, not a schema-shaped
/// one.
#[derive(Deserialize)]
struct ReorderRequest {
    #[serde(default)]
    channel_ids: Option<Vec<String>>,
    #[serde(default)]
    categories: Option<Vec<ReorderGroupRequest>>,
}

/// Sets the deployment's channel order and, when [`ReorderRequest::categories`]
/// is sent, its category placement too. Requires MANAGE_CHANNELS at the
/// deployment level, the same gate `createChannel`, `updateChannel` and
/// `deleteChannel` use. Charged the same [`Class::Write`] budget as those.
///
/// Publishes `ChannelUpdated` only for a channel `outcome.moved` names: a
/// no-op submission answers 200 with nothing published, or every other
/// connection would be told its cache is stale for nothing.
async fn reorder(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<ReorderRequest>,
) -> Result<Json<Vec<ChannelDto>>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    if !state
        .store
        .base_permissions(ctx.user_id)
        .await?
        .contains(Permissions::MANAGE_CHANNELS)
    {
        return Err(ApiError::Forbidden);
    }

    let visible: HashSet<ChannelId> = state
        .store
        .visible_channels_with_permissions(ctx.user_id)
        .await?
        .into_iter()
        .map(|(channel, ..)| channel.id)
        .collect();
    let hidden: HashSet<ChannelId> = state
        .store
        .list_channels()
        .await?
        .into_iter()
        .map(|channel| channel.id)
        .filter(|id| !visible.contains(id))
        .collect();

    let outcome = match (req.channel_ids, req.categories) {
        (Some(_), Some(_)) => {
            return Err(ApiError::BadRequest(
                "send either channel_ids or categories, not both",
            ));
        }
        (None, None) => {
            return Err(ApiError::BadRequest(
                "send either channel_ids or categories",
            ));
        }
        (Some(channel_ids), None) => {
            let ordered = channel_ids
                .iter()
                .map(|id| parse_uuid(id).map(ChannelId))
                .collect::<Result<Vec<_>, _>>()?;
            state
                .store
                .reorder_channels_flat_around(&ordered, &hidden)
                .await
        }
        (None, Some(categories)) => {
            let groups = parse_groups(&categories)?;
            state.store.reorder_channels_around(&groups, &hidden).await
        }
    };

    finish(&state, &visible, outcome).await
}

fn parse_groups(categories: &[ReorderGroupRequest]) -> Result<Vec<ChannelOrderGroup>, ApiError> {
    categories
        .iter()
        .map(|group| {
            let category_id = group
                .category_id
                .as_deref()
                .map(|id| parse_uuid(id).map(ChannelCategoryId))
                .transpose()?;
            let channel_ids = group
                .channel_ids
                .iter()
                .map(|id| parse_uuid(id).map(ChannelId))
                .collect::<Result<Vec<_>, _>>()?;
            Ok::<_, ApiError>(ChannelOrderGroup {
                category_id,
                channel_ids,
            })
        })
        .collect()
}

/// Shared by both the flat and grouped paths: publishes a live update for
/// every channel the store reports moved, and maps a refusal to the 400 it
/// should read as. The answer lists only the channels `visible` to the caller.
async fn finish(
    state: &AppState,
    visible: &HashSet<ChannelId>,
    outcome: Result<ReorderOutcome, ReorderChannelsError>,
) -> Result<Json<Vec<ChannelDto>>, ApiError> {
    match outcome {
        Ok(outcome) => {
            for channel in &outcome.channels {
                if outcome.moved.contains(&channel.id) {
                    let restricted = state.store.channel_restricted(channel.id).await?;
                    state
                        .hub
                        .publish(Event::ChannelUpdated(Arc::new(channel.clone()), restricted));
                }
            }
            Ok(Json(
                outcome
                    .channels
                    .into_iter()
                    .filter(|channel| visible.contains(&channel.id))
                    .map(ChannelDto::from)
                    .collect(),
            ))
        }
        Err(ReorderChannelsError::Mismatch { missing, extra }) => Err(ApiError::BadRequestDetail(
            mismatch_message(&missing, &extra),
        )),
        Err(ReorderChannelsError::UnknownCategory(unknown)) => {
            let ids = unknown
                .iter()
                .map(ChannelCategoryId::to_string)
                .collect::<Vec<_>>()
                .join(", ");
            Err(ApiError::BadRequestDetail(format!(
                "named unknown category(s): {ids}"
            )))
        }
        Err(ReorderChannelsError::Internal(e)) => Err(e.into()),
    }
}

/// Names which channels a rejected order got wrong, so a partial list does
/// not silently leave a gap.
fn mismatch_message(missing: &[ChannelId], extra: &[ChannelId]) -> String {
    let mut parts = Vec::new();
    if !missing.is_empty() {
        let ids = join_ids(missing);
        parts.push(format!("missing live channel(s): {ids}"));
    }
    if !extra.is_empty() {
        let ids = join_ids(extra);
        parts.push(format!("named unknown or repeated channel(s): {ids}"));
    }
    parts.join("; ")
}

fn join_ids(ids: &[ChannelId]) -> String {
    ids.iter()
        .map(ChannelId::to_string)
        .collect::<Vec<_>>()
        .join(", ")
}

#[cfg(test)]
mod tests {
    use super::{ReorderGroupRequest, join_ids, mismatch_message, parse_groups};
    use crate::ids::ChannelId;

    const UUID_A: &str = "00000000-0000-0000-0000-00000000000a";
    const UUID_B: &str = "00000000-0000-0000-0000-00000000000b";

    /// The reorder-mismatch error names only the halves that apply, and joins
    /// both when both do, so a moderator sees exactly which channels were
    /// missing and which were unknown or repeated.
    #[test]
    fn mismatch_message_names_only_the_halves_that_apply() {
        let a = ChannelId::generate();
        let b = ChannelId::generate();

        let missing_only = mismatch_message(&[a], &[]);
        assert!(missing_only.contains("missing live channel"));
        assert!(!missing_only.contains("unknown"));

        let extra_only = mismatch_message(&[], &[b]);
        assert!(extra_only.contains("unknown or repeated"));
        assert!(!extra_only.contains("missing"));

        let both = mismatch_message(&[a], &[b]);
        assert!(both.contains("missing") && both.contains("unknown"));
        assert!(both.contains("; "), "the two halves are joined");
    }

    #[test]
    fn join_ids_comma_separates_each_id() {
        let a = ChannelId::generate();
        let b = ChannelId::generate();
        let joined = join_ids(&[a, b]);
        assert!(joined.contains(&a.to_string()));
        assert!(joined.contains(&b.to_string()));
        assert!(joined.contains(", "));
    }

    fn group(category: Option<&str>, channels: &[&str]) -> ReorderGroupRequest {
        ReorderGroupRequest {
            category_id: category.map(str::to_owned),
            channel_ids: channels.iter().map(|s| s.to_string()).collect(),
        }
    }

    /// A null category is the implicit uncategorised section, which must parse
    /// to `None` rather than being refused.
    #[test]
    fn a_null_category_parses_as_the_uncategorised_section() {
        let Ok(out) = parse_groups(&[group(None, &[UUID_A])]) else {
            panic!("a null category is valid");
        };
        assert_eq!(out.len(), 1);
        assert!(out[0].category_id.is_none());
        assert_eq!(out[0].channel_ids.len(), 1);
    }

    #[test]
    fn a_present_category_and_its_channels_parse() {
        let Ok(out) = parse_groups(&[group(Some(UUID_B), &[UUID_A, UUID_B])]) else {
            panic!("valid ids parse");
        };
        assert!(out[0].category_id.is_some());
        assert_eq!(out[0].channel_ids.len(), 2);
    }

    #[test]
    fn an_unparseable_id_is_refused_in_either_position() {
        assert!(parse_groups(&[group(Some("not-a-uuid"), &[])]).is_err());
        assert!(parse_groups(&[group(None, &["not-a-uuid"])]).is_err());
    }
}
