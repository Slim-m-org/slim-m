// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A member's run of a connector's command or panel (add-on API 7). Where a WASM
//! module would run in the sandbox, the host sends the same run request to the
//! connector's own connections as a `connector.run` frame and waits, bounded,
//! for the same answer at `POST /connectors/me/runs/{run_id}`. An offline, busy
//! or slow connector answers like a failed WASM run, so no surface waits past
//! [`RUN_DEADLINE`]. The guide is docs/modules/connectors.md.

use std::collections::HashMap;
use std::hash::Hash;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use axum::Router;
use axum::body::Bytes;
use axum::extract::{DefaultBodyLimit, Path, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
use axum::routing::post;
use serde::Deserialize;
use serde_json::value::RawValue;
use tokio::sync::oneshot;
use uuid::Uuid;

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, enforce};
use super::module_commands::CommandOutcome;
use super::module_run::{RunContext, RunKind, RunRequest};
use crate::hub::{ConnectorRunRequest, Event, RoomJson};
use crate::ids::{ChannelId, UserId};
use crate::module_runtime::{MAX_RESPONSE_BYTES, NET_FETCH_WALL_FLOOR_MS};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::InstalledModule;

/// How long a member waits for a connector: a WASM module that can fetch gets the same.
pub(crate) const RUN_DEADLINE: Duration = Duration::from_millis(NET_FETCH_WALL_FLOOR_MS);
/// The largest answer a connector may send, the same cap a WASM module's response has.
pub(crate) const MAX_ANSWER_BYTES: usize = MAX_RESPONSE_BYTES;
/// Runs one connector may have waiting at once; past it a run is turned away at once.
pub(crate) const MAX_IN_FLIGHT: usize = 8;
/// Of those, how many one member may hold, so one member cannot fill the rest.
pub(crate) const MAX_IN_FLIGHT_PER_MEMBER: usize = 2;

pub fn routes() -> Router<AppState> {
    Router::new()
        .route("/connectors/me/runs/{runId}", post(answer_run))
        .layer(DefaultBodyLimit::max(MAX_ANSWER_BYTES))
}

/// The runs waiting on connectors, how many each connector and member holds, and how long one waits.
pub struct ConnectorRuns {
    waiting: Mutex<Waiting>,
    deadline: Duration,
}

impl Default for ConnectorRuns {
    fn default() -> Self {
        Self::with_deadline(RUN_DEADLINE)
    }
}

#[derive(Default)]
struct Waiting {
    runs: HashMap<Uuid, Pending>,
    per_module: HashMap<String, usize>,
    per_member: HashMap<(String, UserId), usize>,
}

struct Pending {
    principal: UserId,
    answer: oneshot::Sender<Vec<u8>>,
}

/// One run waiting on its connector; dropping it forgets the run and frees its slots.
struct InFlight<'a> {
    runs: &'a ConnectorRuns,
    run_id: Uuid,
    module_id: String,
    caller: UserId,
}

impl ConnectorRuns {
    /// A run waits `deadline` for its answer; a test shortens it instead of waiting [`RUN_DEADLINE`].
    pub fn with_deadline(deadline: Duration) -> Self {
        Self {
            waiting: Mutex::default(),
            deadline,
        }
    }

    /// A slot for `caller`'s run on `module_id`, and where its answer arrives; `None` when either cap is full.
    fn admit(
        &self,
        module_id: &str,
        principal: UserId,
        caller: UserId,
    ) -> Option<(InFlight<'_>, oneshot::Receiver<Vec<u8>>)> {
        let mut waiting = self.lock();
        let member = (module_id.to_owned(), caller);
        let module_held = waiting.per_module.get(module_id).copied().unwrap_or(0);
        let member_held = waiting.per_member.get(&member).copied().unwrap_or(0);
        if module_held >= MAX_IN_FLIGHT || member_held >= MAX_IN_FLIGHT_PER_MEMBER {
            return None;
        }
        *waiting.per_module.entry(module_id.to_owned()).or_default() += 1;
        *waiting.per_member.entry(member).or_default() += 1;
        let run_id = Uuid::now_v7();
        let (answer, answered) = oneshot::channel();
        waiting.runs.insert(run_id, Pending { principal, answer });
        let in_flight = InFlight {
            runs: self,
            run_id,
            module_id: module_id.to_owned(),
            caller,
        };
        Some((in_flight, answered))
    }

    /// Hands `answer` to run `run_id`; false unless it is waiting and was sent to `principal`.
    fn answer(&self, principal: UserId, run_id: Uuid, answer: Vec<u8>) -> bool {
        let mut waiting = self.lock();
        if !waiting
            .runs
            .get(&run_id)
            .is_some_and(|p| p.principal == principal)
        {
            return false;
        }
        waiting
            .runs
            .remove(&run_id)
            .is_some_and(|p| p.answer.send(answer).is_ok())
    }

    fn lock(&self) -> MutexGuard<'_, Waiting> {
        self.waiting.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        let mut waiting = self.runs.lock();
        waiting.runs.remove(&self.run_id);
        release(&mut waiting.per_module, &self.module_id);
        release(
            &mut waiting.per_member,
            &(self.module_id.clone(), self.caller),
        );
    }
}

fn release<K: Eq + Hash>(counts: &mut HashMap<K, usize>, key: &K) {
    if let Some(held) = counts.get_mut(key) {
        *held = held.saturating_sub(1);
        if *held == 0 {
            counts.remove(key);
        }
    }
}

/// Runs `request` on a connector: forwarded with a context it may see, answered in the WASM shape.
pub(crate) async fn run(
    state: &AppState,
    module: &InstalledModule,
    request: &RunRequest<'_>,
) -> Result<CommandOutcome, ApiError> {
    if request.kind != RunKind::Command {
        return Ok(CommandOutcome::host_failure(
            "a connector answers only a member's own run".to_owned(),
        ));
    }
    let Some(principal) = module.bot_user_id else {
        return Ok(CommandOutcome::host_failure(offline(module)));
    };
    let context = confined(state, principal, request.context).await;
    let wire = super::module_run::wire_request(state, module, request, context).await?;
    let wire = RawValue::from_string(wire).map_err(|_| ApiError::Internal)?;
    Ok(
        match forward(state, module, (principal, request.caller), wire).await {
            Ok(answer) => super::module_run::interpret(&answer),
            Err(why) => CommandOutcome::host_failure(why),
        },
    )
}

/// Sends the run to the connector's connections and waits for its answer; the error is what the member reads.
async fn forward(
    state: &AppState,
    module: &InstalledModule,
    (principal, caller): (UserId, UserId),
    request: Box<RawValue>,
) -> Result<Vec<u8>, String> {
    let gone = !state.hub.presence().is_connected(principal);
    if gone || super::connector_host::known_offline(state, &module.id).await {
        return Err(offline(module));
    }
    let runs = state.dock.connector_runs();
    let Some((in_flight, answered)) = runs.admit(&module.id, principal, caller) else {
        return Err(format!("{} is busy; try again in a moment", module.name));
    };
    state
        .hub
        .publish(Event::ConnectorRun(Arc::new(ConnectorRunRequest {
            principal,
            run_id: in_flight.run_id,
            module_id: module.id.clone(),
            deadline_ms: u64::try_from(runs.deadline.as_millis()).unwrap_or(u64::MAX),
            request: RoomJson::new(request),
        })));
    let answer = tokio::time::timeout(runs.deadline, answered).await;
    drop(in_flight);
    match answer {
        Ok(Ok(bytes)) => Ok(bytes),
        _ => Err(format!("{} did not answer in time", module.name)),
    }
}

fn offline(module: &InstalledModule) -> String {
    format!("{} is offline", module.name)
}

/// The run's context with every channel the connector cannot view left out, as its token would see it.
async fn confined(state: &AppState, principal: UserId, context: RunContext) -> RunContext {
    RunContext {
        channel: viewable(state, principal, context.channel).await,
        voice_channel: viewable(state, principal, context.voice_channel).await,
    }
}

async fn viewable(
    state: &AppState,
    principal: UserId,
    channel: Option<ChannelId>,
) -> Option<ChannelId> {
    let channel = channel?;
    let can_view = state
        .store
        .has_permission(principal, channel, Permissions::VIEW_CHANNEL)
        .await;
    matches!(can_view, Ok(true)).then_some(channel)
}

/// Whether `module`'s answer may be posted in `channel`: a connector only where its own token could post.
pub(crate) async fn may_post_in(
    state: &AppState,
    module: &InstalledModule,
    channel: ChannelId,
) -> Result<bool, ApiError> {
    match (module.is_connector(), module.bot_user_id) {
        (false, _) => Ok(true),
        (true, None) => Ok(false),
        (true, Some(principal)) => Ok(state
            .store
            .has_permission(
                principal,
                channel,
                Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES),
            )
            .await?),
    }
}

/// The answer's shape, checked so a connector learns at once that it sent a malformed one.
#[derive(Deserialize)]
struct Answer {
    ok: bool,
    #[serde(default)]
    output: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

fn well_formed(body: &[u8]) -> bool {
    match serde_json::from_slice::<Answer>(body) {
        Ok(a) if a.ok => a.output.is_some(),
        Ok(a) => a.error.is_some(),
        Err(_) => false,
    }
}

/// A connector answers one run it was sent. A malformed answer still reaches the member, as a failed run.
async fn answer_run(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Path(run_id): Path<String>,
    body: Bytes,
) -> Result<StatusCode, ApiError> {
    enforce(&state, &parts, Some(&ctx), Class::Module)?;
    let module = state
        .store
        .connector_of(ctx.user_id)
        .await?
        .ok_or(ApiError::ForbiddenBecause(
            "only a connector's own token can answer its runs",
        ))?;
    if !module.enabled {
        return Err(ApiError::Conflict("an admin has turned this connector off"));
    }
    let run_id = Uuid::parse_str(&run_id).map_err(|_| ApiError::BadRequest("invalid run id"))?;
    let shaped = well_formed(&body);
    if !state
        .dock
        .connector_runs()
        .answer(ctx.user_id, run_id, body.to_vec())
    {
        return Err(ApiError::NotFound("no run is waiting for that answer"));
    }
    if !shaped {
        return Err(ApiError::BadRequest(
            "an answer is {\"ok\": true, \"output\": ...} or {\"ok\": false, \"error\": ...}",
        ));
    }
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests;
