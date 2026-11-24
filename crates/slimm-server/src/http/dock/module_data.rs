// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Install-time handling of a module's declared data (decision 0091): check the
//! schema can be applied before the install commits, create it after.

use std::sync::Arc;

use super::Manifest;
use crate::http::AppState;
use crate::http::error::ApiError;
use crate::module_runtime::{DataSchema, SqliteData};

const DATA_STORE: &str = "data.store";

/// The schema to create, only when the admin approved `data.store`.
fn approved_schema<'a>(manifest: &'a Manifest, approved: &[String]) -> Option<&'a DataSchema> {
    manifest
        .data
        .as_ref()
        .filter(|_| approved.iter().any(|c| c == DATA_STORE))
}

fn files(state: &AppState) -> Arc<SqliteData> {
    state.dock.module_data(state.store.modules_dir())
}

/// Refuses an install whose schema would remove or retype existing data.
pub(super) async fn check(
    state: &AppState,
    manifest: &Manifest,
    approved: &[String],
) -> Result<(), ApiError> {
    let Some(schema) = approved_schema(manifest, approved) else {
        return Ok(());
    };
    files(state)
        .check_schema(&manifest.id, schema)
        .await
        .map_err(ApiError::UpstreamInvalid)
}

/// Creates the missing tables, columns and indexes once the install is committed.
pub(super) async fn apply(
    state: &AppState,
    manifest: &Manifest,
    approved: &[String],
) -> Result<(), ApiError> {
    let Some(schema) = approved_schema(manifest, approved) else {
        return Ok(());
    };
    files(state)
        .apply_schema(&manifest.id, schema)
        .await
        .map_err(ApiError::UpstreamInvalid)
}

/// Deletes every module's rows about a member whose account is gone, and clears the pending
/// record once every module reports success; a failure stays pending for [`retry_member_purges`].
pub(crate) async fn purge_member(state: &AppState, user_id: crate::ids::UserId) {
    let data = files(state);
    let id = user_id.to_string();
    let outcome = tokio::task::spawn_blocking(move || {
        let mut failed = Vec::new();
        for module in data.stored_module_ids() {
            if crate::module_runtime::purge_member(data.as_ref(), &module, &id).is_err() {
                failed.push(module);
            }
        }
        failed
    })
    .await;
    match outcome {
        Ok(failed) if failed.is_empty() => {
            if let Err(err) = state.store.finish_module_data_purge(user_id).await {
                tracing::warn!(%err, "could not record a finished module data purge");
            }
        }
        Ok(failed) => tracing::error!(
            ?failed,
            "could not purge a deleted member from module data; will retry"
        ),
        Err(err) => tracing::error!(%err, "module data purge task failed; will retry"),
    }
}

/// How often members whose module data purge failed are tried again.
const RETRY_INTERVAL: std::time::Duration = std::time::Duration::from_secs(10 * 60);

/// Retries every pending purge once (what the sweep runs); returns how many members were attempted.
pub async fn retry_member_purges(state: &AppState) -> anyhow::Result<usize> {
    let pending = state.store.pending_module_data_purges().await?;
    for user_id in &pending {
        purge_member(state, *user_id).await;
    }
    Ok(pending.len())
}

/// Keeps retrying a deleted member's module data purge until every module reports success.
pub(crate) fn spawn_purge_sweep(state: AppState) {
    crate::sweeps::spawn_sweep(RETRY_INTERVAL, move || {
        let state = state.clone();
        async move {
            if let Err(err) = retry_member_purges(&state).await {
                tracing::warn!(error = %err, "module data purge retry failed");
            }
        }
    });
}
