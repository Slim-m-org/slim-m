// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The pictures a `screen_stamp` report carries (decision 0121), filled in once per page.
//!
//! One report can hold pictures from several channels, so each viewer gets only those from
//! channels they may read reports from, by the rule the picture fetch grant also uses.

use std::collections::HashMap;

use uuid::Uuid;

use super::super::AppState;
use super::super::error::ApiError;
use super::report_visible_in;
use super::{ModerationHistoryItemDto, ReportDto};
use crate::ids::{ChannelId, UserId};
use crate::store::{ReportPicture, SCREEN_STAMP_KIND};

/// Whose page the pictures are for.
#[derive(Clone, Copy)]
pub(super) enum Viewer {
    /// Sees every picture, as a holder of VIEW_MODERATION_HISTORY sees every resolved report.
    Everything,
    /// Sees the pictures from channels this moderator may read reports from.
    Moderator(UserId),
}

/// Sets `picture_ids` on every `screen_stamp` report in an open-queue page.
pub(super) async fn fill_reports(
    state: &AppState,
    viewer: Viewer,
    dtos: &mut [ReportDto],
) -> Result<(), ApiError> {
    let ids = dtos
        .iter()
        .filter(|dto| dto.subject_kind == SCREEN_STAMP_KIND)
        .map(|dto| dto.id.as_str());
    let mut pictures = pictures_of(state, viewer, ids).await?;
    for dto in dtos
        .iter_mut()
        .filter(|dto| dto.subject_kind == SCREEN_STAMP_KIND)
    {
        dto.picture_ids = Some(take(&mut pictures, &dto.id));
    }
    Ok(())
}

/// Sets `picture_ids` on every resolved `screen_stamp` report in a history page.
pub(super) async fn fill_history(
    state: &AppState,
    viewer: Viewer,
    dtos: &mut [ModerationHistoryItemDto],
) -> Result<(), ApiError> {
    let ids = dtos.iter().filter_map(|dto| match dto {
        ModerationHistoryItemDto::ResolvedReport {
            id, subject_kind, ..
        } if subject_kind == SCREEN_STAMP_KIND => Some(id.as_str()),
        _ => None,
    });
    let mut pictures = pictures_of(state, viewer, ids).await?;
    for dto in dtos.iter_mut() {
        if let ModerationHistoryItemDto::ResolvedReport {
            id,
            subject_kind,
            picture_ids,
            ..
        } = dto
            && subject_kind == SCREEN_STAMP_KIND
        {
            *picture_ids = Some(take(&mut pictures, id));
        }
    }
    Ok(())
}

async fn pictures_of<'a>(
    state: &AppState,
    viewer: Viewer,
    report_ids: impl Iterator<Item = &'a str>,
) -> Result<HashMap<Uuid, Vec<String>>, ApiError> {
    let report_ids: Vec<Uuid> = report_ids.filter_map(|id| id.parse().ok()).collect();
    let mut sight = Sight {
        viewer,
        known: HashMap::new(),
    };
    let mut shown = HashMap::new();
    for (report_id, pictures) in state.store.pictures_for_reports(&report_ids).await? {
        let mut ids: Vec<String> = Vec::new();
        for ReportPicture {
            attachment_id,
            channel_id,
        } in pictures
        {
            if !ids.contains(&attachment_id) && sight.sees(state, channel_id).await {
                ids.push(attachment_id);
            }
        }
        shown.insert(report_id, ids);
    }
    Ok(shown)
}

/// What one viewer may see, asked once per channel on a page.
struct Sight {
    viewer: Viewer,
    known: HashMap<ChannelId, bool>,
}

impl Sight {
    async fn sees(&mut self, state: &AppState, channel_id: ChannelId) -> bool {
        let Viewer::Moderator(user) = self.viewer else {
            return true;
        };
        if let Some(seen) = self.known.get(&channel_id) {
            return *seen;
        }
        let seen = report_visible_in(state, user, channel_id).await;
        self.known.insert(channel_id, seen);
        seen
    }
}

fn take(pictures: &mut HashMap<Uuid, Vec<String>>, report_id: &str) -> Vec<String> {
    report_id
        .parse()
        .ok()
        .and_then(|id: Uuid| pictures.remove(&id))
        .unwrap_or_default()
}
