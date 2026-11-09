// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A module as one file (decision 0090, section 9): an export of an installed
//! module, and an install from a file someone hands the admin.
//!
//! A package is the manifest exactly as it was reviewed plus the artifact, and
//! nothing else: no settings values, no data, no secrets. An import is
//! untrusted bytes, so it gets the Dock's own manifest validation, the sha256
//! the manifest names, a size ceiling, the same review digest and consent, and
//! it is recorded as `local/file` - never verified.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::request::Parts;
use axum::routing::{get, post};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use super::dock_install::{ArtifactSource, InstallRequest, install_manifest};
use super::fetch::{MAX_ARTIFACT_BYTES, MAX_MANIFEST_BYTES};
use super::manifest::{Manifest, parse_manifest};
use super::sources::FILE_REPO;
use super::validate_module_id;
use super::wire::{InstalledModuleDto, ManifestDto};
use crate::http::AppState;
use crate::http::error::ApiError;
use crate::http::extract::{Authed, Json, WRITE, enforce, require_manage_server};
use crate::http::manager_limited::ManagerLimited;
use crate::media::to_hex;
use crate::ratelimit::Class;

/// The only package layout this server reads; a newer one is refused, not guessed at.
const PACKAGE_SCHEMA: &str = "module-package/1";
/// Base64 inflates by a third; the rest is the manifest and the request's own fields.
const BODY_LIMIT: usize = MAX_ARTIFACT_BYTES / 3 * 4 + MAX_MANIFEST_BYTES + 16 * 1024;

pub(super) fn routes() -> Router<AppState> {
    Router::new()
        .route("/space/dock/packages/preview", post(preview))
        .route("/space/dock/packages/install", post(install_package))
        .route("/space/dock/modules/{id}/export", get(export))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Serialize, Deserialize)]
struct Package {
    #[serde(rename = "$slim")]
    schema: String,
    manifest: serde_json::Value,
    /// The wasm, base64.
    artifact: String,
}

#[derive(Deserialize)]
struct PackageInstall {
    package: Package,
    #[serde(flatten)]
    request: InstallRequest,
}

fn refused(reason: &str) -> ApiError {
    ApiError::BadRequestDetail(format!("not a usable module package: {reason}"))
}

/// The manifest and verified artifact a package carries, or why it is refused.
fn open(package: &Package) -> Result<(Manifest, Vec<u8>), ApiError> {
    if package.schema != PACKAGE_SCHEMA {
        return Err(refused("unknown package version"));
    }
    let manifest_bytes = serde_json::to_vec(&package.manifest).map_err(|_| refused("manifest"))?;
    if manifest_bytes.len() > MAX_MANIFEST_BYTES {
        return Err(refused("the manifest is too large"));
    }
    let manifest = parse_manifest(&manifest_bytes).map_err(|e| match e {
        super::manifest::ManifestError::Malformed(reason) => refused(&reason),
    })?;
    validate_module_id(&manifest.id)?;
    if package.artifact.len() > MAX_ARTIFACT_BYTES / 3 * 4 + 4 {
        return Err(refused("the module is too large"));
    }
    let artifact = STANDARD
        .decode(&package.artifact)
        .map_err(|_| refused("the module is not valid base64"))?;
    if artifact.len() > MAX_ARTIFACT_BYTES {
        return Err(refused("the module is too large"));
    }
    if to_hex(&Sha256::digest(&artifact)) != manifest.artifact.sha256 {
        return Err(refused("the module does not match its manifest"));
    }
    Ok((manifest, artifact))
}

async fn preview(
    _manager: ManagerLimited<WRITE>,
    Json(package): Json<Package>,
) -> Result<Json<ManifestDto>, ApiError> {
    let (manifest, _) = open(&package)?;
    Ok(Json(ManifestDto::from(manifest)))
}

async fn install_package(
    _manager: ManagerLimited<WRITE>,
    State(state): State<AppState>,
    Json(req): Json<PackageInstall>,
) -> Result<Json<InstalledModuleDto>, ApiError> {
    let (manifest, artifact) = open(&req.package)?;
    if let Some(installed) = state.store.installed_module(&manifest.id).await?
        && installed.source_repo.as_deref() != Some(FILE_REPO)
    {
        return Err(ApiError::Conflict(
            "that module id is already installed from a different source; uninstall it first",
        ));
    }
    install_manifest(
        &state,
        &manifest,
        ArtifactSource::Bytes(artifact),
        &req.request,
        Some(FILE_REPO),
    )
    .await
    .map(Json)
}

async fn export(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(id): Path<String>,
) -> Result<Json<Package>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    validate_module_id(&id)?;
    let manifest = state
        .store
        .module_manifest_json(&id)
        .await?
        .ok_or(ApiError::Conflict(
            "this module was installed before it could be exported; reinstall it first",
        ))?;
    let (sha256, wasm) = state
        .store
        .module_artifact(&id)
        .await?
        .ok_or(ApiError::NotFound("module not installed"))?;
    let manifest: serde_json::Value =
        serde_json::from_str(&manifest).map_err(|_| ApiError::Internal)?;
    if manifest
        .pointer("/artifact/sha256")
        .and_then(|v| v.as_str())
        != Some(sha256.as_str())
    {
        return Err(ApiError::Conflict(
            "the stored module no longer matches its manifest; reinstall it first",
        ));
    }
    Ok(Json(Package {
        schema: PACKAGE_SCHEMA.to_owned(),
        manifest,
        artifact: STANDARD.encode(wasm),
    }))
}

/// A module installed from a file, as its manifest and artifact are stored: a
/// file has no registry to read them back from, so this is what the module's
/// own screen and a later change of approvals work from.
pub(super) async fn stored_file_module(
    state: &AppState,
    id: &str,
) -> Result<(Manifest, Vec<u8>), ApiError> {
    let installed = state
        .store
        .installed_module(id)
        .await?
        .filter(|m| m.source_repo.as_deref() == Some(FILE_REPO))
        .ok_or(ApiError::NotFound("module not installed from a file"))?;
    let raw = state
        .store
        .module_manifest_json(&installed.id)
        .await?
        .ok_or(ApiError::Conflict("the module's manifest was not kept"))?;
    let manifest = parse_manifest(raw.as_bytes()).map_err(|_| ApiError::Internal)?;
    let (_, wasm) = state
        .store
        .module_artifact(&installed.id)
        .await?
        .ok_or(ApiError::NotFound("module has no stored artifact"))?;
    Ok((manifest, wasm))
}
