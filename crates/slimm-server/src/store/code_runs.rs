// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Shared code-block run results: one row per (message, fenced-block index),
//! replaced on each run so everyone viewing the message sees the latest output
//! inline without rerunning it.
//!
//! Read for a whole page of messages in one query, the same batch-enrich shape
//! reactions use - a query per row would be a query per message in a page.
//! Unlike reactions there is nothing per-viewer to filter: the output is the
//! same fact for everyone who can see the message at all, so this carries no
//! viewer argument and no blocklist step.

use sqlx::QueryBuilder;

use super::Store;
use crate::ids::{MessageId, UserId};

/// How much of a run's output is stored and broadcast. The module's own
/// `runtime.limits` bound what it can produce, but a shared row is read by
/// every viewer and rides the fan-out, so it is capped well below that here;
/// a longer output is truncated with a trailing marker rather than stored
/// whole.
pub const MAX_SHARED_OUTPUT_BYTES: usize = 64 * 1024;

/// One block's latest run, as stored.
#[derive(Debug, Clone)]
pub struct CodeRunSummary {
    pub block_index: i64,
    pub module_id: String,
    pub command: String,
    pub ok: bool,
    pub output: String,
    pub ran_by: Option<UserId>,
    pub ran_at: i64,
}

/// What a run writes: the block it ran, the command, and the result to share.
#[derive(Debug, Clone, Copy)]
pub struct CodeRunRecord<'a> {
    pub message_id: MessageId,
    pub block_index: i64,
    pub module_id: &'a str,
    pub command: &'a str,
    pub ok: bool,
    pub output: &'a str,
    pub ran_by: UserId,
}

/// Truncates `output` on a char boundary to [`MAX_SHARED_OUTPUT_BYTES`],
/// appending a marker when it had to cut, so a huge result becomes a bounded
/// shared row rather than a huge one fanned out to every viewer.
pub fn clamp_output(output: &str) -> String {
    if output.len() <= MAX_SHARED_OUTPUT_BYTES {
        return output.to_string();
    }
    let mut end = MAX_SHARED_OUTPUT_BYTES;
    while end > 0 && !output.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\n… (output truncated)", &output[..end])
}

impl Store {
    /// Records a block's run, replacing any previous result for that block.
    pub async fn record_code_run(&self, run: CodeRunRecord<'_>) -> anyhow::Result<i64> {
        let now = super::now_ms();
        sqlx::query(
            "INSERT INTO code_runs \
                 (message_id, block_index, module_id, command, ok, output, ran_by, ran_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?) \
             ON CONFLICT(message_id, block_index) DO UPDATE SET \
                 module_id = excluded.module_id, command = excluded.command, \
                 ok = excluded.ok, output = excluded.output, \
                 ran_by = excluded.ran_by, ran_at = excluded.ran_at",
        )
        .bind(run.message_id)
        .bind(run.block_index)
        .bind(run.module_id)
        .bind(run.command)
        .bind(run.ok as i64)
        .bind(run.output)
        .bind(run.ran_by)
        .bind(now)
        .execute(&self.pool)
        .await?;
        Ok(now)
    }

    /// Every stored run for a page of messages, in one query, grouped by
    /// message and ordered by block index. Returns only messages that have a
    /// run, so the caller treats a missing id as "none".
    pub async fn code_runs_for_messages(
        &self,
        message_ids: &[MessageId],
    ) -> anyhow::Result<Vec<(MessageId, Vec<CodeRunSummary>)>> {
        if message_ids.is_empty() {
            return Ok(Vec::new());
        }

        let mut builder = QueryBuilder::new(
            "SELECT message_id, block_index, module_id, command, ok, output, ran_by, ran_at \
             FROM code_runs WHERE message_id IN (",
        );
        let mut separated = builder.separated(", ");
        for id in message_ids {
            separated.push_bind(*id);
        }
        builder.push(") ORDER BY message_id, block_index ASC");

        let rows = builder.build().fetch_all(&self.pool).await?;

        use sqlx::Row;
        let mut grouped: Vec<(MessageId, Vec<CodeRunSummary>)> = Vec::new();
        for row in rows {
            let message_id: MessageId = row.try_get("message_id")?;
            let summary = CodeRunSummary {
                block_index: row.try_get("block_index")?,
                module_id: row.try_get("module_id")?,
                command: row.try_get("command")?,
                ok: row.try_get::<i64, _>("ok")? != 0,
                output: row.try_get("output")?,
                ran_by: row.try_get("ran_by")?,
                ran_at: row.try_get("ran_at")?,
            };
            match grouped.iter_mut().find(|(id, _)| *id == message_id) {
                Some((_, list)) => list.push(summary),
                None => grouped.push((message_id, vec![summary])),
            }
        }
        Ok(grouped)
    }
}
