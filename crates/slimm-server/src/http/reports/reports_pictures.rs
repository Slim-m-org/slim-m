// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The pictures a `screen_stamp` report carries (decision 0121), filled in once per page.

use std::collections::HashMap;

use uuid::Uuid;

use super::super::AppState;
use super::super::error::ApiError;
use super::{ModerationHistoryItemDto, ReportDto};
use crate::store::SCREEN_STAMP_KIND;

/// Sets `picture_ids` on every `screen_stamp` report in an open-queue page.
pub(super) async fn fill_reports(state: &AppState, dtos: &mut [ReportDto]) -> Result<(), ApiError> {
    let ids = dtos
        .iter()
        .filter(|dto| dto.subject_kind == SCREEN_STAMP_KIND)
        .map(|dto| dto.id.as_str());
    let mut pictures = pictures_of(state, ids).await?;
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
    dtos: &mut [ModerationHistoryItemDto],
) -> Result<(), ApiError> {
    let ids = dtos.iter().filter_map(|dto| match dto {
        ModerationHistoryItemDto::ResolvedReport {
            id, subject_kind, ..
        } if subject_kind == SCREEN_STAMP_KIND => Some(id.as_str()),
        _ => None,
    });
    let mut pictures = pictures_of(state, ids).await?;
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
    report_ids: impl Iterator<Item = &'a str>,
) -> Result<HashMap<Uuid, Vec<String>>, ApiError> {
    let ids: Vec<Uuid> = report_ids.filter_map(|id| id.parse().ok()).collect();
    Ok(state.store.picture_ids_for_reports(&ids).await?)
}

fn take(pictures: &mut HashMap<Uuid, Vec<String>>, report_id: &str) -> Vec<String> {
    report_id
        .parse()
        .ok()
        .and_then(|id: Uuid| pictures.remove(&id))
        .unwrap_or_default()
}
