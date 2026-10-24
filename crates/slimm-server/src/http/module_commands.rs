// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Runs an installed module's command, per docs/decisions/0021-modules-and-
//! the-dock.md's Phase 3. This is the one route that ever executes a
//! module: everything it decides before handing off to
//! `crate::module_runtime::ModuleHost` is gating, never behavior - slim has
//! no notion of what any command actually does.
//!
//! The wire shapes here (`{ "input": ... }` in, `{ "ok", "output" / "error" }`
//! out) are exactly the module ABI's own request/response JSON (see
//! `module_runtime`'s doc), plus the `command` name this route already knows
//! from the path. A run that fails for a host reason - a resource limit, a
//! malformed module response, a missing artifact - still answers 200 with
//! `{ "ok": false, "error": ... }`: only the gating checks below (is it
//! installed, enabled, does the caller hold its permission) use a distinct
//! status code, because those are refusals to even attempt the call rather
//! than an outcome of attempting it.
//!
//! `GET /modules/code-block-runners` lives here too: the general mechanism a
//! client uses to learn whether it may offer "Run" on a fenced code block,
//! per docs/decisions/0021-modules-and-the-dock.md's module-agnostic
//! principle. slim has no notion of "code execution" anywhere in this file -
//! it only surfaces, per caller, which installed and enabled module declared
//! a `code-block-runner` extension point the caller holds the permission
//! for. A deployment with no such module installed answers an empty list.
//!
//! [`CODE_RUNNER_MODULE_ID`] is the one reserved exception: on both run
//! routes, that exact `module_id` is never looked up in the module store at
//! all and instead reaches [`execute_code_runner`], the broker for this
//! deployment's optional Piston-compatible code runner (`crate::code_runner`,
//! docs/decisions/0026). It rides the same routes and the same discovery
//! list deliberately, per that decision's "reuse discovery, do not invent a
//! parallel one" - a client never needs to know the difference between an
//! installed module and this deployment's runner broker.

use axum::Router;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::routing::{get, post};
use serde::{Deserialize, Serialize};

use super::AppState;
use super::dock::validate_module_id;
use super::error::ApiError;
use super::extract::{AUTHED_READ, AuthedLimited, Json, MODULE};
use super::module_host;
use crate::ids::{ChannelId, MessageId, UserId};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{InstalledModule, ModuleExtensionPoint};

/// A command name is compared verbatim against a module's own persisted
/// extension points, never used as a path or SQL fragment, so this bounds
/// only how much of a caller-supplied string this route will look at before
/// giving up on a match.
const MAX_COMMAND_LEN: usize = 64;
/// A command's `input` is a whole snippet, not a short field, so this is
/// sized well above the other small write bodies in this crate - the real
/// ceiling on what a module can do with it is its own `runtime.limits`, not
/// this transport cap.
const BODY_LIMIT: usize = 256 * 1024;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/modules/{moduleId}/commands/{command}", post(run_command))
        .route("/modules/code-block-runners", get(list_code_block_runners))
        .route("/modules/slash-commands", get(list_slash_commands))
        .layer(DefaultBodyLimit::max(BODY_LIMIT))
}

#[derive(Deserialize)]
struct RunCommandRequest {
    input: String,
    /// The channel the command was invoked from (a slash command's channel).
    /// Without it the run is not offered `message.post`.
    #[serde(default)]
    channel_id: Option<String>,
    /// Post the output into `channel_id` as the member, labelled as the
    /// module's, instead of handing it back. Needs `channel_id`.
    #[serde(default)]
    post_output: bool,
    /// The message the posted output replies to; only with `post_output`.
    #[serde(default)]
    reply_to_id: Option<String>,
}

/// The module ABI's own response shape, echoed straight through: see
/// `module_runtime`'s doc for why this route trusts it no further than
/// requiring it to actually be this shape.
#[derive(Serialize)]
struct RunCommandResponse {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    output: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
    /// The message the output was posted as, when `post_output` was asked for.
    #[serde(skip_serializing_if = "Option::is_none")]
    message_id: Option<String>,
}

impl RunCommandResponse {
    fn failure(error: impl Into<String>) -> Self {
        Self {
            ok: false,
            output: None,
            error: Some(error.into()),
            message_id: None,
        }
    }
}

fn validate_command_name(name: &str) -> Result<(), ApiError> {
    if name.is_empty() || name.len() > MAX_COMMAND_LEN {
        return Err(ApiError::BadRequest("invalid command name"));
    }
    Ok(())
}

/// The command's required permission key, from the module's own persisted
/// extension points. `None` when no `command` extension point named
/// `command` exists at all - the caller gets 404, the same as an unknown
/// module.
fn required_permission<'a>(module: &'a InstalledModule, command: &str) -> Option<&'a str> {
    module
        .extension_points
        .iter()
        .find(|e| e.kind == "command" && e.name == command)
        .and_then(|e| e.permission.as_deref())
}

/// A command's result: `ok` plus a single payload - the module's output when
/// ok, or an error message when not. A refusal to even attempt the run (not
/// installed, not enabled, no permission) is an [`ApiError`] instead; a
/// host-level failure while running is `Ok` with `ok: false`, the same split
/// [`run_command`]'s own doc explains.
pub(crate) struct CommandOutcome {
    pub(crate) ok: bool,
    pub(crate) payload: String,
    /// The host could not run the module (a limit, a trap, a bad response), as
    /// opposed to the module answering with an error of its own.
    pub(crate) host_failed: bool,
}

impl CommandOutcome {
    pub(crate) fn host_failure(payload: String) -> Self {
        Self {
            ok: false,
            payload,
            host_failed: true,
        }
    }
}

/// Gates and runs `command` on `module_id` for `user_id`, the one place a
/// module is ever executed. Shared by [`run_command`] (the generic route) and
/// the message-scoped code-block run (`super::code_runs`), so both apply the
/// exact same install/enable/permission checks before `ModuleHost::run`.
///
/// The run is untrusted: `input` is not necessarily the invoker's own (a code
/// block's text is whoever wrote the message), so it is offered no
/// `message.post`. Use [`execute_command_in`] for a command the invoker typed.
pub(crate) async fn execute_command(
    state: &AppState,
    user_id: UserId,
    module_id: &str,
    command: &str,
    input: &str,
) -> Result<CommandOutcome, ApiError> {
    execute_command_in(state, user_id, module_id, command, input, None).await
}

/// [`execute_command`] for a command the invoker composed themselves in
/// `channel`, which is the only channel a `message.post` may target.
pub(crate) async fn execute_command_in(
    state: &AppState,
    user_id: UserId,
    module_id: &str,
    command: &str,
    input: &str,
    channel: Option<ChannelId>,
) -> Result<CommandOutcome, ApiError> {
    validate_module_id(module_id)?;
    validate_command_name(command)?;

    let module = state
        .store
        .installed_module(module_id)
        .await?
        .ok_or(ApiError::NotFound("module not installed"))?;
    if !module.enabled {
        return Err(ApiError::Conflict("module is not enabled"));
    }
    let permission = required_permission(&module, command)
        .ok_or(ApiError::NotFound("module declares no such command"))?;
    if !state
        .store
        .user_has_module_permission(user_id, module_id, permission)
        .await?
    {
        return Err(ApiError::Forbidden);
    }
    let surface = module_host::surface_for(state, &module, user_id, channel);
    let request = super::module_run::RunRequest {
        caller: user_id,
        command,
        input,
        kind: super::module_run::RunKind::Command,
    };
    super::module_run::run_installed(state, &module, &request, surface).await
}

/// The reserved `module_id` this deployment's code-runner broker
/// (`crate::code_runner`) answers to, on the exact same routes an installed
/// module's command would use - see this file's own module doc. Not a real
/// installable module: [`execute_code_runner`] never reaches the module store
/// for it, and [`super::dock::validate_module_id`] refuses this id on install,
/// so a marketplace listing can never shadow or be shadowed by it.
pub(crate) const CODE_RUNNER_MODULE_ID: &str = "code-runner";

/// Runs `code` as `language` through this deployment's configured code
/// runner, gated on [`Permissions::RUN_CODE`] and charged
/// [`Class::CodeRunner`] - the runner-broker analogue of [`execute_command`],
/// used instead of it whenever a caller names [`CODE_RUNNER_MODULE_ID`].
///
/// `permissions` is resolved by the caller against its own context: the
/// message-scoped run route (`super::code_runs`) evaluates it per channel,
/// the same set it already computed for its `VIEW_CHANNEL` check, while this
/// file's own generic route has no channel to evaluate against and uses the
/// caller's base (guild-level) permissions instead - mirroring how a plain
/// module permission is never channel-scoped either.
pub(crate) async fn execute_code_runner(
    state: &AppState,
    permissions: Permissions,
    user_id: UserId,
    language: &str,
    code: &str,
) -> Result<CommandOutcome, ApiError> {
    if !state.code_runner.is_enabled() {
        return Err(ApiError::NotFound(
            "no code runner is configured for this deployment",
        ));
    }
    if !permissions.contains(Permissions::RUN_CODE) {
        return Err(ApiError::Forbidden);
    }
    // An authenticated key, mirroring `extract::limit_key`'s own branch for one.
    state
        .limiter
        .admit(Class::CodeRunner, &format!("u:{user_id}"))?;

    let outcome = state.code_runner.run(language, code).await;
    Ok(CommandOutcome {
        ok: outcome.ok,
        payload: outcome.payload,
        host_failed: false,
    })
}

async fn run_command(
    AuthedLimited(ctx): AuthedLimited<MODULE>,
    State(state): State<AppState>,
    Path((module_id, command)): Path<(String, String)>,
    Json(req): Json<RunCommandRequest>,
) -> Result<Json<RunCommandResponse>, ApiError> {
    let outcome = if module_id == CODE_RUNNER_MODULE_ID {
        let permissions = state.store.base_permissions(ctx.user_id).await?;
        execute_code_runner(&state, permissions, ctx.user_id, &command, &req.input).await?
    } else {
        let channel = req
            .channel_id
            .as_deref()
            .map(|raw| super::messages::parse_uuid(raw).map(ChannelId))
            .transpose()?;
        execute_command_in(
            &state,
            ctx.user_id,
            &module_id,
            &command,
            &req.input,
            channel,
        )
        .await?
    };
    let response = if !outcome.ok {
        RunCommandResponse::failure(outcome.payload)
    } else if req.post_output && module_id != CODE_RUNNER_MODULE_ID {
        post_output(&state, ctx.user_id, (&module_id, &req), &outcome.payload).await?
    } else {
        RunCommandResponse {
            ok: true,
            output: Some(outcome.payload),
            error: None,
            message_id: None,
        }
    };
    Ok(Json(response))
}

/// Posts a successful command's output as the member, labelled as the module's.
async fn post_output(
    state: &AppState,
    user_id: UserId,
    (module_id, req): (&str, &RunCommandRequest),
    output: &str,
) -> Result<RunCommandResponse, ApiError> {
    let channel = req
        .channel_id
        .as_deref()
        .ok_or(ApiError::BadRequest("post_output needs a channel_id"))?;
    let channel = ChannelId(super::messages::parse_uuid(channel)?);
    let reply_to = req
        .reply_to_id
        .as_deref()
        .map(|raw| super::messages::parse_uuid(raw).map(MessageId))
        .transpose()?;
    if output.trim().is_empty() {
        return Ok(RunCommandResponse {
            ok: true,
            output: Some(String::new()),
            error: None,
            message_id: None,
        });
    }
    let module = state
        .store
        .installed_module(module_id)
        .await?
        .ok_or(ApiError::NotFound("module not installed"))?;
    Ok(
        match module_host::post_command_output(
            state,
            &module,
            (user_id, channel),
            (output, reply_to),
        )
        .await
        {
            Ok(id) => RunCommandResponse {
                ok: true,
                output: None,
                error: None,
                message_id: Some(id.to_string()),
            },
            Err(refused) => RunCommandResponse::failure(refused.0),
        },
    )
}

/// One `(module_id, command)` pair a client may `POST` to
/// `/modules/{moduleId}/commands/{command}` to run a fenced code block.
#[derive(Serialize)]
struct CodeBlockRunnerDto {
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
struct SlashCommandDto {
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
pub(super) struct ModuleInfoDto {
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
pub(super) struct Reachable {
    pub(super) module_id: String,
    pub(super) command: String,
    pub(super) point: ModuleExtensionPoint,
    pub(super) module: ModuleInfoDto,
}

/// Every extension point of `kind` the caller may currently reach: declared by
/// an installed, enabled module, naming both a `command` and a `permission`,
/// and the caller holds that permission. The one discovery loop behind the
/// slash-command, code-block-runner and app lists (decision 0021's
/// module-agnostic principle: a client learns what to offer from here, never
/// from a hardcoded module id), so a new kind reuses it rather than copying it.
pub(super) async fn reachable_extension_points(
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
async fn list_slash_commands(
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
async fn list_code_block_runners(
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
