// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The one definition of "something still references this blob", shared by the
//! orphan sweep and both release paths.

use sqlx::QueryBuilder;

use crate::ids::MessageId;

/// Tables whose rows keep an `attachments` row alive. `canvas_object_attachments` has no ON
/// DELETE guard, so a holder missing here fails the FK on delete or sweeps a live blob.
const HOLDER_TABLES: [&str; 3] = [
    "message_attachments",
    "custom_emoji",
    "canvas_object_attachments",
];

/// SQL true when a permanent holder references the blob whose hash is `sha_column`.
pub(super) fn held_sql(sha_column: &str) -> String {
    HOLDER_TABLES
        .iter()
        .map(|table| format!("EXISTS (SELECT 1 FROM {table} h WHERE h.sha256 = {sha_column})"))
        .collect::<Vec<_>>()
        .join(" OR ")
}

/// Whether the blob `sha256` must outlive the release of `releasing` messages: a permanent
/// holder, or an upload from someone other than those messages' authors still inside the
/// compose window (`pending_cutoff` is its start), which the orphan sweep reclaims later.
pub(super) async fn is_referenced(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    sha256: &[u8],
    releasing: &[MessageId],
    pending_cutoff: i64,
) -> Result<bool, sqlx::Error> {
    let mut query = QueryBuilder::new("SELECT (");
    query.push(held_sql("t.sha"));
    query.push(
        ") OR EXISTS (SELECT 1 FROM attachment_uploaders u WHERE u.sha256 = t.sha \
         AND u.uploaded_at >= ",
    );
    query.push_bind(pending_cutoff);
    query.push(
        " AND u.uploaded_by NOT IN (SELECT author_id FROM messages \
         WHERE author_id IS NOT NULL AND id IN (",
    );
    let mut ids = query.separated(", ");
    for id in releasing {
        ids.push_bind(*id);
    }
    query.push("))) FROM (SELECT ");
    query.push_bind(sha256);
    query.push(" AS sha) t");
    query
        .build_query_scalar::<bool>()
        .fetch_one(&mut **tx)
        .await
}
