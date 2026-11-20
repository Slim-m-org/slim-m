// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `PUT /categories/order`: the whole category arrangement at once, what a
//! drag in the rail sends (decision 0120).

use std::collections::HashSet;

use axum::Router;
use axum::extract::{DefaultBodyLimit, State};
use axum::http::request::Parts;
use axum::routing::put;
use serde::Deserialize;

use super::AppState;
use super::categories::{CategoryDto, require_manage_channels};
use super::category_sight::CategorySight;
use super::error::ApiError;
use super::extract::{Authed, Json, enforce};
use super::messages::parse_uuid;
use crate::hub::Event;
use crate::ids::ChannelCategoryId;
use crate::ratelimit::Class;
use crate::store::{CategoryOrderGroup, CategoryOrderReach, ReorderCategoriesError};

/// A small JSON document; refused well before axum's 2 MB default.
const BODY_LIMIT: usize = 64 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/categories/order", put(reorder))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Deserialize)]
struct OrderGroupRequest {
    /// Null for the top level.
    parent_id: Option<String>,
    category_ids: Vec<String>,
}

#[derive(Deserialize)]
struct ReorderCategoriesRequest {
    groups: Vec<OrderGroupRequest>,
}

/// Applies the arrangement in one transaction and answers every category the caller is listed,
/// in tree order; the hidden ones and the headings they may not manage keep their places. Publishes one `CategoryChanged` only when something moved.
async fn reorder(
    Authed(ctx): Authed,
    parts: Parts,
    State(state): State<AppState>,
    Json(req): Json<ReorderCategoriesRequest>,
) -> Result<Json<Vec<CategoryDto>>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_channels(&state, ctx.user_id).await?;
    let groups = parse_groups(&req.groups)?;
    let sight = CategorySight::of(&state, ctx.user_id).await?;
    let reach = CategoryOrderReach {
        hidden: sight.hidden(),
        fixed: sight.heading_only(),
        unfileable: sight.unfileable(),
    };

    match state.store.reorder_categories_around(&groups, &reach).await {
        Ok(outcome) => {
            if !outcome.moved.is_empty() {
                state.hub.publish(Event::CategoryChanged);
            }
            let sight = CategorySight {
                categories: outcome.categories,
                ..sight
            };
            Ok(Json(sight.listed_dtos()))
        }
        Err(err) => Err(refusal(err, &sight.listed)),
    }
}

fn parse_groups(groups: &[OrderGroupRequest]) -> Result<Vec<CategoryOrderGroup>, ApiError> {
    let parse = |raw: &str| parse_uuid(raw).map(ChannelCategoryId);
    groups
        .iter()
        .map(|group| {
            Ok(CategoryOrderGroup {
                parent_id: group.parent_id.as_deref().map(parse).transpose()?,
                category_ids: group
                    .category_ids
                    .iter()
                    .map(|id| parse(id))
                    .collect::<Result<_, _>>()?,
            })
        })
        .collect()
}

/// The refusal, naming only ids the caller was listed: one hidden or made since they were judged
/// must not reach them through a mismatch.
fn refusal(err: ReorderCategoriesError, listed: &HashSet<ChannelCategoryId>) -> ApiError {
    match err {
        ReorderCategoriesError::RepeatedParent => {
            ApiError::BadRequest("each parent_id may head only one group")
        }
        ReorderCategoriesError::Mismatch { missing, extra } => {
            let missing: Vec<_> = missing
                .into_iter()
                .filter(|id| listed.contains(id))
                .collect();
            if missing.is_empty() && extra.is_empty() {
                return ApiError::Conflict("the categories changed; reload and try again");
            }
            let mut parts = Vec::new();
            if !missing.is_empty() {
                parts.push(format!("missing live category(s): {}", join_ids(&missing)));
            }
            if !extra.is_empty() {
                parts.push(format!(
                    "named unknown or repeated category(s): {}",
                    join_ids(&extra)
                ));
            }
            ApiError::BadRequestDetail(parts.join("; "))
        }
        ReorderCategoriesError::UnknownParent(ids) => {
            ApiError::BadRequestDetail(format!("named unknown parent(s): {}", join_ids(&ids)))
        }
        ReorderCategoriesError::TooDeep(ids) => ApiError::ConflictDetail(format!(
            "a parent must be a top-level category, so not: {}",
            join_ids(&ids)
        )),
        ReorderCategoriesError::Internal(e) => e.into(),
    }
}

fn join_ids(ids: &[ChannelCategoryId]) -> String {
    ids.iter()
        .map(ChannelCategoryId::to_string)
        .collect::<Vec<_>>()
        .join(", ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_mismatch_never_names_a_category_the_caller_was_not_listed() {
        let unseen = ChannelCategoryId::generate();
        let seen = ChannelCategoryId::generate();
        let listed = HashSet::from([seen]);
        let only_unseen = ReorderCategoriesError::Mismatch {
            missing: vec![unseen],
            extra: vec![],
        };
        assert!(matches!(
            refusal(only_unseen, &listed),
            ApiError::Conflict(_)
        ));

        let both = ReorderCategoriesError::Mismatch {
            missing: vec![unseen, seen],
            extra: vec![],
        };
        let ApiError::BadRequestDetail(text) = refusal(both, &listed) else {
            panic!("a mismatch naming a listed category says which");
        };
        assert!(text.contains(&seen.to_string()), "{text}");
        assert!(!text.contains(&unseen.to_string()), "{text}");
    }
}
