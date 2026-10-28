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
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{FromRequestParts, State};
use axum::http::StatusCode;
use axum::http::request::Parts;
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
use super::extract::limit_key;
use super::messages::{AttachmentDto, MessageDto};
use crate::hub::{Event, PendingGuard};
use crate::store::SessionContext;
use authorization::{Authorization, authorize};
use client_frames::ClientFrame;
use frames::ServerFrame;
use permission_cache::PermissionCache;

mod account_frames;
mod authorization;
mod authorization_bits;
mod canvas_frames;
mod canvas_gate;
mod channel_scope;
mod client_frames;
mod deployment_frames;
mod ephemeral_frames;
mod frames;
mod interaction_frames;
mod message_frames;
mod permission_cache;
mod signals;
mod signals_canvas;
mod signals_screen_annotation;

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

/// The address key an unauthenticated socket is counted under, from the same trusted-hops logic as rate limits.
struct PendingKey(String);

impl FromRequestParts<AppState> for PendingKey {
    type Rejection = std::convert::Infallible;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        Ok(Self(limit_key(parts, None, state.limiter.trusted_hops())))
    }
}

async fn connect(
    ws: WebSocketUpgrade,
    PendingKey(address): PendingKey,
    State(state): State<AppState>,
) -> Response {
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
    // Held until the hello is accepted, so one address cannot park every slot behind the auth deadline.
    let Some(pending) = state.hub.try_hold_pending(&address) else {
        return (
            StatusCode::TOO_MANY_REQUESTS,
            "too many pending connections",
        )
            .into_response();
    };
    // tungstenite zero-fills its whole read buffer on every read; 128 KiB by default was most of fan-out's CPU (#2239).
    ws.max_message_size(MAX_FRAME_BYTES)
        .max_frame_size(MAX_FRAME_BYTES)
        .read_buffer_size(MAX_FRAME_BYTES)
        .on_upgrade(move |socket| serve(socket, state, permit, pending))
}

// --- Connection ---

async fn serve(
    socket: WebSocket,
    state: AppState,
    _permit: OwnedSemaphorePermit,
    pending: PendingGuard,
) {
    let (mut sink, mut stream) = socket.split();

    // Subscribed before the ticket is redeemed, so a revocation published during the handshake is buffered.
    let mut events = state.hub.subscribe();
    let mut ephemeral_events = state.hub.subscribe_ephemeral();

    let (ctx, reported_active) = match authenticate(&mut sink, &mut stream, &state).await {
        Some(opened) => opened,
        None => return,
    };
    drop(pending);

    // Per connection, and dropped with it; see `permission_cache`.
    let mut cache = PermissionCache::new();

    // Guarantees the matching disconnect however this function returns; see
    // `signals::PresenceGuard`.
    let presence_guard = signals::PresenceGuard::connect(
        state.hub.clone(),
        state.store.clone(),
        ctx.user_id,
        ctx.device_id,
        reported_active.unwrap_or(true),
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

    // A client that sends `active` frames reports real use; its keepalives then prove nothing.
    let mut reports_activity = reported_active.is_some();
    loop {
        tokio::select! {
            incoming = stream.next() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        // Touch after the parse, never before: it takes the shared presence lock and nothing rate-limits inbound frames.
                        match serde_json::from_str::<ClientFrame>(text.as_str()) {
                            Ok(ClientFrame::Active) => {
                                reports_activity = true;
                                state.hub.presence().touch(ctx.user_id);
                            }
                            Ok(ClientFrame::Ping) => {
                                if !reports_activity {
                                    state.hub.presence().touch(ctx.user_id);
                                }
                                if send_frame(&mut sink, &ServerFrame::Pong).await.is_err() {
                                    break;
                                }
                            }
                            Ok(ClientFrame::Viewing { channel_ids, active }) => {
                                // Not a presence touch: the client decides `active` from real input, not this timer.
                                presence_guard.set_viewing(&channel_ids, active);
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
                            Ok(ClientFrame::CanvasCursor {
                                channel_id,
                                x,
                                y,
                                left,
                            }) => {
                                signals_canvas::handle_canvas_cursor(
                                    &state.store,
                                    &state.hub,
                                    &state.limiter,
                                    &ctx,
                                    &mut cache,
                                    &channel_id,
                                    signals_canvas::CursorAt { x, y, left },
                                )
                                .await;
                            }
                            Ok(ClientFrame::CanvasStrokePreview {
                                channel_id,
                                object_id,
                                points,
                                ended,
                                cancelled,
                                color,
                                width,
                            }) => {
                                // The raw wire size, not a re-serialization: it is what this frame actually cost to send.
                                let frame_bytes = text.as_str().len();
                                signals_canvas::handle_canvas_stroke_preview(
                                    &state.store,
                                    &state.hub,
                                    &state.limiter,
                                    &ctx,
                                    &mut cache,
                                    signals_canvas::StrokePreviewFrame {
                                        channel_id,
                                        object_id,
                                        points,
                                        ended,
                                        cancelled,
                                        color,
                                        width,
                                    },
                                    frame_bytes,
                                )
                                .await;
                            }
                            Ok(ClientFrame::CanvasObjectPreview {
                                channel_id,
                                object_id,
                                x,
                                y,
                                w,
                                h,
                                ended,
                            }) => {
                                signals_canvas::handle_canvas_object_preview(
                                    &state.store,
                                    &state.hub,
                                    &state.limiter,
                                    &ctx,
                                    &mut cache,
                                    signals_canvas::ObjectPreviewFrame {
                                        channel_id,
                                        object_id,
                                        rect: [x, y, w, h],
                                        ended,
                                    },
                                )
                                .await;
                            }
                            Ok(ClientFrame::CanvasMediaSlotPreview {
                                channel_id,
                                kind,
                                user_id,
                                x,
                                y,
                                w,
                                h,
                                ended,
                            }) => {
                                signals_canvas::handle_canvas_media_slot_preview(
                                    &state.store,
                                    &state.hub,
                                    &state.limiter,
                                    &ctx,
                                    &mut cache,
                                    signals_canvas::MediaSlotPreviewFrame {
                                        channel_id,
                                        kind,
                                        slot_user_id: user_id,
                                        rect: [x, y, w, h],
                                        ended,
                                    },
                                )
                                .await;
                            }
                            Ok(ClientFrame::CanvasScreenAnnotation {
                                channel_id,
                                target_user_id,
                                kind,
                                annotation_id,
                                points,
                                color,
                                text: note,
                                ended,
                                allowed,
                                aspect,
                            }) => {
                                let frame_bytes = text.as_str().len();
                                signals_screen_annotation::handle_canvas_screen_annotation(
                                    &state.store,
                                    &state.hub,
                                    &state.limiter,
                                    &ctx,
                                    &mut cache,
                                    signals_screen_annotation::ScreenAnnotationFrame {
                                        channel_id,
                                        target_user_id,
                                        kind,
                                        annotation_id,
                                        points,
                                        color,
                                        text: note,
                                        ended,
                                        allowed,
                                        aspect,
                                    },
                                    frame_bytes,
                                )
                                .await;
                            }
                            Ok(ClientFrame::CanvasView {
                                channel_id,
                                x,
                                y,
                                w,
                                h,
                                summon,
                                tile,
                            }) => {
                                signals_canvas::handle_canvas_view(
                                    &state.store,
                                    &state.hub,
                                    &state.limiter,
                                    &ctx,
                                    &mut cache,
                                    signals_canvas::ViewFrame {
                                        channel_id,
                                        rect: [x, y, w, h],
                                        summon,
                                        tile,
                                    },
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
                    // protocol-level ping itself; activity only without `active`.
                    Some(Ok(_)) => {
                        if !reports_activity {
                            state.hub.presence().touch(ctx.user_id);
                        }
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
) -> Option<(SessionContext, Option<bool>)> {
    let opening = tokio::time::timeout(state.hub.auth_deadline(), stream.next()).await;
    let text = match opening {
        Ok(Some(Ok(Message::Text(text)))) => text,
        _ => return reject(sink, "expected a hello frame").await,
    };

    let (ticket, protocol, active) = match serde_json::from_str::<ClientFrame>(text.as_str()) {
        Ok(ClientFrame::Hello {
            ticket,
            protocol,
            active,
        }) => (ticket, protocol, active),
        _ => return reject(sink, "expected a hello frame").await,
    };
    if protocol != PROTOCOL_VERSION {
        return reject(sink, "unsupported protocol version").await;
    }

    match state.store.redeem_ws_ticket(&ticket).await {
        Ok(Some(ctx)) => Some((ctx, active)),
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
async fn reject<T>(sink: &mut Sink, message: &str) -> Option<T> {
    let _ = send_frame(
        sink,
        &ServerFrame::Error {
            message: message.to_owned(),
        },
    )
    .await;
    None
}
