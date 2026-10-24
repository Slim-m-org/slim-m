// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which host capabilities an install approves (decision 0023), split out of
//! `dock.rs` to hold the file budget.

use super::Manifest;
use super::manifest::NET_FETCH;
use crate::http::AppState;
use crate::http::error::ApiError;
use crate::http::module_host;
use crate::store::ModuleSchedule;

/// What an install that named no approvals keeps: the module's current host
/// capabilities that the new manifest still declares, except the ones whose
/// power a new build or a changed manifest could widen unseen: `message.post`,
/// `net.fetch`, `schedule`, `events`, `data.store` and `log.read` after a new build, `net.fetch` when its hosts
/// changed, `schedule` when its commands or intervals did, `events` when a subscription was added and
/// `data.store` when its cap grew or a table was added. Nothing is added.
pub(super) async fn carried_host_capabilities(
    state: &AppState,
    manifest: &Manifest,
) -> Result<Vec<String>, ApiError> {
    let Some(current) = state.store.installed_module(&manifest.id).await? else {
        return Ok(Vec::new());
    };
    // A new build gets no unseen power to post, dial out or run on a timer.
    let same_build = current.artifact_sha256 == manifest.artifact.sha256;
    let same_hosts = current.network_hosts == manifest.network.hosts;
    let same_schedules = same_schedules(&current.schedules, manifest);
    let no_new_subscriptions = manifest
        .platform
        .subscriptions
        .iter()
        .all(|s| current.subscriptions.contains(s));
    let data_not_widened = data_not_widened(&current.data_schema, manifest);
    Ok(current
        .approved_host_capabilities
        .into_iter()
        .filter(|c| manifest.capabilities.contains(c))
        .filter(|c| same_build || !REASKED_ON_NEW_BUILD.contains(&c.as_str()))
        .filter(|c| same_hosts || c != NET_FETCH)
        .filter(|c| same_schedules || c != "schedule")
        .filter(|c| no_new_subscriptions || c != "events")
        .filter(|c| data_not_widened || c != "data.store")
        .collect())
}

/// Capabilities whose approval does not survive a new artifact.
const REASKED_ON_NEW_BUILD: [&str; 6] = [
    "message.post",
    NET_FETCH,
    "schedule",
    "events",
    "data.store",
    "log.read",
];

/// Whether the manifest's `data` asks for no more than the approved one: not a larger cap, no new table or column, no newly unique or indexed column.
fn data_not_widened(current: &serde_json::Value, manifest: &Manifest) -> bool {
    let Some(wanted) = &manifest.data else {
        return true;
    };
    let Ok(had) = crate::module_runtime::validate_data_schema(current) else {
        return false;
    };
    wanted.max_mb <= had.max_mb
        && wanted.tables.iter().all(|t| {
            had.table(&t.name).is_some_and(|old| {
                t.columns.iter().all(|c| {
                    old.column(&c.name)
                        .is_some_and(|o| (o.unique || !c.unique) && (o.index || !c.index))
                })
            })
        })
}

fn same_schedules(current: &[ModuleSchedule], manifest: &Manifest) -> bool {
    let mut had: Vec<(&str, u32)> = current
        .iter()
        .map(|s| (s.command.as_str(), s.every_minutes))
        .collect();
    let mut now: Vec<(&str, u32)> = manifest
        .schedules
        .iter()
        .map(|s| (s.command.as_str(), s.every_minutes))
        .collect();
    had.sort_unstable();
    now.sort_unstable();
    had == now
}

/// `requested`, deduplicated, if every entry is a capability the manifest
/// declared and this host implements; anything else refuses the install rather
/// than quietly approving less than the admin asked for.
pub(super) fn approvable_host_capabilities(
    manifest: &Manifest,
    requested: &[String],
) -> Result<Vec<String>, ApiError> {
    let mut approved: Vec<String> = Vec::new();
    for capability in requested {
        let implemented = module_host::HOST_CAPABILITIES.contains(&capability.as_str());
        if !implemented || !manifest.capabilities.contains(capability) {
            return Err(ApiError::BadRequest(
                "cannot approve a capability the module does not declare or the host does not implement",
            ));
        }
        if !approved.contains(capability) {
            approved.push(capability.clone());
        }
    }
    Ok(approved)
}

/// Whether local network addresses are approved: only with `net.fetch`
/// approved and a manifest that asked for them. Omitted keeps an earlier
/// approval for the same hosts; asking for it where it cannot apply is refused.
pub(super) async fn local_network_approval(
    state: &AppState,
    manifest: &Manifest,
    approved_host: &[String],
    requested: Option<bool>,
) -> Result<bool, ApiError> {
    let applies = manifest.network.local && approved_host.iter().any(|c| c == NET_FETCH);
    match requested {
        Some(true) if !applies => Err(ApiError::BadRequest(
            "local network approval needs net.fetch approved and a manifest that asks for local addresses",
        )),
        Some(approved) => Ok(approved),
        None if !applies => Ok(false),
        None => Ok(state
            .store
            .installed_module(&manifest.id)
            .await?
            .is_some_and(|m| {
                m.local_network_approved && m.network_hosts == manifest.network.hosts
            })),
    }
}
