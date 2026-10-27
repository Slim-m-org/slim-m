// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The discovery lists behind `GET /modules/slash-commands` and
//! `/modules/code-block-runners`: what the caller may currently offer.

use axum::extract::State;
use serde::Serialize;

use super::CODE_RUNNER_MODULE_ID;
use crate::http::AppState;
use crate::http::error::ApiError;
use crate::http::extract::{AUTHED_READ, AuthedLimited, Json};
use crate::http::module_host;
use crate::ids::UserId;
use crate::permissions::Permissions;
use crate::store::{InstalledModule, ModuleExtensionPoint};

/// One `(module_id, command)` pair a client may `POST` to
/// `/modules/{moduleId}/commands/{command}` to run a fenced code block.
#[derive(Serialize)]
pub(super) struct CodeBlockRunnerDto {
    module_id: String,
    command: String,
    /// The fenced-block language this runner matches, or absent for a
    /// wildcard the client offers on any block (a module installed before
    /// this field existed, or one that deliberately declares none). The
    /// client normalizes case and applies its own small alias map (js ->
    /// javascript, and so on) before comparing this against a block's own
    /// fence tag.
    #[serde(skip_serializing_if = "Option::is_none")]
    language: Option<String>,
}

/// One `slash-command` extension point a client may offer in the composer and
/// `POST` to `/modules/{moduleId}/commands/{command}`. Unlike a code-block
/// runner it carries its own `name` (the slash keyword the composer offers,
/// e.g. `roll`) and `description`, since a slash command is chosen by name
/// from a list rather than matched to a block's language.
#[derive(Serialize)]
pub(super) struct SlashCommandDto {
    module_id: String,
    command: String,
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    /// Which module provides it and what that module is allowed to do.
    module: ModuleInfoDto,
}

/// What a member is told about the module behind a command: its name, whether
/// it came from the official registry, and the host powers an admin approved.
#[derive(Serialize, Clone)]
pub(in crate::http) struct ModuleInfoDto {
    name: String,
    verified: bool,
    /// Approved host capabilities (`kv.store`, `message.post`, `net.fetch`, `schedule`).
    capabilities: Vec<String>,
    /// The sites `net.fetch` may reach; empty without it.
    network_hosts: Vec<String>,
}

impl ModuleInfoDto {
    fn of(module: &InstalledModule) -> Self {
        let capabilities = module_host::effective_capabilities(module);
        let network_hosts = if capabilities.iter().any(|c| c == "net.fetch") {
            module.network_hosts.clone()
        } else {
            Vec::new()
        };
        Self {
            name: module.name.clone(),
            verified: module.source_repo.is_none(),
            capabilities,
            network_hosts,
        }
    }
}

/// One extension point the caller may currently reach, with the module it
/// belongs to and the `command` it invokes already pulled out, since every
/// discovery list hands exactly that pair to a client.
pub(in crate::http) struct Reachable {
    pub(in crate::http) module_id: String,
    pub(in crate::http) command: String,
    pub(in crate::http) point: ModuleExtensionPoint,
    pub(in crate::http) module: ModuleInfoDto,
}

/// Every extension point of `kind` the caller may currently reach: declared by
/// an installed, enabled module, naming both a `command` and a `permission`,
/// and the caller holds that permission. The one discovery loop behind the
/// slash-command, code-block-runner and app lists (decision 0021's
/// module-agnostic principle: a client learns what to offer from here, never
/// from a hardcoded module id), so a new kind reuses it rather than copying it.
pub(in crate::http) async fn reachable_extension_points(
    state: &AppState,
    user_id: UserId,
    kind: &str,
) -> Result<Vec<Reachable>, ApiError> {
    // One role load for the whole sweep, not one per extension point.
    let held = state.store.held_module_permissions(user_id).await?;
    let mut reachable = Vec::new();
    for module in state.store.list_installed_modules().await? {
        if !module.enabled {
            continue;
        }
        let info = ModuleInfoDto::of(&module);
        for point in module.extension_points {
            if point.kind != kind {
                continue;
            }
            let (Some(command), Some(permission)) = (&point.command, &point.permission) else {
                continue;
            };
            if held.contains(&(module.id.clone(), permission.clone())) {
                reachable.push(Reachable {
                    module_id: module.id.clone(),
                    command: command.clone(),
                    point,
                    module: info.clone(),
                });
            }
        }
    }
    Ok(reachable)
}

/// Every `slash-command` extension point the caller may currently reach:
/// installed, enabled, and the caller holds the permission it declared. This
/// is how a client learns which `/name` commands to offer in the composer -
/// never a hardcoded module id, per docs/decisions/0021's module-agnostic
/// principle. Possibly empty.
pub(super) async fn list_slash_commands(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<SlashCommandDto>>, ApiError> {
    let commands = reachable_extension_points(&state, ctx.user_id, "slash-command")
        .await?
        .into_iter()
        .map(|r| SlashCommandDto {
            module_id: r.module_id,
            command: r.command,
            name: r.point.name,
            description: r.point.description,
            module: r.module,
        })
        .collect();
    Ok(Json(commands))
}

/// Every `code-block-runner` extension point the caller may currently reach:
/// installed, enabled, and the caller holds the permission it declared. This
/// is the whole of how a client learns whether to offer "Run" on a fenced
/// code block - never a hardcoded module id, per docs/decisions/0021's
/// module-agnostic principle. Possibly empty, which means no Run affordance
/// anywhere in the client.
///
/// Also lists one entry per language this deployment's configured code
/// runner currently declares (`CodeRunner::languages`, per decision 0026),
/// under the reserved [`CODE_RUNNER_MODULE_ID`] - but only when the broker is
/// configured at all and the caller holds [`Permissions::RUN_CODE`], so an
/// unconfigured or ungranted runner adds nothing here, the same clean-no-op
/// posture the module list already has.
pub(super) async fn list_code_block_runners(
    AuthedLimited(ctx): AuthedLimited<AUTHED_READ>,
    State(state): State<AppState>,
) -> Result<Json<Vec<CodeBlockRunnerDto>>, ApiError> {
    let mut runners: Vec<CodeBlockRunnerDto> =
        reachable_extension_points(&state, ctx.user_id, "code-block-runner")
            .await?
            .into_iter()
            .map(|r| CodeBlockRunnerDto {
                module_id: r.module_id,
                command: r.command,
                language: r.point.language,
            })
            .collect();

    if state.code_runner.is_enabled() {
        let permissions = state.store.base_permissions(ctx.user_id).await?;
        if permissions.contains(Permissions::RUN_CODE) {
            for language in state.code_runner.languages().await {
                runners.push(CodeBlockRunnerDto {
                    module_id: CODE_RUNNER_MODULE_ID.to_owned(),
                    command: language.clone(),
                    language: Some(language),
                });
            }
        }
    }
    Ok(Json(runners))
}
