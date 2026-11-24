// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Hides what an audit row says about a channel or category its reader cannot see.
//!
//! The log is read with MANAGE_SERVER, which does not reveal a private channel (decision 0011), so a
//! row about one keeps its action and target and loses the name, fields and overwrite parameters.

use std::collections::HashSet;

use serde_json::{Map, Value};

use super::AdminChangeDto;
use crate::http::AppState;
use crate::http::category_sight::CategorySight;
use crate::http::error::ApiError;
use crate::ids::{ChannelCategoryId, ChannelId, UserId};
use crate::permissions::Permissions;

enum Subject {
    Channel(ChannelId),
    Category(ChannelCategoryId),
    Unparseable,
}

fn subject_of(entry: &AdminChangeDto) -> Option<Subject> {
    let target = entry.target_id.as_deref();
    let parse = |target: Option<&str>| target.and_then(|id| id.parse().ok());
    if entry.action.starts_with("channel.") {
        Some(parse(target).map_or(Subject::Unparseable, |id| Subject::Channel(ChannelId(id))))
    } else if entry.action.starts_with("category.") {
        Some(parse(target).map_or(Subject::Unparseable, |id| {
            Subject::Category(ChannelCategoryId(id))
        }))
    } else {
        None
    }
}

/// Replaces the detail of every row about a channel or category `reader` cannot see.
pub(super) async fn redact_hidden(
    state: &AppState,
    reader: UserId,
    entries: &mut [AdminChangeDto],
) -> Result<(), ApiError> {
    let base = state.store.base_permissions(reader).await?;
    if base.contains(Permissions::ADMINISTRATOR) {
        return Ok(());
    }
    let mut listed: Option<HashSet<ChannelCategoryId>> = None;
    for entry in entries {
        let hidden = match subject_of(entry) {
            None => false,
            Some(Subject::Unparseable) => true,
            Some(Subject::Channel(id)) => {
                !state.store.viewed_channel_before_delete(reader, id).await?
            }
            Some(Subject::Category(id)) => {
                if listed.is_none() {
                    listed = Some(CategorySight::of(state, reader).await?.listed);
                }
                !listed.as_ref().is_some_and(|listed| listed.contains(&id))
            }
        };
        if hidden {
            let mut detail = Map::new();
            detail.insert("redacted".into(), Value::Bool(true));
            entry.detail = Value::Object(detail);
        }
    }
    Ok(())
}
