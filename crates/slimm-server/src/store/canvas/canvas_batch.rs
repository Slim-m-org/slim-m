// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Placing many objects in one transaction, and the steps the single place shares with it.

use super::{
    CanvasObject, PlaceError, PlaceRequest, Placement, Store, channel_key, fetch_object,
    insert_place_op, next_canvas_seq, now_ms, valid_bounds,
};
use crate::ids::{CanvasObjectId, ChannelId, Seq, UserId};

/// One object of a batch: its id and what a single place would take.
pub struct BatchItem<'a> {
    pub id: CanvasObjectId,
    pub request: PlaceRequest<'a>,
}

/// A batch refused: which object, and why.
#[derive(Debug)]
pub struct BatchError {
    pub index: usize,
    pub error: PlaceError,
}

impl Store {
    /// The checks a place makes before it takes the write lock: bounds, and an image's attachment.
    pub(super) async fn check_place_request(
        &self,
        author_id: UserId,
        request: &PlaceRequest<'_>,
    ) -> Result<(), PlaceError> {
        let (x, y, w, h) = request.bounds;
        if !valid_bounds(x, y, w, h) {
            return Err(PlaceError::OutOfBounds);
        }
        let Some(sha256) = request.attachment else {
            return Ok(());
        };
        if !super::super::attachments::may_link(self, author_id, sha256).await? {
            return Err(PlaceError::AttachmentNotFound);
        }
        let summary = self
            .attachment_summary(sha256)
            .await
            .map_err(PlaceError::Internal)?
            .ok_or(PlaceError::AttachmentNotFound)?;
        if !crate::media::is_inline(&summary.content_type) {
            return Err(PlaceError::NotAPicture);
        }
        Ok(())
    }

    /// Places every item or none, in one transaction with dense seqs in item order.
    ///
    /// An item whose id is already placed in this channel answers with the stored row, so a
    /// retried batch returns what the first try wrote and fans out nothing for it.
    pub async fn place_canvas_objects(
        &self,
        channel_id: ChannelId,
        author_id: UserId,
        items: &[BatchItem<'_>],
    ) -> Result<Vec<Placement>, BatchError> {
        for (index, item) in items.iter().enumerate() {
            self.check_place_request(author_id, &item.request)
                .await
                .map_err(|error| BatchError { index, error })?;
        }
        let at = |index| move |error: PlaceError| BatchError { index, error };
        let mut tx = self.begin_write().await.map_err(|e| at(0)(e.into()))?;
        let mut existing = Vec::with_capacity(items.len());
        for (index, item) in items.iter().enumerate() {
            let found = existing_placement(&mut tx, channel_id, item.id)
                .await
                .map_err(at(index))?;
            existing.push(found);
        }
        let fresh = existing.iter().filter(|found| found.is_none()).count();
        if fresh > 0 {
            let first = existing.iter().position(Option::is_none).unwrap_or(0);
            ensure_room(&mut tx, channel_id, fresh as i64)
                .await
                .map_err(at(first))?;
        }
        let mut placed = Vec::with_capacity(items.len());
        for (index, (item, found)) in items.iter().zip(existing).enumerate() {
            placed.push(match found {
                Some(found) => found,
                None => insert_object(&mut tx, channel_id, author_id, item.id, &item.request)
                    .await
                    .map_err(at(index))?,
            });
        }
        tx.commit().await.map_err(|e| at(0)(e.into()))?;
        Ok(placed)
    }
}

/// The stored row when `id` is already placed here; an error when it is removed or belongs elsewhere.
pub(super) async fn existing_placement(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    id: CanvasObjectId,
) -> Result<Option<Placement>, PlaceError> {
    let Some(existing) = fetch_object(tx, id).await? else {
        return Ok(None);
    };
    match (existing.0 == channel_id, existing.1) {
        (true, false) => Ok(Some(Placement {
            object: existing.2,
            fresh: false,
        })),
        (true, true) => Err(PlaceError::Removed),
        // A removed row keeps the id, so falling through would be a UNIQUE violation reported as a 500.
        (false, _) => Err(PlaceError::IdConflict),
    }
}

/// Refuses when `adding` more live objects would pass the channel's cap.
pub(super) async fn ensure_room(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    adding: i64,
) -> Result<(), PlaceError> {
    let live = sqlx::query_scalar!(
        r#"SELECT COUNT(*) AS "count!: i64" FROM canvas_objects
           WHERE channel_id = ? AND deleted_at IS NULL"#,
        channel_id
    )
    .fetch_one(&mut **tx)
    .await?;
    // Read in this same write transaction as the count above it.
    let cap = super::super::space::read_canvas_object_cap(&mut **tx).await?;
    if live + adding > cap {
        return Err(PlaceError::ChannelFull);
    }
    Ok(())
}

/// Writes one object and its place op, taking the next seq; the caller commits.
pub(super) async fn insert_object(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    channel_id: ChannelId,
    author_id: UserId,
    id: CanvasObjectId,
    request: &PlaceRequest<'_>,
) -> Result<Placement, PlaceError> {
    let (kind, props, attachment) = (request.kind, request.props, request.attachment);
    let (x, y, w, h) = request.bounds;
    let seq = next_canvas_seq(tx, channel_id).await?;
    let key = channel_key(channel_id);
    let now = now_ms();
    // `z_index` starts as `seq`, so paint order is draw order until an object is raised.
    sqlx::query!(
        r#"INSERT INTO canvas_objects
               (id, channel_id, channel_key, kind, z_index, x, y, w, h,
                author_id, seq, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"#,
        id,
        channel_id,
        key,
        kind,
        seq,
        x,
        y,
        w,
        h,
        author_id,
        seq,
        now
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "INSERT INTO canvas_object_props (object_id, props) VALUES (?, ?)",
        id,
        props
    )
    .execute(&mut **tx)
    .await?;
    if let Some(sha256) = attachment {
        sqlx::query!(
            "INSERT INTO canvas_object_attachments (object_id, sha256) VALUES (?, ?)",
            id,
            sha256
        )
        .execute(&mut **tx)
        .await?;
    }
    // Same transaction, same seq, or the op stream stops being dense.
    insert_place_op(tx, channel_id, seq, author_id, id, now).await?;
    Ok(Placement {
        object: CanvasObject {
            id,
            kind: kind.to_owned(),
            z_index: seq,
            x,
            y,
            w,
            h,
            props: props.to_owned(),
            author_id: Some(author_id),
            seq: Seq(seq),
            created_at: now,
        },
        fresh: true,
    })
}
