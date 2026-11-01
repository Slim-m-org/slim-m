// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The canvas half of [`crate::hub::Event`], split out so the hub enum stays readable.

use std::sync::Arc;

use crate::hub::screen_annotation::ScreenAnnotationEvent;
use crate::ids::{CanvasObjectId, CanvasOpId, ChannelId, Seq, UserId};
use crate::store::{CanvasObject, MediaSlotKind};

/// Something that happened on a channel's canvas; wrapped by [`crate::hub::Event::Canvas`].
#[derive(Debug, Clone)]
pub enum CanvasEvent {
    /// An object was placed on a channel's canvas.
    ///
    /// Carries the whole row for the same reason [`MessageEvent::Created`]
    /// does: a brand new object has no prior state to reconcile against, and
    /// an id-only frame would cost every connected viewer one viewport read
    /// per stroke. It is bounded by the write route's props ceiling, which is
    /// sized against [`crate::hub::CHANNEL_CAPACITY`] rather than against any
    /// one drawing.
    ///
    /// Published only for a fresh write. An idempotent replay answers from the
    /// stored row and publishes nothing, so a retry cannot fan a duplicate out.
    /// `object` is `Arc`-wrapped for the same reason [`MessageEvent::Created`]'s are.
    ObjectPlaced {
        channel_id: ChannelId,
        object: Arc<CanvasObject>,
    },
    /// Objects were removed from a channel's canvas.
    ///
    /// Ids only, the shape [`MessageEvent::Deleted`] already uses: a removal
    /// publishes an id rather than content, and the actor is deliberately
    /// absent so a moderation act does not name its moderator to the whole
    /// channel. Bounded at [`crate::store::MAX_REMOVE_IDS_PER_OP`], which is
    /// what keeps this inside both the frame ceiling and the hub's ring.
    ObjectsRemoved {
        channel_id: ChannelId,
        seq: Seq,
        op_id: CanvasOpId,
        object_ids: Vec<CanvasObjectId>,
    },
    /// Every object placed at or below `before_seq` was cleared at once.
    ///
    /// Carries no ids: a clear can cover a channel's whole live ceiling, and
    /// [`crate::hub::CHANNEL_CAPACITY`] buffers 1024 cloned events, so a
    /// 20,000-id frame is exactly what the props ceiling exists to stop one
    /// object doing. The locked objects it spared are named up to
    /// [`crate::store::MAX_REMOVE_IDS_PER_OP`]; `spared_count` is the true total,
    /// so a receiver seeing fewer ids than the count refetches.
    Cleared {
        channel_id: ChannelId,
        seq: Seq,
        op_id: CanvasOpId,
        before_seq: Seq,
        scope: crate::store::ClearScope,
        spared_ids: Vec<CanvasObjectId>,
        spared_count: i64,
    },
    /// A removal or a clear was undone.
    ///
    /// Ids only, the same shape [`CanvasEvent::ObjectsRemoved`] already uses -
    /// a receiver that cannot resurrect them locally refetches rather than
    /// being told what to redraw - but only up to
    /// [`crate::store::MAX_REMOVE_IDS_PER_OP`]. A restore of a `remove` is
    /// naturally at or under that bound already; a restore of a `clear` is
    /// not, and can reach the channel's whole live ceiling, exactly the shape
    /// [`CanvasEvent::Cleared`] carries no ids to avoid. Past the bound this
    /// carries none either, and a receiver falls back to a refetch.
    ObjectsRestored {
        channel_id: ChannelId,
        seq: Seq,
        op_id: CanvasOpId,
        object_ids: Vec<CanvasObjectId>,
    },
    /// A live pointer position on a channel's canvas, relayed as-is.
    ///
    /// Never persisted and carries no `seq`: unlike every other canvas event
    /// this is not a fact about `canvas_objects` or `canvas_ops`, only a
    /// this-instant hint, so there is nothing for a reconnecting or
    /// newly-arriving client to catch up on and no op-stream slot is spent on
    /// it. A receiver that misses one is not stale, it just has not been told
    /// yet; the sender's next move corrects it. There is no matching "stopped"
    /// event, the deliberate difference from [`crate::hub::Event::TypingStarted`]/
    /// [`crate::hub::Event::TypingStopped`]: a receiver ages a cursor out on its own after
    /// a short silence rather than trusting a stop frame the sender might
    /// never get to send (a closed tab sends nothing further either way).
    CursorMoved {
        channel_id: ChannelId,
        user_id: UserId,
        x: f64,
        y: f64,
        /// The pointer left the canvas: receivers hide the cursor at once
        /// instead of waiting out the staleness timer. `x` and `y` are then
        /// meaningless.
        left: bool,
    },
    /// A live in-flight stroke preview on a channel's canvas: the points a
    /// drawer's pen has added since their last preview frame for this
    /// object, relayed as-is.
    ///
    /// The same "never persisted, no seq, no matching catch-up path" shape
    /// [`CanvasEvent::CursorMoved`] already uses, extended to carry drawing
    /// content rather than a bare position - and content is exactly why
    /// `Store::timed_out_until` is checked before this publishes, where
    /// [`CanvasEvent::CursorMoved`] deliberately is not: a cursor carries no
    /// ink, this does, and a timed-out member may not add to the canvas by
    /// any route, this one included.
    ///
    /// `points` is a delta - only what was added since the sender's last
    /// frame for this `object_id` - never the whole path so far, or relaying
    /// a long stroke would cost every later frame more than the last. A
    /// receiver accumulates them locally, keyed by `object_id`. `ended`
    /// marks the gesture's last frame, whether or not it went on to commit a
    /// real object: a receiver drops the preview the instant it sees this
    /// rather than waiting for staleness to age it out.
    ///
    /// `object_id` never names a row in `canvas_objects`: it is a client-minted
    /// id keying this preview, since the committed objects are decided later.
    StrokePreview {
        channel_id: ChannelId,
        user_id: UserId,
        object_id: CanvasObjectId,
        points: Arc<Vec<f64>>,
        ended: bool,
        cancelled: bool,
        /// The drawer's pen colour key, when the sender named a valid one.
        color: Option<String>,
        /// The drawer's pen width in world units, when valid.
        width: Option<f64>,
    },
    /// An object mid-drag or mid-resize: the box its mover currently holds.
    ///
    /// Ephemeral like [`CanvasEvent::CursorMoved`]: no `seq`, never stored, and
    /// the committed [`CanvasEvent::ObjectMoved`] always settles the final
    /// box. `ended` tells receivers to stop interpolating.
    ObjectPreview {
        channel_id: ChannelId,
        user_id: UserId,
        object_id: CanvasObjectId,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        ended: bool,
    },
    /// A camera or screen-share tile mid-drag: the box its mover currently holds.
    ///
    /// Ephemeral like [`CanvasEvent::ObjectPreview`]; the committed
    /// [`CanvasEvent::MediaSlotChanged`] always settles the final box.
    MediaSlotPreview {
        channel_id: ChannelId,
        user_id: UserId,
        kind: MediaSlotKind,
        slot_user_id: UserId,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        ended: bool,
    },
    /// A viewer's annotation over, or a sharer's consent about, a screen share.
    ///
    /// Ephemeral like [`CanvasEvent::CursorMoved`]: no `seq`, never stored,
    /// the sharer's overlay fades it within seconds. Boxed so the payload does
    /// not widen every other variant.
    ScreenAnnotation(Box<ScreenAnnotationEvent>),
    /// The part of the shared board a member is looking at, in world units.
    ///
    /// Ephemeral like [`CanvasEvent::CursorMoved`]: no `seq`, never stored, a
    /// missed one is corrected by the next. `summon` asks every receiver to
    /// jump to this view once ("bring everyone to me"); without it the frame
    /// only matters to members following `user_id`.
    View {
        channel_id: ChannelId,
        user_id: UserId,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        summon: bool,
        /// The call tile `user_id` has full screen, for followers to open too.
        tile: Option<String>,
    },
    /// A placed object was repositioned.
    ///
    /// Carries the whole new box, the same reason [`CanvasEvent::ObjectPlaced`]
    /// carries the whole row: a receiver needs no refetch to draw it in its
    /// new place. The actor is deliberately absent, the shape
    /// [`CanvasEvent::ObjectsRemoved`] already uses, since moving another
    /// member's object needs `MANAGE_CANVAS` and so can be a moderation act
    /// the same way a removal is.
    ///
    /// Published only for a fresh, effective move. An idempotent replay, or a
    /// move naming an already-removed object, publishes nothing.
    ObjectMoved {
        channel_id: ChannelId,
        seq: Seq,
        op_id: CanvasOpId,
        object_id: CanvasObjectId,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
    },
    /// A placed object's paint order changed.
    ///
    /// Carries the new `z_index` outright, the same reason
    /// [`CanvasEvent::ObjectMoved`] carries the whole new box: a receiver
    /// needs no refetch to repaint it in its new stacking position. The
    /// actor is deliberately absent, the same shape [`CanvasEvent::ObjectMoved`]
    /// already uses, since restacking another member's object needs
    /// `MANAGE_CANVAS` and so can be a moderation act the same way a move is.
    ///
    /// Published only for a fresh, effective reorder. An idempotent replay,
    /// or a reorder naming an already-removed object, publishes nothing.
    ObjectReordered {
        channel_id: ChannelId,
        seq: Seq,
        op_id: CanvasOpId,
        object_id: CanvasObjectId,
        z_index: i64,
    },
    /// A note's props were replaced (decision 0072). Carries the whole new
    /// props so a receiver repaints without a refetch; the actor is absent for
    /// the reason [`CanvasEvent::ObjectMoved`] gives, since editing another
    /// member's note needs `MANAGE_CANVAS`.
    ObjectEdited {
        channel_id: ChannelId,
        seq: Seq,
        op_id: CanvasOpId,
        object_id: CanvasObjectId,
        props: String,
    },
    /// A participant's camera or screen-share tile was moved, resized,
    /// locked or sent to the back - decision 0010's reversal, which made
    /// this shared state rather than a per-viewer local one.
    ///
    /// Carries the whole current row, the same reason [`CanvasEvent::ObjectMoved`]
    /// does: a receiver needs no refetch to redraw the tile. `user_id` names
    /// the participant the tile represents, never who moved it - anyone with
    /// `USE_CANVAS` may rearrange anyone's tile, so there is no moderation
    /// story here for an actor field to serve the way a canvas object's
    /// move or reorder has one.
    ///
    /// Carries no `seq` and is never part of the canvas op stream: a slot
    /// mutates in place rather than appending a history, so there is
    /// nothing here for a reconnecting client to catch up on beyond a
    /// fresh `GET .../canvas/media-slots`.
    MediaSlotChanged {
        channel_id: ChannelId,
        kind: MediaSlotKind,
        user_id: UserId,
        x: f64,
        y: f64,
        w: f64,
        h: f64,
        locked: bool,
        sent_to_back: bool,
        /// Orders this against every other lock or slot change in the channel; see `store::canvas_state_version`.
        version: i64,
    },
    /// A canvas object was locked in place or unlocked; current state, not op history.
    ObjectLockChanged {
        channel_id: ChannelId,
        object_id: CanvasObjectId,
        locked: bool,
        /// Orders this against every other lock or slot change in the channel.
        version: i64,
    },
}
