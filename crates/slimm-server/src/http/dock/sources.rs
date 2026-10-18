// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Community module sources beside the official one, per
//! docs/decisions/0046-more-than-one-module-source.md.
//!
//! A source is an `owner/repo` slug read from the same fixed host as the
//! official one, never a URL, so every fetch keeps the one allowlist. Its
//! index, manifests and artifacts go through the same validation and sha256
//! check as the official source's.

use std::collections::HashSet;
use std::path::PathBuf;

use serde::Deserialize;
use url::Url;

use super::{Enabled, fetch_index};
use crate::http::AppState;
use crate::http::dock::dock_sources::OFFICIAL_ID;
use crate::http::error::ApiError;

/// Where a source's files are read from.
#[derive(Clone)]
pub(super) enum Origin {
    /// Bases on the fixed host, tried in order.
    Remote(Vec<Url>),
    /// The operator's `dev_module_dir`; never fetched over the network.
    Dev(PathBuf),
}

/// Where a Dock call reads from, and the repo recorded on an install (`None`
/// for the official source).
pub(super) struct Resolved {
    pub(super) origin: Origin,
    pub(super) repo: Option<String>,
}

/// The source id and recorded repo of the operator's local directory.
pub(crate) const DEV_ID: &str = "dev";
pub(crate) const DEV_REPO: &str = "local/dev";

#[derive(Deserialize)]
pub(super) struct SourceQuery {
    pub(super) source: Option<String>,
}

pub(super) async fn resolve(
    state: &AppState,
    dock: &Enabled,
    source: Option<&str>,
) -> Result<Resolved, ApiError> {
    match source {
        None | Some(OFFICIAL_ID) => Ok(Resolved {
            origin: Origin::Remote(dock.official_bases.clone()),
            repo: None,
        }),
        Some(DEV_ID) => {
            let root = dock
                .dev_dir
                .clone()
                .ok_or(ApiError::NotFound("unknown module source"))?;
            Ok(Resolved {
                origin: Origin::Dev(root),
                repo: Some(DEV_REPO.to_owned()),
            })
        }
        Some(id) => {
            let found = state
                .store
                .dock_source(id)
                .await?
                .ok_or(ApiError::NotFound("unknown module source"))?;
            Ok(Resolved {
                origin: Origin::Remote(vec![dock.base_for(&found.repo)?]),
                repo: Some(found.repo),
            })
        }
    }
}

/// Module ids a listing of `repo`'s source must show as not installable: any
/// the official index publishes (best effort, the listing still works when
/// it is down) and any already installed from a different source.
pub(super) async fn taken_ids(
    state: &AppState,
    dock: &Enabled,
    repo: &str,
) -> Result<HashSet<String>, ApiError> {
    let mut taken: HashSet<String> =
        match fetch_index(dock, &Origin::Remote(dock.official_bases.clone())).await {
            Ok(index) => index.into_iter().map(|e| e.id).collect(),
            Err(_) => HashSet::new(),
        };
    for m in state.store.list_installed_modules().await? {
        if m.source_repo.as_deref() != Some(repo) {
            taken.insert(m.id);
        }
    }
    Ok(taken)
}

/// Refuses an install whose id another source already owns: the official
/// index always wins, and an id installed from one source stays with it
/// until uninstalled. Fails closed when the official index cannot be read.
pub(super) async fn check_id_free(
    state: &AppState,
    dock: &Enabled,
    resolved: &Resolved,
    id: &str,
) -> Result<(), ApiError> {
    if let Some(installed) = state.store.installed_module(id).await?
        && installed.source_repo != resolved.repo
    {
        return Err(ApiError::Conflict(
            "that module id is already installed from a different source; uninstall it first",
        ));
    }
    if resolved.repo.is_some() && !matches!(resolved.origin, Origin::Dev(_)) {
        let official = fetch_index(dock, &Origin::Remote(dock.official_bases.clone())).await?;
        if official.iter().any(|e| e.id == id) {
            return Err(ApiError::Conflict(
                "that module id belongs to the official source",
            ));
        }
    }
    Ok(())
}
