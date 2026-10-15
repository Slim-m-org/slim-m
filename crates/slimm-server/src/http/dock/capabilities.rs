// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which host capabilities an install approves (decision 0023), split out of
//! `dock.rs` to hold the file budget.

use super::Manifest;
use super::manifest::NET_FETCH;
use crate::http::AppState;
use crate::http::error::ApiError;
use crate::http::module_host;

/// What an install that named no approvals keeps: the module's current host
/// capabilities that the new manifest still declares, except `message.post`
/// when the artifact changed and `net.fetch` when its hosts changed. Nothing
/// is added.
pub(super) async fn carried_host_capabilities(
    state: &AppState,
    manifest: &Manifest,
) -> Result<Vec<String>, ApiError> {
    let Some(current) = state.store.installed_module(&manifest.id).await? else {
        return Ok(Vec::new());
    };
    // A new build gets no unseen power to post: message.post must be approved again.
    let same_build = current.artifact_sha256 == manifest.artifact.sha256;
    let same_hosts = current.network_hosts == manifest.network.hosts;
    Ok(current
        .approved_host_capabilities
        .into_iter()
        .filter(|c| manifest.capabilities.contains(c))
        .filter(|c| same_build || c != "message.post")
        .filter(|c| same_hosts || c != NET_FETCH)
        .collect())
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
