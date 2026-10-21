// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The frames a client sends over the socket.

use serde::Deserialize;

#[derive(Deserialize)]
#[serde(tag = "type")]
pub(super) enum ClientFrame {
    #[serde(rename = "hello")]
    Hello {
        ticket: String,
        protocol: u32,
        /// Present when the client reports activity with `active` frames, and
        /// then says whether the person is at the device right now.
        #[serde(default)]
        active: Option<bool>,
    },
    #[serde(rename = "ping")]
    Ping,
    /// The person used this device recently. Once a connection sends one, its
    /// pings stop counting as activity, so an unattended client goes away.
    #[serde(rename = "active")]
    Active,
    /// A typing refresh. Rate-limited and authorized like any other channel
    /// event (view plus send); see [`super::signals::handle_typing`]. There is
    /// no explicit "stop" frame: the state lapses on its own without a refresh.
    #[serde(rename = "typing")]
    Typing { channel_id: String },
    /// The channels this connection has open and focused right now, replacing
    /// its previous report; empty when none. Lapses after
    /// [`crate::viewing::VIEWING_TTL`], so a client refreshes it periodically.
    /// Used only to skip push for what this account is already reading.
    /// `active` says the user has used this device recently, which skips
    /// message pushes to their other devices for a short while.
    #[serde(rename = "viewing")]
    Viewing {
        channel_ids: Vec<String>,
        #[serde(default)]
        active: bool,
    },
    /// A pointer position on a channel's canvas. Rate-limited and authorized
    /// the same bar the canvas HTTP routes use (view plus `USE_CANVAS`); see
    /// [`super::signals::handle_canvas_cursor`]. No "stop" frame either, for
    /// the reason [`crate::hub::Event::CanvasCursorMoved`] gives.
    #[serde(rename = "canvas.cursor")]
    CanvasCursor {
        channel_id: String,
        x: f64,
        y: f64,
        /// The pointer left the canvas; see [`crate::hub::Event::CanvasCursorMoved`].
        #[serde(default)]
        left: bool,
    },
    /// An in-flight stroke preview on a channel's canvas. Rate-limited by the
    /// frame's own byte size rather than by count, and authorized on the same
    /// bar the canvas write route uses (view plus `USE_CANVAS`, plus a direct
    /// timeout check a cursor frame does not need, since this one carries
    /// drawing content); see
    /// [`super::signals::handle_canvas_stroke_preview`].
    #[serde(rename = "canvas.stroke_preview")]
    CanvasStrokePreview {
        channel_id: String,
        object_id: String,
        points: Vec<f64>,
        #[serde(default)]
        ended: bool,
    },
    /// The box of an object this client is dragging or resizing, so others
    /// can follow it before the move commits. Gated like a cursor, plus a
    /// timeout check; see [`super::signals::handle_canvas_object_preview`].
    #[serde(rename = "canvas.object_preview")]
    CanvasObjectPreview {
        channel_id: String,
        object_id: String,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        #[serde(default)]
        ended: bool,
    },
    /// The world rectangle this client is looking at, so others can follow it
    /// or be summoned to it; gated like a cursor, see
    /// [`super::signals::handle_canvas_view`].
    #[serde(rename = "canvas.view")]
    CanvasView {
        channel_id: String,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        #[serde(default)]
        summon: bool,
    },
}
