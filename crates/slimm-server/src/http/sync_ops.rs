// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The message-op half of `POST /sync`.
//!
//! A sibling of [`super::sync`] rather than part of it, for the line budget.
//!
//! Riding `/sync` rather than taking a route of its own is the opposite of
//! what the canvas op feed does, and the reasons are opposite too: the canvas
//! cursor belongs to an open pane, so putting it here would make every client
//! pay for a surface most never open, while the message cursor is already in
//! `/sync` for exactly these channels and a per-channel route would make a
//! reconnect N requests, which is the one thing `/sync` exists to prevent.

use serde::Serialize;

use super::AppState;
use crate::ids::ChannelId;
use crate::store::{MessageOpEntry, MessageOpKind};

/// An op cursor further behind than this returns `reset` instead of a backlog.
pub(super) const OP_SNAPSHOT_GAP: i64 = 2_000;
/// Most ops returned for one scope.
pub(super) const OPS_PER_SCOPE_LIMIT: i64 = 100;

/// A ceiling on the whole `/sync` response, in bytes of serialized content.
///
/// The message half never had one: `AGGREGATE_LIMIT` bounds it at 500 rows and
/// `MAX_CONTENT_CHARS` bounds each at 4000, so an 8 MB response was already
/// reachable, and ops carry content too. This bounds both halves together
/// rather than giving each its own, since what a client has to hold is the sum.
pub(super) const SYNC_RESPONSE_BYTES: usize = 1024 * 1024;

/// One op on the wire.
///
/// No `actor_id`, on any kind, ever. `Event::MessageDeleted` carries only the
/// ids a live connection needs to drop it from view, and a catch-up feed that
/// named the moderator would hand every member, over a different route,
/// exactly what the live path withholds. The column exists in `message_ops`;
/// this struct deliberately has no field for it.
#[derive(Serialize)]
pub(super) struct MessageOpDto {
    pub seq: i64,
    pub kind: &'static str,
    pub message_id: String,
    pub created_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub edited_at: Option<i64>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub forwarded_removed: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub link_previews_removed: bool,
}

/// What the ops half contributed to one scope.
pub(super) struct OpsHalf {
    pub ops: Vec<MessageOpDto>,
    pub op_latest_seq: i64,
    pub ops_has_more: bool,
    /// The op cursor could not be answered from the stream, so the caller must
    /// set the response's existing `reset` rather than a flag of its own: the
    /// client's recovery is identical either way, and two flags would be two
    /// names for one path.
    pub reset: bool,
}

/// Reads one scope's ops, or answers empty when the request carried no cursor.
///
/// A request with no `after_op_seq` gets no ops and, crucially, can never be
/// told to reset from an op gap. That is what an older client always sends and
/// what a newer one sends before it has adopted a head, and both take this one
/// branch: evaluating the gap unconditionally is the mutation that would wipe
/// every old client's cache on the first connect after deploy.
pub(super) async fn ops_for_scope(
    state: &AppState,
    channel_id: ChannelId,
    after_op_seq: Option<i64>,
    byte_budget: &mut usize,
) -> anyhow::Result<OpsHalf> {
    let latest = state.store.latest_message_op_seq(channel_id).await?;
    let Some(after) = after_op_seq else {
        return Ok(OpsHalf {
            ops: Vec::new(),
            op_latest_seq: latest,
            ops_has_more: false,
            reset: false,
        });
    };

    let floor = state.store.earliest_message_op_seq(channel_id).await?;
    let floor = effective_floor(floor, latest);
    // `after > latest` is what a Litestream restore produces; see the reset doc.
    let reset =
        after > latest || latest.saturating_sub(after) > OP_SNAPSHOT_GAP || after < floor - 1;
    if reset {
        return Ok(OpsHalf {
            ops: Vec::new(),
            op_latest_seq: latest,
            ops_has_more: false,
            reset: true,
        });
    }

    let page = state
        .store
        .message_ops_since(channel_id, after, OPS_PER_SCOPE_LIMIT + 1)
        .await?;
    let mut entries = page.ops;
    let mut ops_has_more = entries.len() as i64 > OPS_PER_SCOPE_LIMIT;
    entries.truncate(OPS_PER_SCOPE_LIMIT as usize);

    let mut ops: Vec<MessageOpDto> = entries.into_iter().map(dto_from).collect();
    collapse_repeated_content(&mut ops);
    if trim_to_budget(&mut ops, byte_budget) {
        ops_has_more = true;
    }

    Ok(OpsHalf {
        ops,
        op_latest_seq: page.latest_seq,
        ops_has_more,
        reset: false,
    })
}

/// The floor to compare a cursor against, standing in for `None`.
///
/// `None` from [`crate::store::Store::earliest_message_op_seq`] used to mean
/// only one thing: this channel has never had an op, in which case `latest`
/// is always `0` too and no cursor a real client sends is ever below it. The
/// message-retention sweep's own op-log reclaim (`store/message_retention.rs`)
/// can now produce a second `None` case - every op row for a channel with a
/// nonzero `latest` has been reclaimed - and the two must not be conflated:
/// the second means nothing between any earlier cursor and `latest` can be
/// delivered any more, so every such cursor must reset. Standing in
/// `latest + 1` does exactly that (`after < latest + 1 - 1` is `after <
/// latest`), while leaving the true "never had an op" case at `latest == 0`
/// unaffected, since no legitimate cursor is ever negative.
fn effective_floor(floor: Option<i64>, latest: i64) -> i64 {
    floor.unwrap_or(latest + 1)
}

fn dto_from(entry: MessageOpEntry) -> MessageOpDto {
    let (kind, content, edited_at) = match entry.kind {
        MessageOpKind::Edit => ("edit", entry.content, entry.edited_at),
        MessageOpKind::Delete => ("delete", None, None),
    };
    MessageOpDto {
        seq: entry.seq,
        kind,
        message_id: entry.message_id.to_string(),
        created_at: entry.created_at,
        content,
        edited_at,
        forwarded_removed: entry.forwarded_removed,
        link_previews_removed: entry.link_previews_removed,
    }
}

/// Blanks the content on every op but the last naming a given message.
///
/// Content is the message's *current* text, so a message edited 500 times in
/// one page is 500 copies of the same string, which the byte budget would then
/// truncate into seventeen round trips.
///
/// A blanked op is not dropped: it keeps its seq and its row, so the cursor
/// still advances through it and the client's `+1` adjacency across a page
/// boundary is untouched. Dropping them instead would put a hole in the stream.
fn collapse_repeated_content(ops: &mut [MessageOpDto]) {
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    for op in ops.iter_mut().rev() {
        if op.content.is_none() {
            continue;
        }
        if !seen.insert(op.message_id.clone()) {
            op.content = None;
            op.edited_at = None;
        }
    }
}

/// Drops ops from the back until the page fits, answering whether it cut any.
///
/// The first op is always admitted however little budget is left. Without that
/// guarantee one message longer than the whole budget stalls the cursor
/// forever, which is a livelock rather than a slow sync.
fn trim_to_budget(ops: &mut Vec<MessageOpDto>, budget: &mut usize) -> bool {
    let mut kept = 0usize;
    for (i, op) in ops.iter().enumerate() {
        let cost = op.content.as_ref().map_or(0, std::string::String::len) + 64;
        if i > 0 && cost > *budget {
            break;
        }
        *budget = budget.saturating_sub(cost);
        kept = i + 1;
    }
    let trimmed = kept < ops.len();
    ops.truncate(kept);
    trimmed
}

#[cfg(test)]
mod tests {
    use super::{MessageOpDto, collapse_repeated_content, effective_floor, trim_to_budget};

    fn edit(id: &str, seq: i64, content: &str) -> MessageOpDto {
        MessageOpDto {
            seq,
            kind: "edit",
            message_id: id.to_owned(),
            created_at: 0,
            content: Some(content.to_owned()),
            edited_at: Some(seq),
            forwarded_removed: false,
            link_previews_removed: false,
        }
    }

    fn delete(id: &str, seq: i64) -> MessageOpDto {
        MessageOpDto {
            seq,
            kind: "delete",
            message_id: id.to_owned(),
            created_at: 0,
            content: None,
            edited_at: None,
            forwarded_removed: false,
            link_previews_removed: false,
        }
    }

    /// Several edits of one message in a batch collapse to only the last one
    /// carrying content: the client applies them in order, so every earlier
    /// body is about to be overwritten anyway and need not ride the wire.
    #[test]
    fn only_the_latest_edit_of_a_message_keeps_its_content() {
        let mut ops = vec![
            edit("m1", 1, "v1"),
            edit("m1", 2, "v2"),
            edit("m1", 3, "v3"),
        ];
        collapse_repeated_content(&mut ops);
        assert_eq!(ops[0].content, None);
        assert_eq!(ops[0].edited_at, None);
        assert_eq!(ops[1].content, None);
        assert_eq!(ops[2].content.as_deref(), Some("v3"));
    }

    #[test]
    fn edits_of_different_messages_are_all_kept() {
        let mut ops = vec![edit("m1", 1, "a"), edit("m2", 2, "b")];
        collapse_repeated_content(&mut ops);
        assert_eq!(ops[0].content.as_deref(), Some("a"));
        assert_eq!(ops[1].content.as_deref(), Some("b"));
    }

    /// A delete carries no content, so it is skipped rather than counted as a
    /// sighting of the message - a later delete must not blank the body of an
    /// edit the client still has to apply first.
    #[test]
    fn a_delete_does_not_collapse_an_earlier_edit() {
        let mut ops = vec![edit("m1", 1, "keep"), delete("m1", 2)];
        collapse_repeated_content(&mut ops);
        assert_eq!(ops[0].content.as_deref(), Some("keep"));
    }

    /// The first op is admitted however little budget is left, or one message
    /// bigger than the whole budget would stall the cursor on it forever - a
    /// livelock, not a slow sync.
    #[test]
    fn the_first_op_is_always_admitted_even_past_budget() {
        let mut ops = vec![edit("m1", 1, &"x".repeat(500))];
        let mut budget = 10usize;
        assert!(!trim_to_budget(&mut ops, &mut budget));
        assert_eq!(ops.len(), 1);
        assert_eq!(
            budget, 0,
            "an over-budget first op saturates the budget to 0"
        );
    }

    #[test]
    fn a_later_op_that_does_not_fit_is_trimmed_and_the_budget_is_spent() {
        let mut ops = vec![edit("m1", 1, "a"), edit("m2", 2, &"y".repeat(500))];
        let mut budget = 100usize; // first op costs 1+64; the second's 500+64 will not fit
        assert!(trim_to_budget(&mut ops, &mut budget));
        assert_eq!(ops.len(), 1);
        assert_eq!(ops[0].message_id, "m1");
    }

    #[test]
    fn a_page_within_budget_is_untouched_and_spends_each_op() {
        let mut ops = vec![edit("m1", 1, "a"), edit("m2", 2, "b")];
        let mut budget = 1000usize;
        assert!(!trim_to_budget(&mut ops, &mut budget));
        assert_eq!(ops.len(), 2);
        assert_eq!(budget, 1000 - (1 + 64) - (1 + 64));
    }

    /// A reclaimed op log returns `None` for its floor, which must stand in as
    /// `latest + 1` so every earlier cursor resets - while the never-had-an-op
    /// case (`latest == 0`) is left alone, since no real cursor is negative.
    #[test]
    fn effective_floor_forces_a_reset_only_for_a_reclaimed_log() {
        assert_eq!(effective_floor(Some(5), 10), 5);
        assert_eq!(effective_floor(None, 10), 11);
        assert_eq!(effective_floor(None, 0), 1);
    }
}
