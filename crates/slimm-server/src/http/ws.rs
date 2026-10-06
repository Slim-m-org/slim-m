// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The WebSocket surface: connect, authenticate, negotiate, and fan out events.
//!
//! A client connects to `/ws`, then sends a `hello` frame carrying a single-use
//! connect ticket (minted over REST from its session) and the protocol version
//! it speaks. The server redeems the ticket, confirms the version, and replies
//! with its own `hello`. From then on the connection is a one-way fan-out of
//! events the user is allowed to see, plus a `ping`/`pong` keepalive.
//!
//! Delivery is authorized per event: a `message.created` reaches a connection
//! only if that user can view the channel it happened in, so the socket never
//! leaks a channel the caller could not read over REST. If the connection falls
//! behind the durable broadcast buffer it is closed and the client resyncs
//! over REST; falling behind the ephemeral one (cursors, stroke previews)
//! never closes anything, see `crate::hub`'s own doc comment.

use std::time::Duration;

use axum::Router;
use axum::extract::State;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use futures_util::stream::{SplitSink, SplitStream};
use futures_util::{SinkExt, StreamExt};
use tokio::sync::OwnedSemaphorePermit;
use tokio::sync::broadcast::error::RecvError;

use super::AppState;
use super::PROTOCOL_VERSION;
use super::canvas::CanvasObjectDto;
use super::channels::ChannelDto;
use super::messages::{AttachmentDto, MessageDto};
use crate::hub::Event;
use crate::store::SessionContext;
use authorization::{Authorization, authorize};
use frames::ClientFrame;
use frames::ServerFrame;
use permission_cache::PermissionCache;

mod account_frames;
mod authorization;
mod canvas_frames;
mod ephemeral_frames;
mod frames;
mod interaction_frames;
mod message_frames;
mod permission_cache;
mod signals;

/// How long a freshly connected socket has to send its `hello` before it is
/// dropped, so unauthenticated sockets cannot linger.
const AUTH_DEADLINE: Duration = Duration::from_secs(10);

/// How long a single send may block before the peer is treated as dead. Without
/// this a peer that completes the handshake and then stops reading could wedge
/// its connection task indefinitely.
const WRITE_TIMEOUT: Duration = Duration::from_secs(10);

/// Legitimate frames are tiny JSON; cap message and frame size well below the
/// library defaults so a client cannot force a large buffer.
const MAX_FRAME_BYTES: usize = 4 * 1024;

type Sink = SplitSink<WebSocket, Message>;
type Stream = SplitStream<WebSocket>;

/// The WebSocket route, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new().route("/ws", get(connect))
}

async fn connect(ws: WebSocketUpgrade, State(state): State<AppState>) -> Response {
    // Checked before the connection-count slot: cheaper to refuse here than to claim and release one.
    if !state.hub.admit_memory() {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            "insufficient memory headroom",
        )
            .into_response();
    }
    // Claim a connection slot before upgrading, so a flood cannot open unbounded
    // sockets. The permit is held for the connection's whole life.
    let Some(permit) = state.hub.try_connect() else {
        return (StatusCode::SERVICE_UNAVAILABLE, "too many connections").into_response();
    };
    ws.max_message_size(MAX_FRAME_BYTES)
        .max_frame_size(MAX_FRAME_BYTES)
        .on_upgrade(move |socket| serve(socket, state, permit))
}

// --- Connection ---

async fn serve(socket: WebSocket, state: AppState, _permit: OwnedSemaphorePermit) {
    let (mut sink, mut stream) = socket.split();

    // Subscribed before the ticket is redeemed, so a revocation published during the handshake is buffered.
    let mut events = state.hub.subscribe();
    let mut ephemeral_events = state.hub.subscribe_ephemeral();

    let ctx = match authenticate(&mut sink, &mut stream, &state).await {
        Some(ctx) => ctx,
        None => return,
    };

    // Per connection, and dropped with it; see `permission_cache`.
    let mut cache = PermissionCache::new();

    // Guarantees the matching disconnect however this function returns; see
    // `signals::PresenceGuard`.
    let presence_guard = signals::PresenceGuard::connect(
        state.hub.clone(),
        state.store.clone(),
        ctx.user_id,
        ctx.device_id,
    )
    .await;

    if send_frame(
        &mut sink,
        &ServerFrame::Hello {
            protocol: PROTOCOL_VERSION,
            moderation_seq: state.hub.moderation_head(),
        },
    )
    .await
    .is_err()
    {
        return;
    }

    loop {
        tokio::select! {
            incoming = stream.next() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        // Touch after the parse, never before: it takes the shared presence lock and nothing rate-limits inbound frames.
                        match serde_json::from_str::<ClientFrame>(text.as_str()) {
                            Ok(ClientFrame::Ping) => {
                                state.hub.presence().touch(ctx.user_id);
                                if send_frame(&mut sink, &ServerFrame::Pong).await.is_err() {
                                    break;
                                }
                            }
                            Ok(ClientFrame::Viewing { channel_ids }) => {
                                // Not a touch: a timer on a focused window is not the user being active.
                                presence_guard.set_viewing(&channel_ids);
                            }
                            Ok(ClientFrame::Typing { channel_id }) => {
                                signals::handle_typing(
                                    &state.store,
                                    &state.hub,
                                    &state.limiter,
                                    &ctx,
                                    &channel_id,
                                )
                                .await;
                            }
                            Ok(ClientFrame::CanvasCursor { channel_id, x, y }) => {
                                signals::handle_canvas_cursor(
                                    &state.store,
                                    &state.hub,
                                    &state.limiter,
                                    &ctx,
                                    &channel_id,
                                    x,
                                    y,
                                )
                                .await;
                            }
                            Ok(ClientFrame::CanvasStrokePreview {
                                channel_id,
                                object_id,
                                points,
                                ended,
                            }) => {
                                // The raw wire size, not a re-serialization: it is what this frame actually cost to send.
                                let frame_bytes = text.as_str().len();
                                signals::handle_canvas_stroke_preview(
                                    &state.store,
                                    &state.hub,
                                    &state.limiter,
                                    &ctx,
                                    signals::StrokePreviewFrame {
                                        channel_id,
                                        object_id,
                                        points,
                                        ended,
                                    },
                                    frame_bytes,
                                )
                                .await;
                            }
                            // A second hello or anything unparseable is not
                            // worth tearing the connection down over.
                            Ok(ClientFrame::Hello { .. }) | Err(_) => {}
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Err(_)) => break,
                    // Other frames (binary, ping, pong): axum answers a
                    // protocol-level ping itself, but it is still activity.
                    Some(Ok(_)) => {
                        state.hub.presence().touch(ctx.user_id);
                    }
                }
            }
            event = events.recv() => {
                match event {
                    // Our own session was revoked: close the socket at once.
                    Ok(Event::SessionRevoked(session_id)) => {
                        if session_id == ctx.session_id {
                            break;
                        }
                    }
                    Ok(event) => {
                        match authorize(&state.store, &state.hub, &state.link_previews, &ctx, &mut cache, event).await {
                            Authorization::Deliver(frame) => {
                                if send_frame(&mut sink, &frame).await.is_err() {
                                    break;
                                }
                            }
                            Authorization::Withhold => {}
                            // See `Authorization::Unknown`'s doc comment for why.
                            Authorization::Unknown => {
                                let _ = send_frame(
                                    &mut sink,
                                    &ServerFrame::Error { message: "resync".to_owned() },
                                )
                                .await;
                                break;
                            }
                        }
                    }
                    Err(RecvError::Lagged(_)) => {
                        let _ = send_frame(
                            &mut sink,
                            &ServerFrame::Error { message: "resync".to_owned() },
                        )
                        .await;
                        break;
                    }
                    Err(RecvError::Closed) => break,
                }
            }
            ephemeral_event = ephemeral_events.recv() => {
                match ephemeral_event {
                    Ok(event) => {
                        match authorize(&state.store, &state.hub, &state.link_previews, &ctx, &mut cache, event).await {
                            Authorization::Deliver(frame) => {
                                if send_frame(&mut sink, &frame).await.is_err() {
                                    break;
                                }
                            }
                            // Withheld or undecidable: a lost cursor/preview costs nothing either way.
                            Authorization::Withhold | Authorization::Unknown => {}
                        }
                    }
                    // The whole point: falling behind here never closes the connection or resyncs.
                    Err(RecvError::Lagged(_)) => {}
                    Err(RecvError::Closed) => break,
                }
            }
        }
    }
}

/// Reads and validates the opening `hello`, returning the session it authorizes.
/// On any failure it sends an error frame and returns `None`; the caller closes.
async fn authenticate(
    sink: &mut Sink,
    stream: &mut Stream,
    state: &AppState,
) -> Option<SessionContext> {
    let opening = tokio::time::timeout(AUTH_DEADLINE, stream.next()).await;
    let text = match opening {
        Ok(Some(Ok(Message::Text(text)))) => text,
        _ => return reject(sink, "expected a hello frame").await,
    };

    let (ticket, protocol) = match serde_json::from_str::<ClientFrame>(text.as_str()) {
        Ok(ClientFrame::Hello { ticket, protocol }) => (ticket, protocol),
        _ => return reject(sink, "expected a hello frame").await,
    };
    if protocol != PROTOCOL_VERSION {
        return reject(sink, "unsupported protocol version").await;
    }

    match state.store.redeem_ws_ticket(&ticket).await {
        Ok(Some(ctx)) => Some(ctx),
        _ => reject(sink, "invalid ticket").await,
    }
}

async fn send_frame(sink: &mut Sink, frame: &ServerFrame) -> Result<(), ()> {
    let text = serde_json::to_string(frame).map_err(|_| ())?;
    // A send that does not complete within the deadline means the peer stopped
    // reading; treat it like any other send failure and close the connection.
    match tokio::time::timeout(WRITE_TIMEOUT, sink.send(Message::Text(text.into()))).await {
        Ok(Ok(())) => Ok(()),
        _ => Err(()),
    }
}

/// Sends a final error frame and resolves to `None`.
async fn reject(sink: &mut Sink, message: &str) -> Option<SessionContext> {
    let _ = send_frame(
        sink,
        &ServerFrame::Error {
            message: message.to_owned(),
        },
    )
    .await;
    None
}
