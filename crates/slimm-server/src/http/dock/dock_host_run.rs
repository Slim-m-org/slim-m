// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Dock's side of host-run connectors (decision 0134): what the admin approves at
//! install, and the status and recent log lines admins see. A sibling of `dock_connector`,
//! so the connector page's own changes and these stay apart.

use axum::Router;
use axum::extract::{Path, State};
use axum::http::request::Parts;
use axum::routing::get;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::validate_module_id;
use crate::http::AppState;
use crate::http::connector_host::client::LogLine;
use crate::http::connector_host::lifecycle::{self, NOT_SET_UP, UNAVAILABLE};
use crate::http::connector_host::{Health, HostRun};
use crate::http::error::ApiError;
use crate::http::extract::{Authed, Json, Query, enforce, require_manage_server};
use crate::ids::UserId;
use crate::ratelimit::Class;
use crate::store::{EgressHost, HostRunSpec};

const UPDATE_THE_APP: &str =
    "this connector asks to be run by the host, which this app cannot show; update the app";
const DEFAULT_TAIL: u32 = 200;
const MAX_TAIL: u32 = 1000;

pub(super) fn routes() -> Router<AppState> {
    Router::new()
        .route("/space/dock/connector-runtime", get(runtime_status))
        .route("/space/dock/modules/{id}/host-run", get(status))
        .route("/space/dock/modules/{id}/host-run/logs", get(logs))
}

/// What the admin approved of a host-run ask: a subset of its egress, and the Private
/// network approval only if it asked for one.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct HostRunApproval {
    #[serde(default)]
    egress: Vec<EgressHost>,
    #[serde(default)]
    egress_private: bool,
}

/// Checks a host-run install before anything is stored; answers the runner and the spec to store.
pub(super) fn approve(
    state: &AppState,
    asked: &HostRunSpec,
    approval: Option<&HostRunApproval>,
) -> Result<(HostRun, HostRunSpec), ApiError> {
    let runner = state.dock.host_run().ok_or(NOT_SET_UP)?;
    let approval = approval.ok_or(ApiError::BadRequest(UPDATE_THE_APP))?;
    let mut egress = Vec::with_capacity(approval.egress.len());
    for pair in &approval.egress {
        let host = super::manifest::connector::host_run::normalize_host(&pair.host);
        let pair = EgressHost {
            host: host.unwrap_or_default(),
            port: pair.port,
        };
        if !asked.egress.contains(&pair) {
            return Err(ApiError::BadRequest(
                "a connector can only be approved egress hosts it asks for",
            ));
        }
        if !egress.contains(&pair) {
            egress.push(pair);
        }
    }
    if approval.egress_private && !asked.egress_private {
        return Err(ApiError::BadRequest(
            "this connector did not ask for the Private network",
        ));
    }
    runner.require_available()?;
    if let Health::Up(hello) = runner.health() {
        check_against_operator(asked, &hello)?;
        if approval.egress_private && hello["private_network"] == Value::Bool(false) {
            return Err(ApiError::BadRequest(
                "this server cannot grant the Private network until its operator lists the docker host's own addresses in SLIMM_SUPERVISOR_LAN_DENY",
            ));
        }
    }
    let approved = HostRunSpec {
        egress,
        egress_private: approval.egress_private,
        ..asked.clone()
    };
    Ok((runner, approved))
}

/// The operator's registries and ceilings, checked here so the refusal reaches the admin at install.
fn check_against_operator(asked: &HostRunSpec, hello: &Value) -> Result<(), ApiError> {
    let registries: Vec<&str> = hello["registries"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    if !registries.is_empty() && !registries.iter().any(|p| asked.image.starts_with(p)) {
        return Err(ApiError::BadRequestDetail(format!(
            "this server only runs connector images from {}",
            registries.join(", ")
        )));
    }
    let ceilings = &hello["ceilings"];
    let over = |asked: Option<f64>, key: &str| {
        asked
            .zip(ceilings[key].as_f64())
            .is_some_and(|(a, max)| a > max)
    };
    if over(asked.memory_mib.map(|m| m as f64), "max_memory_mib")
        || over(asked.cpus, "max_cpus")
        || over(asked.pids.map(|p| p as f64), "max_pids")
        || (asked.volume && over(asked.volume_mib.map(|v| v as f64), "max_volume_mib"))
    {
        return Err(ApiError::BadRequestDetail(
            "this connector asks for more memory, CPU, processes or storage than this server allows"
                .to_owned(),
        ));
    }
    Ok(())
}

/// Stores the approved spec and asks the supervisor to build it; failures show on the connector.
pub(super) async fn after_store_install(
    state: &AppState,
    runner: &HostRun,
    module_id: &str,
    spec: &HostRunSpec,
) -> Result<(), ApiError> {
    let record = state.store.upsert_host_run(module_id, spec).await?;
    runner.forget_crashes(module_id);
    lifecycle::after_install(state, runner, &record).await;
    Ok(())
}

#[derive(Serialize)]
pub(in crate::http) struct HostRunAskDto {
    image: String,
    egress: Vec<EgressHost>,
    egress_private: bool,
    volume: bool,
    limits: LimitsDto,
}

#[derive(Serialize)]
struct LimitsDto {
    #[serde(skip_serializing_if = "Option::is_none")]
    memory_mib: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cpus: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pids: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    volume_mib: Option<i64>,
}

impl HostRunAskDto {
    pub(in crate::http) fn of(spec: &HostRunSpec) -> Self {
        Self {
            image: spec.image.clone(),
            egress: spec.egress.clone(),
            egress_private: spec.egress_private,
            volume: spec.volume,
            limits: LimitsDto {
                memory_mib: spec.memory_mib,
                cpus: spec.cpus,
                pids: spec.pids,
                volume_mib: spec.volume_mib,
            },
        }
    }
}

#[derive(Serialize)]
struct RuntimeDto {
    configured: bool,
    available: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    detail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    runtime: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    registries: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    ceilings: Option<Value>,
}

/// Whether this server can run connectors, so the Dock offers host-run installs only then.
async fn runtime_status(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
) -> Result<Json<RuntimeDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    let Some(runner) = state.dock.host_run() else {
        return Ok(Json(RuntimeDto {
            configured: false,
            available: false,
            detail: None,
            runtime: None,
            registries: None,
            ceilings: None,
        }));
    };
    let hello = match runner.health() {
        Health::Up(hello) => Some(hello),
        _ => None,
    };
    let field = |key: &str| hello.as_ref().map(|h| h[key].clone());
    Ok(Json(RuntimeDto {
        configured: true,
        available: runner.unavailable_reason().is_none(),
        detail: runner.unavailable_reason(),
        runtime: field("runtime"),
        registries: field("registries"),
        ceilings: field("ceilings"),
    }))
}

#[derive(Serialize)]
struct StatusDto {
    state: &'static str,
    #[serde(flatten)]
    ask: HostRunAskDto,
    #[serde(skip_serializing_if = "Option::is_none")]
    exit_code: Option<i64>,
    oom_killed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    started_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    finished_at: Option<String>,
    restarts: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    last_error: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    volume_bytes: Option<u64>,
}

/// A host-run connector's state for admins: running, stopped, crashed, disabled after
/// crashes, refused, starting or runtime unavailable.
async fn status(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(id): Path<String>,
) -> Result<Json<StatusDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    validate_module_id(&id)?;
    let record = state
        .store
        .host_run(&id)
        .await?
        .ok_or(ApiError::NotFound("this connector is not run by the host"))?;
    let runner = state.dock.host_run();
    let unavailable = runner.as_ref().map_or_else(
        || Some("the connector supervisor is not configured".to_owned()),
        |r| r.unavailable_reason(),
    );
    let listed = match (&runner, &unavailable) {
        (Some(runner), None) => runner
            .client
            .list()
            .await
            .ok()
            .and_then(|l| l.into_iter().find(|c| c.id == record.run_id)),
        _ => None,
    };
    let state_name = match (
        &record,
        &unavailable,
        listed.as_ref().map(|l| l.state.as_str()),
    ) {
        (r, _, _) if r.crash_disabled_at.is_some() => "disabled_after_crashes",
        (_, Some(_), _) => "runtime_unavailable",
        (r, _, _) if r.refused => "refused",
        (r, _, _) if !r.enabled => "stopped",
        (_, _, Some("running")) => "running",
        (_, _, Some("exited")) => "crashed",
        _ => "starting",
    };
    let listed = listed.unwrap_or_else(|| crate::http::connector_host::client::Listed {
        id: record.run_id.clone(),
        state: String::new(),
        exit_code: None,
        oom_killed: false,
        started_at: None,
        finished_at: None,
        image: None,
        volume_bytes: None,
        volume_over_limit: false,
    });
    Ok(Json(StatusDto {
        state: state_name,
        ask: HostRunAskDto::of(&record.spec),
        exit_code: listed.exit_code,
        oom_killed: listed.oom_killed,
        started_at: listed.started_at,
        finished_at: listed.finished_at,
        restarts: runner.as_ref().map_or(0, |r| r.restarts(&id)),
        last_error: record.last_error.or(unavailable),
        volume_bytes: listed.volume_bytes,
    }))
}

#[derive(Deserialize)]
struct LogsQuery {
    tail: Option<u32>,
}

#[derive(Serialize)]
struct LogsDto {
    lines: Vec<LogLine>,
}

/// The container's recent output, read from the runtime on demand and never stored.
async fn logs(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(id): Path<String>,
    Query(query): Query<LogsQuery>,
) -> Result<Json<LogsDto>, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::AuthedRead)?;
    require_manage_server(&state, ctx.user_id).await?;
    validate_module_id(&id)?;
    let record = state
        .store
        .host_run(&id)
        .await?
        .ok_or(ApiError::NotFound("this connector is not run by the host"))?;
    let runner = state.dock.host_run().ok_or(NOT_SET_UP)?;
    let tail = query.tail.unwrap_or(DEFAULT_TAIL).clamp(1, MAX_TAIL);
    match runner.client.logs(&record.run_id, tail).await {
        Ok(lines) => Ok(Json(LogsDto { lines })),
        Err(crate::http::connector_host::SupervisorError::Refused { code, .. })
            if code == "not_found" =>
        {
            Ok(Json(LogsDto { lines: Vec::new() }))
        }
        Err(_) => Err(UNAVAILABLE),
    }
}

/// Starting a host-run connector needs the supervisor; anything else enables as before.
pub(super) async fn before_enable(state: &AppState, id: &str) -> Result<(), ApiError> {
    if state.store.host_run(id).await?.is_none() {
        return Ok(());
    }
    state.dock.host_run().ok_or(NOT_SET_UP)?.require_available()
}

/// Enable starts the container; disable stops it, though the zero ceiling already holds.
pub(super) async fn after_enabled(
    state: &AppState,
    id: &str,
    enabled: bool,
) -> Result<(), ApiError> {
    let Some(runner) = state.dock.host_run() else {
        return Ok(());
    };
    if state.store.host_run(id).await?.is_none() {
        return Ok(());
    }
    if enabled {
        lifecycle::after_enable(state, &runner, id).await
    } else {
        lifecycle::after_disable(state, &runner, id).await;
        Ok(())
    }
}

/// Removes the container before the module row and its host-run row go.
pub(super) async fn before_uninstall(
    state: &AppState,
    id: &str,
    keep_volume: bool,
) -> Result<(), ApiError> {
    match state.dock.host_run() {
        Some(runner) => lifecycle::before_uninstall(state, &runner, id, keep_volume).await,
        None => Ok(()),
    }
}

/// An update that drops `host_run` removes the container and its volume.
/// Answers whether it had one, since then the container's token is revoked and a new one is due.
pub(super) async fn no_longer_host_run(
    state: &AppState,
    id: &str,
    actor: UserId,
) -> Result<Option<String>, ApiError> {
    let Some(record) = state.store.host_run(id).await? else {
        return Ok(None);
    };
    if let Some(runner) = state.dock.host_run() {
        lifecycle::remove_dropped(&runner, &record).await;
    }
    state.store.delete_host_run(id).await?;
    let reissued = state.store.reissue_connector_token(id, actor).await?;
    Ok(reissued.map(|(token, revoked)| {
        super::dock_connector::close_sessions(state, revoked);
        token
    }))
}
