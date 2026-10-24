// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What installed modules show on a member's profile and next to their name
//! (decision 0091, "Slots: slot/1"). Any signed-in member may read them; a
//! module is asked once per slot for every member missing from the cache, and
//! a module that fails shows nothing instead of failing the request.

use std::collections::{BTreeMap, HashMap};
use std::time::Instant;

use axum::Router;
use axum::extract::{Path, State};
use axum::routing::get;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::AppState;
use super::error::ApiError;
use super::extract::{AuthedLimited, Json, MODULE, Query};
use super::module_run::{RunKind, RunRequest, run_installed};
use super::module_slot_cache::SlotKey;
use super::module_slot_nodes::{SlotItem, parse_response};
use crate::ids::UserId;
use crate::store::{InstalledModule, ModuleSlot, RunResult, now_ms};

const PROFILE_SECTION: &str = "profile.section";
const MEMBER_BADGE: &str = "member.badge";
const SLOT_COMMAND: &str = "@slot";
const MAX_BADGE_IDS: usize = 100;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/space/dock/slots/profile/{user_id}", get(profile))
        .route("/space/dock/slots/badges", get(badges))
}

#[derive(Serialize)]
struct ProfileSection {
    module_id: String,
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    title: Option<String>,
    nodes: Vec<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    fallback: Option<String>,
}

#[derive(Serialize)]
struct ProfileResponse {
    sections: Vec<ProfileSection>,
}

#[derive(Serialize)]
struct Badge {
    module_id: String,
    name: String,
    nodes: Vec<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    fallback: Option<String>,
}

#[derive(Serialize)]
struct BadgesResponse {
    badges: BTreeMap<String, Vec<Badge>>,
}

#[derive(Deserialize)]
struct BadgesQuery {
    ids: String,
}

/// One declared slot and what its module returned for the members asked about.
struct Filled {
    module_id: String,
    slot: ModuleSlot,
    items: HashMap<UserId, SlotItem>,
}

async fn profile(
    AuthedLimited(ctx): AuthedLimited<MODULE>,
    State(state): State<AppState>,
    Path(raw): Path<String>,
) -> Result<Json<ProfileResponse>, ApiError> {
    let member = parse_user(&raw)?;
    let mut sections = Vec::new();
    if state.store.user_profile(member).await?.is_some() {
        for filled in fill(&state, ctx.user_id, PROFILE_SECTION, &[member]).await? {
            let Some(item) = filled.items.get(&member) else {
                continue;
            };
            sections.push(ProfileSection {
                module_id: filled.module_id,
                name: filled.slot.name,
                title: filled.slot.title,
                nodes: item.nodes.clone(),
                fallback: item.fallback.clone(),
            });
        }
    }
    Ok(Json(ProfileResponse { sections }))
}

async fn badges(
    AuthedLimited(ctx): AuthedLimited<MODULE>,
    State(state): State<AppState>,
    Query(query): Query<BadgesQuery>,
) -> Result<Json<BadgesResponse>, ApiError> {
    let asked = parse_ids(&query.ids)?;
    let live: Vec<UserId> = state
        .store
        .user_profiles(&asked)
        .await?
        .into_iter()
        .map(|u| u.id)
        .collect();
    let mut badges: BTreeMap<String, Vec<Badge>> = BTreeMap::new();
    if !live.is_empty() {
        for filled in fill(&state, ctx.user_id, MEMBER_BADGE, &live).await? {
            for (member, item) in &filled.items {
                badges.entry(member.to_string()).or_default().push(Badge {
                    module_id: filled.module_id.clone(),
                    name: filled.slot.name.clone(),
                    nodes: item.nodes.clone(),
                    fallback: item.fallback.clone(),
                });
            }
        }
    }
    Ok(Json(BadgesResponse { badges }))
}

fn parse_user(raw: &str) -> Result<UserId, ApiError> {
    super::messages::parse_uuid(raw).map(UserId)
}

fn parse_ids(raw: &str) -> Result<Vec<UserId>, ApiError> {
    let parts: Vec<&str> = raw
        .split(',')
        .map(str::trim)
        .filter(|p| !p.is_empty())
        .collect();
    if parts.len() > MAX_BADGE_IDS {
        return Err(ApiError::BadRequest("ids takes at most 100 user ids"));
    }
    let mut ids = Vec::with_capacity(parts.len());
    for part in parts {
        let id = parse_user(part)?;
        if !ids.contains(&id) {
            ids.push(id);
        }
    }
    Ok(ids)
}

/// Every enabled module's slot of `kind`, filled for `members`.
async fn fill(
    state: &AppState,
    viewer: UserId,
    kind: &str,
    members: &[UserId],
) -> Result<Vec<Filled>, ApiError> {
    let mut out = Vec::new();
    for module in state.store.list_installed_modules().await? {
        if !module.enabled || module.addon_api < 1 {
            continue;
        }
        for slot in module.slots.iter().filter(|s| s.kind == kind) {
            let items = items_for(state, &module, slot, viewer, members).await;
            out.push(Filled {
                module_id: module.id.clone(),
                slot: slot.clone(),
                items,
            });
        }
    }
    Ok(out)
}

/// Cached items first; one module run covers every member the cache lacks.
async fn items_for(
    state: &AppState,
    module: &InstalledModule,
    slot: &ModuleSlot,
    viewer: UserId,
    members: &[UserId],
) -> HashMap<UserId, SlotItem> {
    let cache = state.dock.slot_cache();
    let key = |member: UserId| SlotKey {
        module_id: module.id.clone(),
        artifact_sha256: module.artifact_sha256.clone(),
        kind: slot.kind.clone(),
        name: slot.name.clone(),
        viewer,
        member,
    };
    let mut found = HashMap::new();
    let mut missing = Vec::new();
    for member in members {
        match cache.get(&key(*member), Instant::now()) {
            Some(Some(item)) => {
                found.insert(*member, item);
            }
            Some(None) => {}
            None => missing.push(*member),
        }
    }
    if missing.is_empty() {
        return found;
    }
    let generation = cache.generation(&module.id);
    let Some(mut fresh) = run_slot(state, module, slot, viewer, &missing).await else {
        return found;
    };
    for member in missing {
        let item = fresh.remove(&member);
        cache.put(key(member), item.clone(), (Instant::now(), generation));
        if let Some(item) = item {
            found.insert(member, item);
        }
    }
    found
}

/// The run's `input`: which slot, for whom, and who is looking.
fn slot_input(slot: &ModuleSlot, members: &[UserId], viewer: UserId) -> String {
    json!({
        "slot": slot.kind,
        "name": slot.name,
        "user_ids": members.iter().map(ToString::to_string).collect::<Vec<_>>(),
        "viewer_id": viewer.to_string(),
    })
    .to_string()
}

/// Runs the module for `members` in the slot lane; a failure yields nothing to cache.
/// `None` means it never ran (the viewer has a fill going, or the lane was full), so nothing is cached either.
async fn run_slot(
    state: &AppState,
    module: &InstalledModule,
    slot: &ModuleSlot,
    viewer: UserId,
    members: &[UserId],
) -> Option<HashMap<UserId, SlotItem>> {
    let _fill = state.dock.slot_cache().begin_fill(viewer)?;
    let input = slot_input(slot, members, viewer);
    let surface = super::module_host::surface_for(state, module, viewer, None);
    let request = RunRequest {
        caller: viewer,
        command: SLOT_COMMAND,
        input: &input,
        kind: RunKind::Slot,
    };
    let outcome = match run_installed(state, module, &request, surface).await {
        Ok(outcome) if super::module_breaker::was_turned_away(&outcome) => return None,
        Ok(outcome) => outcome,
        Err(_) => return Some(HashMap::new()),
    };
    if !outcome.ok {
        return Some(HashMap::new());
    }
    if let Some(items) = parse_response(&outcome.payload, members) {
        return Some(items);
    }
    let junk = RunResult::Failed("the module's slot response was not slot/1".into());
    if let Err(err) = state
        .store
        .record_module_run(&module.id, SLOT_COMMAND, &junk, (now_ms(), 0))
        .await
    {
        tracing::warn!(%err, module = %module.id, "could not record a module run");
    }
    Some(HashMap::new())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_run_input_names_the_slot_the_members_and_the_viewer() {
        let (ada, bob, viewer) = (UserId::generate(), UserId::generate(), UserId::generate());
        let slot = ModuleSlot {
            kind: MEMBER_BADGE.into(),
            name: "level".into(),
            title: None,
        };
        let input: Value = serde_json::from_str(&slot_input(&slot, &[ada, bob], viewer)).unwrap();
        assert_eq!(
            input,
            json!({
                "slot": "member.badge",
                "name": "level",
                "user_ids": [ada.to_string(), bob.to_string()],
                "viewer_id": viewer.to_string(),
            })
        );
    }
}
