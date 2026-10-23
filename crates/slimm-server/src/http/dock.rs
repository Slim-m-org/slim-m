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

use self::dock_lifecycle::{clear_storage, disable, enable, list_installed, uninstall};
use self::dock_settings::{get_settings, put_settings};
use self::dock_sources::{add_source, list_sources, remove_source};
use super::AppState;
use super::error::ApiError;
use super::extract::require_manage_server;
use super::extract::{Authed, Json, enforce};
use super::module_host;
use crate::config::Config;
use crate::media::to_hex;
use crate::ratelimit::Class;
use crate::store::{
    DockProvenance, InstallModuleRequest, ModuleExtensionPointSpec, ModulePermissionSpec,
    ModuleRuntimeLimits, ModuleSchedule,
};

use capabilities::{
    approvable_host_capabilities, carried_host_capabilities, local_network_approval,
};
use fetch::{FetchError, fetch_first};
use keywords::ensure_slash_keywords_free;
use manifest::{IndexEntry, Manifest, ManifestError, parse_index, parse_manifest, validate_slug};
use sources::{Origin, SourceQuery};
use wire::{IndexEntryDto, InstalledModuleDto, ManifestDto};

pub(super) mod dock_lifecycle;
pub(super) mod dock_settings;
pub(super) mod dock_sources;

const BODY_LIMIT: usize = 4 * 1024;
/// Room for 32 settings of up to 1000 characters each.
const SETTINGS_BODY_LIMIT: usize = 64 * 1024;

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
    /// The operator's local module directory, canonical; `None` leaves the `dev` source absent.
    dev_dir: Option<std::path::PathBuf>,
}

impl Dock {
    /// Always enabled: unlike link previews, the Dock has no deployment-wide
    /// off switch - `MANAGE_SERVER` alone gates it. Only the repo it points
    /// at is configurable.
    pub fn new(config: &Config) -> Self {
        let root = Url::parse(&format!("https://{ADDONS_HOST}/"))
            .expect("a fixed host is always a valid URL");
        Self::rooted_at(root, config.addons_repos(), false)
            .with_dev_dir(config.dev_module_dir.as_deref())
    }

    /// Reads the operator's `dev_module_dir`, if it names a directory.
    fn with_dev_dir(mut self, dir: Option<&str>) -> Self {
        let Some(dir) = dir else { return self };
        match std::fs::canonicalize(dir) {
            Ok(path) if path.is_dir() => {
                if let Some(inner) = self.inner.as_mut().and_then(Arc::get_mut) {
                    inner.dev_dir = Some(path);
                }
            }
            _ => tracing::warn!(
                dir,
                "SLIMM_DEV_MODULE_DIR is not a readable directory; the dev source stays off"
            ),
        }
        self
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
                dev_dir: None,
            })),
        }
    }

    /// A disabled stand-in for a test building [`AppState`] with no interest
    /// in the Dock: every one of its routes would need a real fetch, so
    /// nothing exercises it by accident.
    pub fn disabled() -> Self {
        Self { inner: None }
    }

    /// Whether the operator turned the local `dev` source on.
    pub(crate) fn has_dev_source(&self) -> bool {
        self.inner.as_deref().is_some_and(|d| d.dev_dir.is_some())
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
        .route(
            "/space/dock/modules/{id}/storage",
            axum::routing::delete(clear_storage),
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
        .route(
            "/space/dock/modules/{id}/settings",
            get(get_settings)
                .put(put_settings)
                .layer(DefaultBodyLimit::max(SETTINGS_BODY_LIMIT)),
        )
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

/// [path] from wherever [origin] keeps its files.
async fn fetch_path(
    dock: &Enabled,
    origin: &Origin,
    path: &str,
    limits: fetch::Limits,
) -> Result<Vec<u8>, FetchError> {
    match origin {
        Origin::Remote(bases) => {
            fetch_first(&dock.client, bases, path, &dock.allowed_host, limits).await
        }
        Origin::Dev(root) => fetch::read_local(root, path, limits).await,
    }
}

/// Fetches and validates the module at [id]'s current `manifest.json`,
/// confirming the registry's own `id` field agrees with the path it was
/// fetched at - the same "does not alias a different resource" check
/// `messages::SendError::IdConflict` exists for elsewhere.
async fn fetch_manifest(dock: &Enabled, origin: &Origin, id: &str) -> Result<Manifest, ApiError> {
    let bytes = fetch_path(
        dock,
        origin,
        &format!("modules/{id}/manifest.json"),
        fetch::Limits::MANIFEST,
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

/// `bases` moved to the immutable ref the index published for `id`, so the
/// manifest an admin reviews and the artifact it installs come from one fixed
/// commit. An entry with no ref (an older index), or an index that cannot be
/// read, leaves `bases` on `main`; the reviewed digest still binds the install.
async fn pinned_origin(dock: &Enabled, origin: &Origin, id: &str) -> Result<Origin, ApiError> {
    let Origin::Remote(bases) = origin else {
        return Ok(origin.clone());
    };
    let Ok(index) = fetch_index(dock, origin).await else {
        return Ok(origin.clone());
    };
    let Some(reference) = index
        .into_iter()
        .find(|e| e.id == id)
        .and_then(|e| e.reference)
    else {
        return Ok(origin.clone());
    };
    bases
        .iter()
        .map(|base| {
            base.join(&format!("../{reference}/"))
                .map_err(|_| ApiError::Internal)
        })
        .collect::<Result<Vec<_>, _>>()
        .map(Origin::Remote)
}

/// The first of `bases`' `index.json` that exists, fetched capped and validated.
async fn fetch_index(dock: &Enabled, origin: &Origin) -> Result<Vec<IndexEntry>, ApiError> {
    let bytes = fetch_path(dock, origin, "index.json", fetch::Limits::INDEX).await?;
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
    let index = fetch_index(dock, &resolved.origin).await?;
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
    let origin = pinned_origin(dock, &resolved.origin, &id).await?;
    let manifest = fetch_manifest(dock, &origin, &id).await?;
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
    /// The second, separate approval for `net.fetch` to reach local network
    /// addresses. Omitted keeps an earlier approval for the same hosts.
    #[serde(default)]
    approve_local_network: Option<bool>,
    /// The `review_digest` of the manifest the admin was shown. Refused when
    /// the manifest has changed since, so consent is for what was reviewed.
    #[serde(default)]
    reviewed_digest: Option<String>,
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
    let origin = pinned_origin(dock, &resolved.origin, &id).await?;
    let manifest = fetch_manifest(dock, &origin, &id).await?;
    if manifest.version != req.version {
        return Err(ApiError::Conflict(
            "the module's current version no longer matches the one requested; reopen it in the Dock",
        ));
    }
    if req
        .reviewed_digest
        .as_deref()
        .is_some_and(|reviewed| reviewed != manifest.review_digest())
    {
        return Err(ApiError::Conflict(
            "the module changed since you reviewed it; reopen it in the Dock",
        ));
    }
    let approved_host = match &req.approved_host_capabilities {
        Some(requested) => approvable_host_capabilities(&manifest, requested)?,
        None => carried_host_capabilities(&state, &manifest).await?,
    };
    let local_network =
        local_network_approval(&state, &manifest, &approved_host, req.approve_local_network)
            .await?;
    let network_hosts: &[String] = if approved_host.iter().any(|c| c == manifest::NET_FETCH) {
        &manifest.network.hosts
    } else {
        &[]
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
    let artifact = fetch_artifact(dock, &origin, &manifest).await?;

    let permissions: Vec<ModulePermissionSpec> = manifest
        .permissions
        .iter()
        .map(|p| ModulePermissionSpec {
            key: &p.key,
            name: &p.name,
            description: &p.description,
        })
        .collect();
    let extension_points: Vec<ModuleExtensionPointSpec> =
        manifest.extension_points.iter().map(Into::into).collect();
    let schedules: Vec<ModuleSchedule> = manifest
        .schedules
        .iter()
        .map(|s| ModuleSchedule {
            command: s.command.clone(),
            every_minutes: s.every_minutes,
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
                network_hosts,
                local_network_approved: local_network,
                schedules: &schedules,
                platform: &manifest.platform,
            },
        )
        .await?;
    let installed = if module_host::schedule_approved(&installed) {
        state
            .store
            .ensure_module_bot(&installed.id, &installed.name)
            .await?;
        state
            .store
            .installed_module(&installed.id)
            .await?
            .ok_or(ApiError::Internal)?
    } else {
        installed
    };
    Ok(Json(InstalledModuleDto::from(installed)))
}

/// Fetches the module's own artifact bytes at `manifest.artifact.path`,
/// relative to the same allowlisted base the manifest itself came from, and
/// refuses them if their sha256 does not match what the manifest declared -
/// the fetch-time half of the check `crate::module_runtime::ModuleHost`
/// repeats again, defense in depth, right before it ever runs them.
async fn fetch_artifact(
    dock: &Enabled,
    origin: &Origin,
    manifest: &Manifest,
) -> Result<Vec<u8>, ApiError> {
    let bytes = fetch_path(
        dock,
        origin,
        &manifest.artifact.path,
        fetch::Limits::ARTIFACT,
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
