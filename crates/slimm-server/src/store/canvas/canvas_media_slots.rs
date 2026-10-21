// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Where a call participant's camera or screen-share tile sits on a
//! channel's shared canvas - see migration `0040_canvas_media_slots.sql`
//! for why this is its own table rather than a `canvas_objects` row or a
//! `canvas_ops` kind.

use crate::ids::{ChannelId, UserId};

use super::super::{Store, now_ms};
use super::valid_bounds;

/// The two kinds of media tile a call can put on a canvas.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MediaSlotKind {
    Camera,
    Screen,
}

impl MediaSlotKind {
    pub fn as_str(self) -> &'static str {
        match self {
            MediaSlotKind::Camera => "camera",
            MediaSlotKind::Screen => "screen",
        }
    }

    /// `None` for anything but the two kinds the CHECK constraint on
    /// `canvas_media_slots.kind` allows, the same "an unknown kind is
    /// refused, never silently stored" shape `canvas_write.rs`'s own
    /// `KINDS` allowlist uses for a real object.
    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "camera" => Some(MediaSlotKind::Camera),
            "screen" => Some(MediaSlotKind::Screen),
            _ => None,
        }
    }
}

/// One participant's tile: where it sits, and how, identical for every
/// viewer of this channel's canvas.
#[derive(Debug, Clone)]
pub struct CanvasMediaSlot {
    pub channel_id: ChannelId,
    pub user_id: UserId,
    pub kind: MediaSlotKind,
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
    pub locked: bool,
    pub sent_to_back: bool,
    pub updated_at: i64,
}

/// Why upserting a slot failed.
#[derive(Debug)]
pub enum MediaSlotError {
    /// Not finite, negative extent, or outside the bounded world - the same
    /// check a real canvas object's own bounds already take.
    OutOfBounds,
    /// The slot is currently locked and this request would move or resize
    /// it while leaving it locked - see [`Store::upsert_canvas_media_slot`]'s
    /// own doc for why that is refused rather than silently applied.
    Locked,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for MediaSlotError {
    fn from(err: sqlx::Error) -> Self {
        MediaSlotError::Internal(err.into())
    }
}

impl Store {
    /// Creates or replaces one participant's tile, visible to every viewer
    /// of this channel's canvas from the moment this call commits.
    ///
    /// A plain upsert on the primary key `(channel_id, user_id, kind)`: two
    /// viewers racing to touch the same tile for the first time cannot
    /// create two rows, since SQLite's single writer serializes the pair and
    /// the second commit simply overwrites the first with its own answer.
    ///
    /// A currently-locked slot refuses a geometry change that would leave it
    /// locked - migration `0040`'s own doc calls this "the same shared-lock
    /// behaviour Figma and FigJam themselves use", which means nobody may
    /// drag a locked tile, not merely that the arranging client's own UI
    /// disables the gesture. Unlocking, relocking with the same geometry,
    /// and a depth toggle are all still free of this check: only a move or
    /// resize that would leave the tile locked is refused.
    pub async fn upsert_canvas_media_slot(
        &self,
        channel_id: ChannelId,
        user_id: UserId,
        kind: MediaSlotKind,
        bounds: (f64, f64, f64, f64),
        locked: bool,
        sent_to_back: bool,
    ) -> Result<CanvasMediaSlot, MediaSlotError> {
        let (x, y, w, h) = bounds;
        if !valid_bounds(x, y, w, h) {
            return Err(MediaSlotError::OutOfBounds);
        }
        let kind_str = kind.as_str();
        let now = now_ms();

        // Reads before deciding to write, so the write lock is taken up front (see `Store::begin_write`).
        let mut tx = self.begin_write().await?;
        let existing = sqlx::query!(
            r#"SELECT x AS "x!: f64", y AS "y!: f64", w AS "w!: f64", h AS "h!: f64",
                      locked AS "locked!: bool"
               FROM canvas_media_slots WHERE channel_id = ? AND user_id = ? AND kind = ?"#,
            channel_id,
            user_id,
            kind_str,
        )
        .fetch_optional(&mut *tx)
        .await?;
        if let Some(row) = &existing
            && row.locked
            && (row.x != x || row.y != y || row.w != w || row.h != h)
        {
            tx.commit().await?;
            return Err(MediaSlotError::Locked);
        }

        sqlx::query!(
            r#"INSERT INTO canvas_media_slots
                   (channel_id, user_id, kind, x, y, w, h, locked, sent_to_back, updated_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT (channel_id, user_id, kind) DO UPDATE SET
                   x = excluded.x, y = excluded.y, w = excluded.w, h = excluded.h,
                   locked = excluded.locked, sent_to_back = excluded.sent_to_back,
                   updated_at = excluded.updated_at"#,
            channel_id,
            user_id,
            kind_str,
            x,
            y,
            w,
            h,
            locked,
            sent_to_back,
            now,
        )
        .execute(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok(CanvasMediaSlot {
            channel_id,
            user_id,
            kind,
            x,
            y,
            w,
            h,
            locked,
            sent_to_back,
            updated_at: now,
        })
    }

    /// Every slot ever touched in this channel - bounded by however many
    /// distinct (participant, kind) pairs anyone has ever arranged, at most
    /// twice the channel's member count, which is small enough on this
    /// product's target scale that no page limit earns its cost the way
    /// `MAX_PINS_PER_CHANNEL` needed one.
    pub async fn list_canvas_media_slots(
        &self,
        channel_id: ChannelId,
    ) -> anyhow::Result<Vec<CanvasMediaSlot>> {
        let rows = sqlx::query!(
            r#"SELECT user_id AS "user_id!: UserId", kind AS "kind!",
                      x AS "x!: f64", y AS "y!: f64", w AS "w!: f64", h AS "h!: f64",
                      locked AS "locked!: bool", sent_to_back AS "sent_to_back!: bool",
                      updated_at AS "updated_at!: i64"
               FROM canvas_media_slots WHERE channel_id = ?"#,
            channel_id
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            // Skipped rather than trusted, the same degrade-away treatment an unparseable `props` object gets.
            .filter_map(|r| {
                Some(CanvasMediaSlot {
                    channel_id,
                    user_id: r.user_id,
                    kind: MediaSlotKind::parse(&r.kind)?,
                    x: r.x,
                    y: r.y,
                    w: r.w,
                    h: r.h,
                    locked: r.locked,
                    sent_to_back: r.sent_to_back,
                    updated_at: r.updated_at,
                })
            })
            .collect())
    }
}
