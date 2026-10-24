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
