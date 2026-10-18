// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The routes that manage community module sources, per
//! docs/decisions/0046-more-than-one-module-source.md. A sibling of `dock.rs`
//! rather than a child so `tests/openapi_429_coverage.rs` can resolve the
//! handlers; the fetch-side helpers live in `dock/sources.rs`.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use serde::{Deserialize, Serialize};

use super::super::AppState;
use super::super::error::ApiError;
use super::super::extract::{Authed, Json, enforce, require_manage_server};
use crate::ratelimit::Class;
use crate::store::DockSource;

/// The path id the official source answers to in `?source=` and listings.
pub(crate) const OFFICIAL_ID: &str = "official";

const MAX_COMMUNITY_SOURCES: usize = 8;
const MAX_OWNER_LEN: usize = 39;
const MAX_REPO_NAME_LEN: usize = 100;

/// `owner/repo`, GitHub's own character rules, and nothing that could steer
/// the fixed host's path elsewhere.
pub(in crate::http) fn validate_repo(repo: &str) -> Result<(), ApiError> {
    const INVALID: ApiError = ApiError::BadRequest("a source is a GitHub owner/repo slug");
    let (owner, name) = repo.split_once('/').ok_or(INVALID)?;
    let owner_ok = !owner.is_empty()
        && owner.len() <= MAX_OWNER_LEN
        && owner.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
    let name_ok = !name.is_empty()
        && name.len() <= MAX_REPO_NAME_LEN
        && name != "."
        && name != ".."
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'));
    if owner_ok && name_ok {
        Ok(())
    } else {
        Err(INVALID)
    }
}

#[derive(Serialize)]
pub(in crate::http) struct SourceDto {
    id: String,
    repo: String,
    official: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    created_at: Option<i64>,
    /// An operator's local directory, not a repository: never verified.
    local: bool,
}

impl From<DockSource> for SourceDto {
    fn from(s: DockSource) -> Self {
        Self {
            id: s.id,
            repo: s.repo,
            official: false,
            created_at: Some(s.created_at),
            local: false,
        }
    }
}

pub(in crate::http) async fn list_sources(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<Vec<SourceDto>>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    let official_repo = state.dock.official_repo()?;
    let mut out = vec![SourceDto {
        id: OFFICIAL_ID.to_owned(),
        repo: official_repo.to_owned(),
        official: true,
        created_at: None,
        local: false,
    }];
    out.extend(
        state
            .store
            .list_dock_sources()
            .await?
            .into_iter()
            .map(SourceDto::from),
    );
    if state.dock.has_dev_source() {
        out.push(SourceDto {
            id: super::sources::DEV_ID.to_owned(),
            repo: super::sources::DEV_REPO.to_owned(),
            official: false,
            created_at: None,
            local: true,
        });
    }
    Ok(Json(out))
}

#[derive(Deserialize)]
pub(in crate::http) struct AddSourceRequest {
    repo: String,
}

pub(in crate::http) async fn add_source(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Json(req): Json<AddSourceRequest>,
) -> Result<(StatusCode, Json<SourceDto>), ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    let repo = req.repo.trim();
    validate_repo(repo)?;
    if state.dock.is_official(repo)? {
        return Err(ApiError::Conflict("that is already the official source"));
    }
    let existing = state.store.list_dock_sources().await?;
    let known = existing.iter().any(|s| s.repo.eq_ignore_ascii_case(repo));
    if !known && existing.len() >= MAX_COMMUNITY_SOURCES {
        return Err(ApiError::Conflict(
            "too many module sources; remove one first",
        ));
    }
    let (source, created) = state.store.add_dock_source(repo).await?;
    let status = if created {
        StatusCode::CREATED
    } else {
        StatusCode::OK
    };
    Ok((status, Json(SourceDto::from(source))))
}

pub(in crate::http) async fn remove_source(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(source_id): Path<String>,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Write)?;
    require_manage_server(&state, ctx.user_id).await?;
    if source_id == OFFICIAL_ID {
        return Err(ApiError::BadRequest(
            "the official source cannot be removed",
        ));
    }
    if state.store.remove_dock_source(&source_id).await? {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::NotFound("unknown module source"))
    }
}

#[cfg(test)]
mod tests {
    use super::validate_repo;

    #[test]
    fn accepts_a_plain_owner_and_repo() {
        assert!(validate_repo("someone/slim-addons").is_ok());
        assert!(validate_repo("a-b/repo_name.v2").is_ok());
    }

    #[test]
    fn refuses_urls_hosts_and_path_tricks() {
        for bad in [
            "",
            "someone",
            "https://evil.example/x/y",
            "evil.example/x/y",
            "someone/../etc",
            "someone/..",
            "../x",
            "a/b/c",
            "some one/repo",
            "someone/re?po",
            "someone/repo#x",
            "someone/repo@x",
            "127.0.0.1:8080/repo",
            "/repo",
            "someone/",
        ] {
            assert!(validate_repo(bad).is_err(), "{bad:?} must be refused");
        }
    }

    #[test]
    fn refuses_an_overlong_owner() {
        let owner = "a".repeat(40);
        assert!(validate_repo(&format!("{owner}/repo")).is_err());
    }
}
