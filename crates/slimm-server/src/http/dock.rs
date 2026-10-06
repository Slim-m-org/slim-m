// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Dock: browsing and installing modules from the addons repo, per
//! docs/decisions/0021-modules-and-the-dock.md. Gated on MANAGE_SERVER, the
//! same bit as `/space/analytics` and `/space/storage`, since it lives under
//! Space settings alongside them.
//!
//! Phase 1 (browse) and Phase 2 (install/enable/uninstall) only: nothing
//! here runs a module, or knows what one does. `manifest.rs` parses and
//! strictly validates what the registry returns; `ssrf.rs` and `fetch.rs`
//! reach it through a host-allowlisted client, the same posture decision
//! 0019 gives link preview's arbitrary-host fetch, narrowed here to the one
//! fixed host this Dock is configured with; `wire.rs` holds the DTOs.

mod capabilities;
mod fetch;
pub(super) mod keywords;
mod manifest;
mod sources;
mod ssrf;
mod testing;
pub(super) mod wire;

use std::sync::Arc;

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, Query, State};
use axum::http::request::Parts;
use axum::routing::{get, post};
use serde::Deserialize;
use sha2::{Digest, Sha256};
use url::Url;

use super::AppState;
use super::dock_lifecycle::{disable, enable, list_installed, uninstall};
use super::dock_sources::{add_source, list_sources, remove_source};
use super::error::ApiError;
use super::extract::require_manage_server;
use super::extract::{Authed, Json, enforce};
use crate::config::Config;
use crate::media::to_hex;
use crate::ratelimit::Class;
use crate::store::{
    DockProvenance, InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec,
    ModuleRuntimeLimits,
};

use capabilities::{approvable_host_capabilities, carried_host_capabilities};
use fetch::{FetchError, fetch_first};
use keywords::ensure_slash_keywords_free;
use manifest::{IndexEntry, Manifest, ManifestError, parse_index, parse_manifest, validate_slug};
use sources::SourceQuery;
use wire::{IndexEntryDto, InstalledModuleDto, ManifestDto};

const BODY_LIMIT: usize = 4 * 1024;

/// The fixed host every Dock fetch targets in production; see
/// `Config::addons_repo`'s own doc for why only the repo is configurable.
const ADDONS_HOST: &str = "raw.githubusercontent.com";

const MAX_MODULE_ID_LEN: usize = 64;

/// This deployment's Dock: cheap to clone (an `Option<Arc<_>>`), the same
/// shape `http::link_preview::LinkPreviews` and `http::gifs::GifSearch` use.
#[derive(Clone)]
pub struct Dock {
    inner: Option<Arc<Enabled>>,
}

struct Enabled {
    client: reqwest::Client,
    /// The official source's bases, tried in order; see `Config::addons_repos`.
    official_bases: Vec<Url>,
    /// The root every source hangs off as `<root>/<owner>/<repo>/main/`.
    source_root: Url,
    official_repos: Vec<String>,
    allowed_host: String,
}

impl Dock {
    /// Always enabled: unlike link previews, the Dock has no deployment-wide
    /// off switch - `MANAGE_SERVER` alone gates it. Only the repo it points
    /// at is configurable.
    pub fn new(config: &Config) -> Self {
        let root = Url::parse(&format!("https://{ADDONS_HOST}/"))
            .expect("a fixed host is always a valid URL");
        Self::rooted_at(root, config.addons_repos(), false)
    }

    fn rooted_at(source_root: Url, official_repos: Vec<String>, allow_private: bool) -> Self {
        let official_bases = official_repos
            .iter()
            .map(|repo| {
                source_root
                    .join(&format!("{repo}/main/"))
                    .expect("a fixed host and a repo slug always form a valid URL")
            })
            .collect();
        Self::from_parts(source_root, official_repos, official_bases, allow_private)
    }

    fn from_parts(
        source_root: Url,
        official_repos: Vec<String>,
        official_bases: Vec<Url>,
        allow_private: bool,
    ) -> Self {
        let allowed_host = source_root
            .host_str()
            .expect("the source root always has a host")
            .to_owned();
        Self {
            inner: Some(Arc::new(Enabled {
                client: ssrf::build_client(allow_private),
                official_bases,
                source_root,
                official_repos,
                allowed_host,
            })),
        }
    }

    /// A disabled stand-in for a test building [`AppState`] with no interest
    /// in the Dock: every one of its routes would need a real fetch, so
    /// nothing exercises it by accident.
    pub fn disabled() -> Self {
        Self { inner: None }
    }

    /// The official source's repo slug, for the sources listing.
    pub(crate) fn official_repo(&self) -> Result<&str, ApiError> {
        Ok(&self.enabled()?.official_repos[0])
    }

    /// Whether `repo` is any slug the official source is read from.
    pub(crate) fn is_official(&self, repo: &str) -> Result<bool, ApiError> {
        Ok(self
            .enabled()?
            .official_repos
            .iter()
            .any(|official| official.eq_ignore_ascii_case(repo)))
    }

    fn enabled(&self) -> Result<&Enabled, ApiError> {
        self.inner.as_deref().ok_or(ApiError::NotConfigured(
            "the module marketplace is not configured",
        ))
    }
}

impl Enabled {
    /// A community source's base: always the fixed host, only the slug varies.
    fn base_for(&self, repo: &str) -> Result<Url, ApiError> {
        self.source_root
            .join(&format!("{repo}/main/"))
            .map_err(|_| ApiError::Internal)
    }
}

/// The Dock routes, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/space/dock/modules", get(list_modules))
        .route("/space/dock/modules/{id}", get(get_module))
        .route(
            "/space/dock/modules/{id}/install",
            post(install).delete(uninstall),
        )
        .route("/space/dock/modules/{id}/enable", post(enable))
        .route("/space/dock/modules/{id}/disable", post(disable))
        .route("/space/dock/installed", get(list_installed))
        .route("/space/dock/sources", get(list_sources).post(add_source))
        .route(
            "/space/dock/sources/{sourceId}",
            axum::routing::delete(remove_source),
        )
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

impl From<FetchError> for ApiError {
    fn from(err: FetchError) -> Self {
        match err {
            // Unreachable unless the Dock's own fixed-base URL construction broke, never a caller's doing.
            FetchError::Refused => ApiError::Internal,
            FetchError::Missing => {
                ApiError::NotFound("no add-on registry was found at that source")
            }
            FetchError::Unavailable => ApiError::Unavailable,
        }
    }
}

impl From<ManifestError> for ApiError {
    fn from(err: ManifestError) -> Self {
        match err {
            ManifestError::Malformed(reason) => ApiError::UpstreamInvalid(reason),
        }
    }
}

/// `pub(crate)` rather than `pub(self)`: `http::module_commands` validates a
/// command route's own `moduleId` path segment the same way, and a second
/// slug validator there could silently drift from this one's rules.
///
/// Also the one place the broker ids are held back. `CODE_RUNNER_MODULE_ID` is
/// answered before the module store is ever consulted, so a registry listing
/// under that id would install, show as enabled, register its permissions, and
/// then have every one of its commands routed to the code runner instead -
/// permanently unreachable, with nothing said at install time. Refusing it here
/// covers install and manifest fetch together, and cannot reach the runner's own
/// path: both run routes branch on the id before `execute_command` calls this.
pub(crate) fn validate_module_id(id: &str) -> Result<(), ApiError> {
    if id == super::module_commands::CODE_RUNNER_MODULE_ID {
        return Err(ApiError::BadRequest(
            "that module id is reserved for this deployment's code runner",
        ));
    }
    validate_slug(id, MAX_MODULE_ID_LEN).map_err(|_| ApiError::BadRequest("invalid module id"))
}

/// Fetches and validates the module at [id]'s current `manifest.json`,
/// confirming the registry's own `id` field agrees with the path it was
/// fetched at - the same "does not alias a different resource" check
/// `messages::SendError::IdConflict` exists for elsewhere.
async fn fetch_manifest(dock: &Enabled, bases: &[Url], id: &str) -> Result<Manifest, ApiError> {
    let bytes = fetch_first(
        &dock.client,
        bases,
        &format!("modules/{id}/manifest.json"),
        &dock.allowed_host,
        fetch::MAX_MANIFEST_BYTES,
    )
    .await?;
    let manifest = parse_manifest(&bytes)?;
    if manifest.id != id {
        return Err(ApiError::UpstreamInvalid(
            "manifest.json's own id does not match the module it was fetched for".to_owned(),
        ));
    }
    Ok(manifest)
}

/// The first of `bases`' `index.json` that exists, fetched capped and validated.
async fn fetch_index(dock: &Enabled, bases: &[Url]) -> Result<Vec<IndexEntry>, ApiError> {
    let bytes = fetch_first(
        &dock.client,
        bases,
        "index.json",
        &dock.allowed_host,
        fetch::MAX_INDEX_BYTES,
    )
    .await?;
    Ok(parse_index(&bytes)?)
}

async fn list_modules(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Query(query): Query<SourceQuery>,
) -> Result<Json<Vec<IndexEntryDto>>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    let dock = state.dock.enabled()?;
    let resolved = sources::resolve(&state, dock, query.source.as_deref()).await?;
    let index = fetch_index(dock, &resolved.bases).await?;
    let taken = match &resolved.repo {
        Some(repo) => sources::taken_ids(&state, dock, repo).await?,
        None => Default::default(),
    };
    Ok(Json(
        index
            .into_iter()
            .map(|e| {
                let shadowed = taken.contains(&e.id);
                IndexEntryDto::new(e, shadowed)
            })
            .collect(),
    ))
}

async fn get_module(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(id): Path<String>,
    Query(query): Query<SourceQuery>,
) -> Result<Json<ManifestDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    validate_module_id(&id)?;
    let dock = state.dock.enabled()?;
    let resolved = sources::resolve(&state, dock, query.source.as_deref()).await?;
    let manifest = fetch_manifest(dock, &resolved.bases, &id).await?;
    Ok(Json(ManifestDto::from(manifest)))
}

#[derive(Deserialize)]
struct InstallRequest {
    /// The version the admin reviewed in the Dock before installing. Checked
    /// against the freshly re-fetched manifest's own `version` so a race
    /// with an upstream release cannot install something nobody reviewed.
    version: String,
    /// The host capabilities the admin approved after seeing them listed
    /// (decision 0023). Each must be one the manifest declared and the host
    /// implements. Omitted keeps what was approved before, minus anything the
    /// new manifest no longer declares, and never adds one; an empty list
    /// withdraws every approval.
    #[serde(default)]
    approved_host_capabilities: Option<Vec<String>>,
}

async fn install(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(id): Path<String>,
    Query(query): Query<SourceQuery>,
    Json(req): Json<InstallRequest>,
) -> Result<Json<InstalledModuleDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    validate_module_id(&id)?;
    let dock = state.dock.enabled()?;
    let resolved = sources::resolve(&state, dock, query.source.as_deref()).await?;
    sources::check_id_free(&state, dock, &resolved, &id).await?;
    let manifest = fetch_manifest(dock, &resolved.bases, &id).await?;
    if manifest.version != req.version {
        return Err(ApiError::Conflict(
            "the module's current version no longer matches the one requested; reopen it in the Dock",
        ));
    }
    let approved_host = match &req.approved_host_capabilities {
        Some(requested) => approvable_host_capabilities(&manifest, requested)?,
        None => carried_host_capabilities(&state, &manifest).await?,
    };
    if state
        .store
        .installed_module(&id)
        .await?
        .is_some_and(|m| m.enabled)
    {
        let keywords = manifest
            .extension_points
            .iter()
            .filter(|e| e.kind == "slash-command")
            .map(|e| e.name.as_str());
        ensure_slash_keywords_free(&state, &id, keywords).await?;
    }
    let artifact = fetch_artifact(dock, &resolved.bases, &manifest).await?;

    let permissions: Vec<ModulePermissionSpec> = manifest
        .permissions
        .iter()
        .map(|p| ModulePermissionSpec {
            key: &p.key,
            name: &p.name,
            description: &p.description,
        })
        .collect();
    let extension_points: Vec<ModuleExtensionPointSpec> = manifest
        .extension_points
        .iter()
        .map(|e| ModuleExtensionPointSpec {
            kind: &e.kind,
            name: &e.name,
            description: e.description.as_deref(),
            permission: e.permission.as_deref(),
            command: e.command.as_deref(),
            language: e.language.as_deref(),
        })
        .collect();
    let runtime_limits = ModuleRuntimeLimits {
        memory_mb: manifest.runtime.limits.memory_mb,
        wall_ms: manifest.runtime.limits.wall_ms,
        fuel: manifest.runtime.limits.fuel,
    };
    let installed = state
        .store
        .install_module_from_dock(
            InstallModuleRequest {
                id: &manifest.id,
                name: &manifest.name,
                version: &manifest.version,
                artifact_sha256: &manifest.artifact.sha256,
                approved_capabilities: &manifest.capabilities,
                runtime_limits: &runtime_limits,
                permissions: &permissions,
                extension_points: &extension_points,
            },
            &artifact,
            &DockProvenance {
                host_capabilities: &approved_host,
                source_repo: resolved.repo.as_deref(),
            },
        )
        .await?;
    Ok(Json(InstalledModuleDto::from(installed)))
}

/// Fetches the module's own artifact bytes at `manifest.artifact.path`,
/// relative to the same allowlisted base the manifest itself came from, and
/// refuses them if their sha256 does not match what the manifest declared -
/// the fetch-time half of the check `crate::module_runtime::ModuleHost`
/// repeats again, defense in depth, right before it ever runs them.
async fn fetch_artifact(
    dock: &Enabled,
    bases: &[Url],
    manifest: &Manifest,
) -> Result<Vec<u8>, ApiError> {
    let bytes = fetch_first(
        &dock.client,
        bases,
        &manifest.artifact.path,
        &dock.allowed_host,
        fetch::MAX_ARTIFACT_BYTES,
    )
    .await?;
    let digest = to_hex(&Sha256::digest(&bytes));
    if digest != manifest.artifact.sha256 {
        return Err(ApiError::UpstreamInvalid(
            "the module artifact's sha256 does not match its manifest".to_owned(),
        ));
    }
    Ok(bytes)
}
