// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Carries out what the session machine decided: the listener's token and
//! frames, the events a module is sent, and the frame everyone in the call sees.

use std::time::Duration;

use super::link::LinkEvent;
use super::protocol::FromListener;
use super::session::{Effect, EndReason};
use super::{CallAudioView, Outcome};
use crate::http::AppState;
use crate::http::module_events::call_audio as module_events;
use crate::http::module_host::call_audio_approved;
use crate::hub::Event;
use crate::store::now_ms;

/// How often the machine is ticked for lapses and the time limit.
const TICK: Duration = Duration::from_secs(1);
/// A session's module and channel list are re-read this many ticks apart.
const STANDING_EVERY_TICKS: u64 = 5;

/// Starts the loop that listens to the link; `None` when call audio is off.
pub fn spawn(state: AppState) -> Option<tokio::task::JoinHandle<()>> {
    let mut events = state.call_audio.take_events()?;
    Some(tokio::spawn(async move {
        let mut ticker = tokio::time::interval(TICK);
        let mut ticks = 0_u64;
        loop {
            tokio::select! {
                event = events.recv() => {
                    let Some(event) = event else { return };
                    handle(&state, event).await;
                }
                _ = ticker.tick() => {
                    ticks += 1;
                    for outcome in state.call_audio.tick(now_ms()) {
                        apply(&state, outcome).await;
                    }
                    if ticks.is_multiple_of(STANDING_EVERY_TICKS) {
                        check_standing(&state).await;
                    }
                }
            }
        }
    }))
}

async fn handle(state: &AppState, event: LinkEvent) {
    let now = now_ms();
    match event {
        LinkEvent::Ready { max_sessions } => state.call_audio.listener_ready(max_sessions),
        LinkEvent::Disconnected => {
            for outcome in state.call_audio.listener_lost(now) {
                apply(state, outcome).await;
            }
        }
        LinkEvent::Message(segment @ FromListener::Segment { .. }) => {
            if let Some(accepted) = state.call_audio.accept_segment(&segment, now) {
                module_events::segment(state, &accepted);
            }
        }
        LinkEvent::Message(FromListener::Ended { session, reason }) => {
            let reason = match reason.as_str() {
                "overload" => EndReason::Overload,
                "time_limit" => EndReason::TimeLimit,
                _ => EndReason::ListenerUnavailable,
            };
            if let Some(outcome) = state.call_audio.end_by_id(&session, reason, now) {
                apply(state, outcome).await;
            }
        }
        LinkEvent::Message(_) => {}
    }
}

/// Ends the sessions whose module was turned off or lost its approval or channel.
async fn check_standing(state: &AppState) {
    for channel in state.call_audio.channels(None) {
        let Some(view) = state.call_audio.view(channel) else {
            continue;
        };
        let reason = match standing(state, &view.module_id, channel).await {
            Ok(None) => continue,
            Ok(Some(reason)) => reason,
            Err(err) => {
                tracing::warn!(%err, "could not check a call-audio module");
                continue;
            }
        };
        if let Some(outcome) = state.call_audio.end(channel, reason, now_ms()) {
            apply(state, outcome).await;
        }
    }
}

async fn standing(
    state: &AppState,
    module_id: &str,
    channel: crate::ids::ChannelId,
) -> anyhow::Result<Option<EndReason>> {
    let module = state.store.installed_module(module_id).await?;
    if !module
        .as_ref()
        .is_some_and(|m| m.enabled && call_audio_approved(m))
    {
        return Ok(Some(EndReason::ModuleDisabled));
    }
    if !state.store.call_audio_armed(module_id, channel).await? {
        return Ok(Some(EndReason::ChannelRemoved));
    }
    Ok(None)
}

/// Ends every session of `module_id` for `reason`.
pub async fn end_module_sessions(state: &AppState, module_id: &str, reason: EndReason) {
    for channel in state.call_audio.channels(Some(module_id)) {
        if let Some(outcome) = state.call_audio.end(channel, reason, now_ms()) {
            apply(state, outcome).await;
        }
    }
}

/// Carries out an outcome's effects, then tells the call what its session now looks like.
/// False when the listener could not be started and the session was ended instead.
pub async fn apply(state: &AppState, outcome: Outcome) -> bool {
    let mut ended: Option<EndReason> = None;
    for effect in &outcome.effects {
        match effect {
            Effect::Start => {
                if !start_listener(state, &outcome) {
                    stop_unstartable(state, &outcome);
                    return false;
                }
                module_events::started(state, &outcome);
            }
            Effect::Include => state.call_audio.send_include(outcome.channel),
            Effect::Participant { user_id, included } => {
                module_events::participant(state, &outcome, *user_id, *included);
            }
            Effect::Ended { reason, was_on } => {
                ended = Some(*reason);
                if *was_on {
                    state.call_audio.send_stop(outcome.session_id);
                    module_events::stopped(state, &outcome, reason.wire());
                }
            }
        }
    }
    publish(state, &outcome, ended);
    true
}

fn publish(state: &AppState, outcome: &Outcome, ended: Option<EndReason>) {
    let (view, ended): (Option<Box<CallAudioView>>, _) = match ended {
        Some(reason) => (None, Some(ended_name(reason))),
        None => (Some(Box::new(outcome.view.clone())), None),
    };
    state.hub.publish(Event::CallAudioChanged {
        channel_id: outcome.channel,
        state: view,
        ended,
    });
}

/// What clients are told: unlike a module, they may learn that the ask lapsed.
fn ended_name(reason: EndReason) -> &'static str {
    match reason {
        EndReason::Lapsed => "lapsed",
        other => other.wire(),
    }
}

fn start_listener(state: &AppState, outcome: &Outcome) -> bool {
    let call_audio = &state.call_audio;
    let minted = state.voice.mint_listener(
        outcome.channel,
        outcome.session_id,
        call_audio.livekit_url().as_deref(),
    );
    match minted {
        Ok(token) => {
            call_audio.send_start(outcome.channel, token.token, token.url);
            true
        }
        Err(_) => false,
    }
}

fn stop_unstartable(state: &AppState, outcome: &Outcome) {
    if let Some(next) =
        state
            .call_audio
            .end(outcome.channel, EndReason::ListenerUnavailable, now_ms())
    {
        publish(state, &next, Some(EndReason::ListenerUnavailable));
    }
}
