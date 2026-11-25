// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! How long an export holds the writer lock, at three board sizes (decision 0139, 4.5).
//!
//! Run once with `cargo nextest run --release --run-ignored only -E 'test(canvas_export_measure)' --no-capture`;
//! `MAX_EXPORT_OBJECTS` is the largest size here that stays under a second, rounded down.

use std::time::Instant;

use serde_json::json;
use slimm_server::ids::{CanvasObjectId, ChannelId};
use slimm_server::store::ExportRequest;

use crate::canvas_export::Rig;

/// A busy board's mix: mostly ink, a fifth notes, a tenth connectors, a few of everything else.
const SHARES: [(&str, usize); 8] = [
    ("stroke", 50),
    ("note", 20),
    ("edge", 10),
    ("text", 6),
    ("shape", 6),
    ("image", 4),
    ("emoji", 3),
    ("module", 1),
];

fn kind_at(position: usize) -> &'static str {
    let mut slot = position % 100;
    for (kind, share) in SHARES {
        if slot < share {
            return kind;
        }
        slot -= share;
    }
    "stroke"
}

async fn seed(rig: &Rig, count: usize) {
    let channel = rig.source;
    let key = i64::from(channel.0.as_bytes()[15]);
    let points: Vec<f64> = (0..120).map(|n| f64::from(n) * 1.5).collect();
    let stroke = json!({ "points": points, "width": 3.0, "color": "annotation" }).to_string();
    let hashes: Vec<Vec<u8>> = (0..8u8).map(|n| vec![n; 32]).collect();
    let mut tx = rig.pool.begin().await.unwrap();
    for hash in &hashes {
        sqlx::query("INSERT INTO attachments (sha256, size, content_type, created_at) VALUES (?, 8, 'image/png', 1)")
            .bind(hash)
            .execute(&mut *tx)
            .await
            .unwrap();
    }
    sqlx::query("INSERT OR IGNORE INTO installed_modules (id, name, version, artifact_sha256, enabled, installed_at) VALUES ('board', 'Board', '0.1.0', 'x', 1, 0)")
        .execute(&mut *tx)
        .await
        .unwrap();
    let ids: Vec<CanvasObjectId> = (0..count).map(|_| CanvasObjectId::generate()).collect();
    let attachable: Vec<usize> = (0..count)
        .filter(|&i| {
            matches!(
                kind_at(i),
                "note" | "text" | "shape" | "image" | "emoji" | "module"
            )
        })
        .collect();
    let mut next_edge = 0usize;
    for (i, id) in ids.iter().enumerate() {
        let kind = kind_at(i);
        let props = match kind {
            "stroke" => stroke.clone(),
            "note" => json!({ "text": format!("note {i}"), "color": "annotation" }).to_string(),
            "text" => json!({ "text": format!("label {i}") }).to_string(),
            "shape" => json!({ "shape": "ellipse" }).to_string(),
            "emoji" => json!({ "emoji": "x" }).to_string(),
            "image" => json!({ "attachment": "00", "content_type": "image/png" }).to_string(),
            "module" => json!({ "module_id": "board", "tile": "Board" }).to_string(),
            _ => {
                let from = ids[attachable[next_edge % attachable.len()]];
                let to = ids[attachable[(next_edge + 1) % attachable.len()]];
                next_edge += 1;
                json!({ "from": { "object_id": from.to_string(), "side": "right" },
                        "to": { "object_id": to.to_string(), "side": "left" } })
                .to_string()
            }
        };
        let seq = i as i64 + 1;
        let (x, y) = ((i % 200) as f64 * 40.0, (i / 200) as f64 * 40.0);
        sqlx::query(
            "INSERT INTO canvas_objects (id, channel_id, channel_key, kind, z_index, x, y, w, h, author_id, seq, created_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?, 100, 50, ?, ?, 1)",
        )
        .bind(id)
        .bind(channel)
        .bind(key)
        .bind(kind)
        .bind(seq)
        .bind(x)
        .bind(y)
        .bind(rig.admin)
        .bind(seq)
        .execute(&mut *tx)
        .await
        .unwrap();
        sqlx::query("INSERT INTO canvas_object_props (object_id, props) VALUES (?, ?)")
            .bind(id)
            .bind(&props)
            .execute(&mut *tx)
            .await
            .unwrap();
        sqlx::query("INSERT INTO canvas_ops (channel_id, seq, id, kind, actor_id, created_at) VALUES (?, ?, ?, 'place', ?, 1)")
            .bind(channel)
            .bind(seq)
            .bind(slimm_server::ids::CanvasOpId::generate())
            .bind(rig.admin)
            .execute(&mut *tx)
            .await
            .unwrap();
        if kind == "image" {
            sqlx::query("INSERT INTO canvas_object_attachments (object_id, sha256) VALUES (?, ?)")
                .bind(id)
                .bind(&hashes[i % hashes.len()])
                .execute(&mut *tx)
                .await
                .unwrap();
        }
        if kind == "note" && i % 50 == 0 {
            sqlx::query("INSERT INTO canvas_object_locks (object_id, channel_id, locked_by, locked_at) VALUES (?, ?, ?, 1)")
                .bind(id)
                .bind(channel)
                .bind(rig.admin)
                .execute(&mut *tx)
                .await
                .unwrap();
        }
        if kind == "module" {
            sqlx::query("INSERT INTO canvas_tile_scenes (object_id, channel_id, output, ran_at) VALUES (?, ?, 'frame', 1)")
                .bind(id)
                .bind(channel)
                .execute(&mut *tx)
                .await
                .unwrap();
        }
    }
    sqlx::query(
        "UPDATE channel_seq_counters SET next_seq = ? WHERE channel_id = ? AND stream = 'canvas'",
    )
    .bind(count as i64 + 1)
    .bind(channel)
    .execute(&mut *tx)
    .await
    .unwrap();
    tx.commit().await.unwrap();
    wire_edge_ends(rig).await;
}

/// The end rows a placed edge would have written, so a clear cascades as it does on a real board.
async fn wire_edge_ends(rig: &Rig) {
    for end in ["from", "to"] {
        sqlx::query(sqlx::AssertSqlSafe(format!(
            "INSERT INTO canvas_edge_ends (edge_id, endpoint, object_id) \
             SELECT o.id, '{end}', unhex(replace(json_extract(p.props, '$.{end}.object_id'), '-', '')) \
             FROM canvas_objects o JOIN canvas_object_props p ON p.object_id = o.id WHERE o.kind = 'edge'"
        )))
        .execute(&rig.pool)
        .await
        .unwrap();
    }
}

async fn timed(rig: &Rig, clear: bool) -> (u128, i64, i64) {
    let started = Instant::now();
    let done = rig
        .store
        .export_canvas_to_new_channel(ExportRequest {
            id: ChannelId::generate(),
            source_id: rig.source,
            actor_id: rig.admin,
            name: "copy",
            category_id: None,
            voice_enabled: false,
            clear_source: clear,
        })
        .await
        .unwrap();
    (started.elapsed().as_millis(), done.copied, done.skipped)
}

#[tokio::test]
#[ignore = "a timing run, once with --release"]
async fn canvas_export_measure_the_writer_lock_at_three_sizes() {
    println!("objects | copy ms | copy+clear ms | copied | skipped");
    for count in [1_000usize, 5_000, 20_000] {
        let rig = Rig::new().await;
        rig.store.set_canvas_object_cap(100_000).await.unwrap();
        seed(&rig, count).await;
        let (copy, copied, skipped) = timed(&rig, false).await;
        let (with_clear, _, _) = timed(&rig, true).await;
        println!("{count} | {copy} | {with_clear} | {copied} | {skipped}");
    }
}
