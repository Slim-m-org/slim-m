// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The deployment-wide storage ceiling, `SLIMM_MAX_TOTAL_ATTACHMENT_BYTES`.
//!
//! Checked before the bytes are written, never after, so a refusal leaves
//! nothing on disk to reclaim. The stored total alone is stale the moment two
//! uploads overlap, so the check also counts open resumable sessions (their
//! declared size) and [`media::Reservation`]s held across the gap between the
//! final check and the row. Checks that reserve run under the media admission
//! gate, so the last bytes go to exactly one caller.
//!
//! Not a per-account quota: that needs a policy answer nobody has asked for.
//! There is no default ceiling, since a guess would either refuse legitimate
//! uploads on a large volume or do nothing on a small one. What every
//! deployment gets instead is a free-space floor on the media volume, so
//! uploads stop before the disk fills and SQLite can still write.

use uuid::Uuid;

use super::AppState;
use super::error::ApiError;
use crate::media;
use crate::store::now_ms;

/// Refuses `incoming` bytes that would pass the ceiling, counting pending claims.
///
/// `exclude` is a resumable session whose own declared size is the thing being
/// stored, so it is not charged twice.
pub(super) async fn ensure_room(
    state: &AppState,
    incoming: i64,
    exclude: Option<Uuid>,
) -> Result<(), ApiError> {
    let ceiling = state.media.max_total_attachment_bytes();
    if ceiling.is_none() && !state.media.has_free_floor() {
        return Ok(());
    }
    // Claims first: one released after its row lands is then seen in the total, never in neither.
    let pending = state
        .media
        .pending_bytes(exclude, now_ms())
        .await
        .map_err(|err| {
            tracing::error!(error = %err, "could not total pending uploads");
            ApiError::Internal
        })?;
    let incoming = incoming.max(0) as u64;
    // A session being completed already sits on the volume, so only the ceiling charges its bytes.
    let on_disk = if exclude.is_some() { 0 } else { incoming };
    if state.media.below_free_floor(on_disk, pending) {
        return Err(ApiError::InsufficientStorage);
    }
    let Some(ceiling) = ceiling else {
        return Ok(());
    };
    let held = state.store.total_attachment_bytes().await?.max(0) as u64;
    let total = held.saturating_add(pending).saturating_add(incoming);
    if total > ceiling {
        return Err(ApiError::InsufficientStorage);
    }
    Ok(())
}

/// A check with no claim; for callers that store right away.
pub(super) async fn room_for(state: &AppState, incoming: i64) -> Result<(), ApiError> {
    ensure_room(state, incoming, None).await
}

/// Checks and claims `incoming` bytes, held until the guard drops.
pub(super) async fn reserve_room(
    state: &AppState,
    incoming: i64,
    exclude: Option<Uuid>,
) -> Result<media::Reservation, ApiError> {
    if state.media.max_total_attachment_bytes().is_none() && !state.media.has_free_floor() {
        return Ok(media::Reservation::none());
    }
    let _gate = state.media.admission_gate().await;
    ensure_room(state, incoming, exclude).await?;
    Ok(state.media.reserve(incoming.max(0) as u64))
}
