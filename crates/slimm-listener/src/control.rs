// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The only way in: `/v1/control`, one WebSocket from the server, checked
//! against the bearer secret, and `/healthz`. The listener has no route into
//! the server and calls nothing back; it answers the commands it is sent.
//!
//! Losing the connection ends every session: with nobody to tell it who agreed,
//! it must not keep hearing anyone. The server pings every couple of seconds,
//! so five quiet seconds means it is gone.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use axum::Router;
use axum::extract::State;
use axum::extract::ws::{CloseFrame, Message, WebSocket, WebSocketUpgrade};
use axum::http::{HeaderMap, StatusCode, header};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use tokio::sync::mpsc::{UnboundedSender, unbounded_channel};
use tokio::task::JoinHandle;

use crate::config::Config;
use crate::protocol::{self, Command, DecodeError, Report};
use crate::session::SessionCommand;
use crate::stt::Pool;

/// No frame from the server for this long means it is gone.
pub const SILENCE_LIMIT: Duration = Duration::from_secs(5);
/// How long sessions get to leave their rooms once the connection ends.
const LEAVE_WITHIN: Duration = Duration::from_secs(3);

/// What the real listener does for `start`: join the room and run the session.
pub struct Launch {
    pub session: String,
    pub livekit_url: String,
    pub token: String,
    pub include: std::collections::HashSet<String>,
    pub language: Option<String>,
    pub reports: UnboundedSender<Report>,
    pub pool: Arc<Pool>,
}

pub struct Running {
    pub commands: UnboundedSender<SessionCommand>,
    pub task: JoinHandle<()>,
}

pub trait Launcher: Send + Sync + 'static {
    fn launch(&self, launch: Launch) -> Running;
}

#[derive(Clone)]
pub struct Control {
    config: Arc<Config>,
    pool: Arc<Pool>,
    launcher: Arc<dyn Launcher>,
    connected: Arc<AtomicBool>,
    silence: Duration,
}

/// Holds the single control slot; dropping it frees the slot, however the
/// connection ended, including an upgrade that never ran or a panic in `serve`.
struct ControlSlot(Arc<AtomicBool>);

impl ControlSlot {
    fn take(flag: &Arc<AtomicBool>) -> Option<Self> {
        flag.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .ok()
            .map(|_| Self(Arc::clone(flag)))
    }
}

impl Drop for ControlSlot {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

/// The sessions of one connection. A stopped or ended session keeps counting
/// against `max_sessions` and shutdown until its task has finished leaving.
#[derive(Default)]
struct Sessions {
    running: HashMap<String, Running>,
    leaving: Vec<Running>,
}

impl Sessions {
    fn occupied(&mut self) -> usize {
        self.leaving.retain(|found| !found.task.is_finished());
        self.running.len() + self.leaving.len()
    }

    fn retire(&mut self, session: &str) -> Option<&Running> {
        let found = self.running.remove(session)?;
        self.leaving.push(found);
        self.leaving.last()
    }

    async fn leave_everything(self) {
        let all = self.running.into_values().chain(self.leaving);
        let all: Vec<Running> = all.collect();
        for found in &all {
            let _ = found.commands.send(SessionCommand::Stop);
        }
        for found in all {
            let abort = found.task.abort_handle();
            if tokio::time::timeout(LEAVE_WITHIN, found.task)
                .await
                .is_err()
            {
                abort.abort();
            }
        }
    }
}

impl Control {
    pub fn new(config: Arc<Config>, pool: Arc<Pool>, launcher: Arc<dyn Launcher>) -> Self {
        Self {
            config,
            pool,
            launcher,
            connected: Arc::new(AtomicBool::new(false)),
            silence: SILENCE_LIMIT,
        }
    }

    /// How long the server may stay quiet before it counts as gone.
    pub fn with_silence_limit(mut self, silence: Duration) -> Self {
        self.silence = silence;
        self
    }

    pub fn router(self) -> Router {
        Router::new()
            .route("/healthz", get(|| async { "ok" }))
            .route("/v1/control", get(upgrade))
            .with_state(self)
    }
}

async fn upgrade(
    State(control): State<Control>,
    headers: HeaderMap,
    ws: WebSocketUpgrade,
) -> Response {
    let presented = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or_default();
    if !same_secret(presented, &control.config.secret) {
        return StatusCode::UNAUTHORIZED.into_response();
    }
    let Some(slot) = ControlSlot::take(&control.connected) else {
        return StatusCode::CONFLICT.into_response();
    };
    ws.on_upgrade(move |socket| async move {
        let _slot = slot;
        serve(&control, socket).await;
    })
}

/// Compares without stopping at the first difference.
fn same_secret(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    let mut diff = a.len() ^ b.len();
    for i in 0..a.len().max(b.len()) {
        diff |= usize::from(a.get(i).copied().unwrap_or(0) ^ b.get(i).copied().unwrap_or(0));
    }
    diff == 0
}

async fn serve(control: &Control, mut socket: WebSocket) {
    let (reports, mut outgoing) = unbounded_channel::<Report>();
    let ready = Report::Ready {
        version: env!("CARGO_PKG_VERSION").into(),
        engine: "whisper.cpp".into(),
        model: control.pool.model().into(),
        max_sessions: control.config.max_sessions,
    };
    if socket
        .send(Message::text(protocol::encode(&ready)))
        .await
        .is_err()
    {
        return;
    }
    let mut sessions = Sessions::default();
    loop {
        tokio::select! {
            incoming = tokio::time::timeout(control.silence, socket.recv()) => {
                let Ok(Some(Ok(frame))) = incoming else { break };
                match frame {
                    Message::Text(text) => {
                        if !handle(control, text.as_str(), &reports, &mut sessions, &mut socket).await {
                            break;
                        }
                    }
                    Message::Close(_) => break,
                    _ => {}
                }
            }
            Some(report) = outgoing.recv() => {
                if let Report::Ended { session, .. } = &report {
                    sessions.retire(session);
                }
                if socket.send(Message::text(protocol::encode(&report))).await.is_err() {
                    break;
                }
            }
        }
    }
    sessions.leave_everything().await;
}

/// Applies one command; false closes the connection.
async fn handle(
    control: &Control,
    text: &str,
    reports: &UnboundedSender<Report>,
    sessions: &mut Sessions,
    socket: &mut WebSocket,
) -> bool {
    let command = match protocol::decode(text) {
        Ok(command) => command,
        Err(DecodeError::Newer(v)) => {
            tracing::warn!(v, "the server speaks a newer protocol; closing");
            let close = CloseFrame {
                code: 1002,
                reason: "unsupported protocol version".into(),
            };
            let _ = socket.send(Message::Close(Some(close))).await;
            return false;
        }
        Err(DecodeError::Malformed(why)) => {
            tracing::warn!(%why, "ignoring a malformed frame");
            return true;
        }
    };
    match command {
        Command::Start {
            session,
            livekit_url,
            token,
            include,
            language,
        } => {
            if sessions.running.contains_key(&session) {
                return true;
            }
            if sessions.occupied() >= control.config.max_sessions as usize {
                let _ = reports.send(Report::Ended {
                    session,
                    reason: "overload".into(),
                });
                return true;
            }
            let launched = control.launcher.launch(Launch {
                session: session.clone(),
                livekit_url,
                token,
                include: include.into_iter().collect(),
                language: language.or_else(|| control.config.language.clone()),
                reports: reports.clone(),
                pool: Arc::clone(&control.pool),
            });
            sessions.running.insert(session, launched);
        }
        Command::Include { session, include } => {
            if let Some(found) = sessions.running.get(&session) {
                let _ = found
                    .commands
                    .send(SessionCommand::Include(include.into_iter().collect()));
            }
        }
        Command::Stop { session } => {
            if let Some(found) = sessions.retire(&session) {
                let _ = found.commands.send(SessionCommand::Stop);
            }
        }
    }
    true
}

#[cfg(test)]
mod tests;
