// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The invariants checked between steps: the table against the oracle, the
//! feed against the table, the viewport read against a brute-force filter,
//! and the op log against its own structure.

use std::collections::{BTreeMap, HashSet};

use slimm_server::ids::CanvasObjectId;
use slimm_server::store::{Rect, ViewportQuery};
use sqlx::Row;

use crate::oracle::valid;
use crate::replay::{Client, Held, first_diff, whole_world};
use crate::script::Bounds;
use crate::world::{Check, World, v};

use crate::support::canvas::DAY_MS;

pub struct TableRow {
    pub held: Held,
}

fn intersects(b: Bounds, view: Rect) -> bool {
    b.0 <= view.max_x && b.0 + b.2 >= view.min_x && b.1 <= view.max_y && b.1 + b.3 >= view.min_y
}

impl World {
    pub async fn table(&self) -> Result<BTreeMap<CanvasObjectId, TableRow>, String> {
        let rows = sqlx::query(
            "SELECT id, kind, author_id, seq, x, y, w, h, z_index, props, deleted_at
             FROM canvas_objects WHERE channel_id = ?",
        )
        .bind(self.channel)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| e.to_string())?;
        let mut table = BTreeMap::new();
        for r in rows {
            let id: CanvasObjectId = r.try_get("id").map_err(|e| e.to_string())?;
            let deleted_at: Option<i64> = r.try_get("deleted_at").map_err(|e| e.to_string())?;
            let held = Held {
                kind: r.try_get("kind").map_err(|e| e.to_string())?,
                author: r.try_get("author_id").map_err(|e| e.to_string())?,
                seq: r.try_get("seq").map_err(|e| e.to_string())?,
                b: (r.get("x"), r.get("y"), r.get("w"), r.get("h")),
                z: r.try_get("z_index").map_err(|e| e.to_string())?,
                props: r.try_get("props").map_err(|e| e.to_string())?,
                alive: deleted_at.is_none(),
            };
            table.insert(id, TableRow { held });
        }
        Ok(table)
    }

    pub async fn table_alive(&self) -> Result<BTreeMap<CanvasObjectId, Held>, String> {
        let table = self.table().await?;
        Ok(table
            .into_iter()
            .filter(|(_, r)| r.held.alive)
            .map(|(id, r)| (id, r.held))
            .collect())
    }

    async fn scalar(&self, sql: &str) -> Result<i64, String> {
        sqlx::query_scalar(sql)
            .bind(self.channel)
            .fetch_one(&self.pool)
            .await
            .map_err(|e| e.to_string())
    }

    pub async fn check_cheap(&self, i: usize) -> Check {
        let table = self.table().await.map_err(|e| v("table:read", i, e))?;
        for (label, o) in &self.oracle.objs {
            let id = self.obj_ids[label];
            let Some(row) = table.get(&id) else {
                return Err(v(
                    "table:missing_row",
                    i,
                    format!("object {label} is not in canvas_objects"),
                ));
            };
            let h = &row.held;
            let same = h.kind == o.kind.as_str()
                && h.author == Some(self.writers[o.author])
                && h.seq == o.seq
                && h.b == o.b
                && h.z == o.z
                && h.props == o.props
                && h.alive == o.alive;
            if !same {
                return Err(v(
                    "table:diverged_from_oracle",
                    i,
                    format!("object {label}: table {h:?} vs oracle {o:?}"),
                ));
            }
        }
        if table.len() != self.oracle.objs.len() {
            return Err(v(
                "table:unknown_row",
                i,
                format!("{} rows vs {} placed", table.len(), self.oracle.objs.len()),
            ));
        }
        let latest = self.scalar("SELECT next_seq - 1 FROM channel_seq_counters WHERE channel_id = ? AND stream = 'canvas'").await.map_err(|e| v("seq:read", i, e))?;
        if latest != self.oracle.latest {
            return Err(v(
                "seq:diverged",
                i,
                format!("counter {latest} vs oracle {}", self.oracle.latest),
            ));
        }
        let rtree: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM canvas_rtree")
            .fetch_one(&self.pool)
            .await
            .map_err(|e| v("rtree:read", i, e.to_string()))?;
        if rtree != self.oracle.live() {
            return Err(v(
                "rtree:count",
                i,
                format!("{rtree} index rows vs {} live objects", self.oracle.live()),
            ));
        }
        self.check_locks(i).await
    }

    async fn check_locks(&self, i: usize) -> Check {
        let got: HashSet<CanvasObjectId> = self
            .store
            .list_canvas_object_locks(self.channel)
            .await
            .map_err(|e| v("locks:read", i, e.to_string()))?
            .into_iter()
            .collect();
        let want: HashSet<CanvasObjectId> = self
            .oracle
            .objs
            .iter()
            .filter(|(_, o)| o.alive && o.locked)
            .map(|(l, _)| self.obj_ids[l])
            .collect();
        if got != want {
            return Err(v(
                "locks:list",
                i,
                format!("store lists {} locked, oracle {}", got.len(), want.len()),
            ));
        }
        Ok(())
    }

    pub async fn check_deep(&mut self, i: usize) -> Check {
        let table = self.table().await.map_err(|e| v("table:read", i, e))?;
        if let Some((id, row)) = table.iter().find(|(_, r)| !valid(r.held.b)) {
            return Err(v(
                "containment:stored_out_of_bounds",
                i,
                format!("{id} holds {:?}", row.held.b),
            ));
        }
        let want: BTreeMap<_, _> = table
            .iter()
            .filter(|(_, r)| r.held.alive)
            .map(|(id, r)| (*id, r.held.clone()))
            .collect();
        let pages = if self.replay_broken {
            vec![]
        } else {
            vec![1, 1 + self.rng.below(9) as i64, 500]
        };
        for page in pages {
            let mut client = Client::default();
            client
                .catch_up(&self.store, self.channel, page, false)
                .await
                .map_err(|e| v("replay:feed", i, e))?;
            if let Some(diff) = first_diff(
                &format!("replay from 0 (page {page})"),
                &client.alive(),
                &want,
            ) {
                if !self.swept_once {
                    return Err(v("replay:diverged_from_table", i, diff));
                }
                self.soft
                    .push(v("sweep:replay_diverged_from_table", i, diff));
                self.replay_broken = true;
                break;
            }
        }
        self.check_log(i).await?;
        self.check_windows(i, &want).await
    }

    async fn check_log(&self, i: usize) -> Check {
        let rows = sqlx::query(
            "SELECT seq, kind, created_at FROM canvas_ops WHERE channel_id = ? ORDER BY seq",
        )
        .bind(self.channel)
        .fetch_all(&self.pool)
        .await
        .map_err(|e| v("log:read", i, e.to_string()))?;
        let mut stamps = HashSet::new();
        let mut places = 0;
        for (n, r) in rows.iter().enumerate() {
            let seq: i64 = r.get("seq");
            let kind: String = r.get("kind");
            let created: i64 = r.get("created_at");
            if !self.swept_once && seq != n as i64 + 1 {
                return Err(v("log:not_dense", i, format!("row {n} holds seq {seq}")));
            }
            if seq > self.oracle.latest {
                return Err(v(
                    "log:seq_past_counter",
                    i,
                    format!("seq {seq} beyond {}", self.oracle.latest),
                ));
            }
            if kind == "place" {
                places += 1;
            } else if !stamps.insert(created) {
                return Err(v(
                    "log:duplicate_op_timestamp",
                    i,
                    format!("two non-place ops share created_at {created}"),
                ));
            }
        }
        if places != self.oracle.objs.len() {
            return Err(v(
                "log:place_rows",
                i,
                format!("{places} place rows for {} objects", self.oracle.objs.len()),
            ));
        }
        let audit = self
            .scalar("SELECT COUNT(*) FROM canvas_audit_log WHERE channel_id = ?")
            .await
            .map_err(|e| v("audit:read", i, e))?;
        if audit != self.oracle.audit {
            return Err(v(
                "audit:count",
                i,
                format!(
                    "{audit} audit rows vs {} touched by moderation ops",
                    self.oracle.audit
                ),
            ));
        }
        Ok(())
    }

    fn windows(
        &self,
        alive: &BTreeMap<CanvasObjectId, Held>,
    ) -> Vec<(Rect, Option<Rect>, i64, i64)> {
        let latest = self.oracle.latest;
        let mut out = Vec::new();
        for (n, half) in [10.0, 100.0, 1000.0, 4000.0].into_iter().enumerate() {
            let view = Rect {
                min_x: -half,
                max_x: half,
                min_y: -half,
                max_y: half,
            };
            let previous = (n % 2 == 1).then_some(Rect {
                min_x: 0.0,
                max_x: half + 400.0,
                min_y: -half,
                max_y: half,
            });
            out.push((view, previous, latest / 2, 1_000_000));
            out.push((view, previous, latest / 3, 2));
        }
        let mut by_seq: Vec<&Held> = alive.values().collect();
        by_seq.sort_by_key(|h| h.seq);
        let step = (by_seq.len() / 24).max(1);
        for h in by_seq.into_iter().step_by(step) {
            let (x, y, w, hgt) = h.b;
            for off in [-0.5, -0.25, 0.0, 0.25, 0.5] {
                let right = Rect {
                    min_x: x + w + off,
                    max_x: x + w + off + 5.0,
                    min_y: y - 5.0,
                    max_y: y + hgt + 5.0,
                };
                let left = Rect {
                    min_x: x - 5.0 - off,
                    max_x: x - off,
                    min_y: y - 5.0,
                    max_y: y + hgt + 5.0,
                };
                let below = Rect {
                    min_x: x - 5.0,
                    max_x: x + w + 5.0,
                    min_y: y + hgt + off,
                    max_y: y + hgt + off + 5.0,
                };
                out.extend([right, left, below].map(|r| (r, None, 0, 1_000_000)));
            }
        }
        out
    }

    async fn check_windows(&mut self, i: usize, alive: &BTreeMap<CanvasObjectId, Held>) -> Check {
        for (view, previous, after_seq, limit) in self.windows(alive) {
            let query = ViewportQuery {
                view,
                previous,
                after_seq,
                limit,
            };
            let mut want: Vec<(&CanvasObjectId, &Held)> = alive
                .iter()
                .filter(|(_, h)| intersects(h.b, view))
                .filter(|(_, h)| previous.is_none_or(|p| h.seq > after_seq || !intersects(h.b, p)))
                .collect();
            want.sort_by_key(|(_, h)| (h.z, h.seq));
            let skip = want.len().saturating_sub(limit as usize);
            let want: Vec<(&CanvasObjectId, &Held)> = want.into_iter().skip(skip).collect();
            let (_, objects) = self
                .store
                .viewport_snapshot(self.channel, &query)
                .await
                .map_err(|e| v("viewport:read", i, e.to_string()))?;
            let got: Vec<CanvasObjectId> = objects.iter().map(|o| o.id).collect();
            let want_ids: Vec<CanvasObjectId> = want.iter().map(|(id, _)| **id).collect();
            if got != want_ids {
                let missing: Vec<_> = want
                    .iter()
                    .filter(|(id, _)| !got.contains(id))
                    .map(|(_, h)| h.b)
                    .take(3)
                    .collect();
                let extra: Vec<_> = objects
                    .iter()
                    .filter(|o| !want_ids.contains(&o.id))
                    .map(|o| (o.x, o.y, o.w, o.h))
                    .take(3)
                    .collect();
                return Err(v(
                    "viewport:differs_from_filter",
                    i,
                    format!(
                        "window {view:?} previous {previous:?} after {after_seq} limit {limit}: store {} ids vs filter {}; missing {missing:?}; extra {extra:?}",
                        got.len(),
                        want_ids.len()
                    ),
                ));
            }
        }
        let (_, all) = self
            .store
            .viewport_snapshot(self.channel, &whole_world())
            .await
            .map_err(|e| v("viewport:read", i, e.to_string()))?;
        if all.len() != alive.len() {
            return Err(v(
                "viewport:whole_world",
                i,
                format!("{} of {} live objects", all.len(), alive.len()),
            ));
        }
        Ok(())
    }

    pub async fn age_and_sweep(&mut self, i: usize) -> Check {
        let delta = 31 * DAY_MS;
        let latest = self.oracle.latest;
        let cut = if self.rng.chance(50) {
            latest
        } else {
            self.rng.range(1, latest.max(1))
        };
        let dead_stamps = "SELECT created_at FROM canvas_ops WHERE channel_id = ? AND seq <= ? AND kind IN ('remove', 'clear')";
        sqlx::query(&format!("UPDATE canvas_objects SET deleted_at = deleted_at - ? WHERE deleted_at IN ({dead_stamps})")).bind(delta).bind(self.channel).bind(cut).execute(&self.pool).await.map_err(|e| v("sweep:age", i, e.to_string()))?;
        sqlx::query(
            "UPDATE canvas_ops SET created_at = created_at - ? WHERE channel_id = ? AND seq <= ?",
        )
        .bind(delta)
        .bind(self.channel)
        .bind(cut)
        .execute(&self.pool)
        .await
        .map_err(|e| v("sweep:age", i, e.to_string()))?;
        let effective: Vec<u32> = self
            .oracle
            .ops
            .iter()
            .filter(|(label, rec)| {
                matches!(rec.kind, "remove" | "clear")
                    && rec
                        .touched
                        .iter()
                        .any(|o| self.oracle.objs[o].dead_by == Some(**label))
            })
            .map(|(label, _)| *label)
            .collect();
        self.store
            .sweep_canvas_ops()
            .await
            .map_err(|e| v("sweep:failed", i, e.to_string()))?;
        self.swept_once = true;
        let kept: HashSet<slimm_server::ids::CanvasOpId> =
            sqlx::query_scalar("SELECT id FROM canvas_ops WHERE channel_id = ?")
                .bind(self.channel)
                .fetch_all(&self.pool)
                .await
                .map_err(|e| v("sweep:read", i, e.to_string()))?
                .into_iter()
                .collect();
        let gone: Vec<u32> = self
            .oracle
            .ops
            .keys()
            .copied()
            .filter(|l| self.op_ids.get(l).is_some_and(|id| !kept.contains(id)))
            .collect();
        for label in gone {
            if effective.contains(&label) {
                return Err(v(
                    "sweep:deleted_an_op_that_still_undoes_something",
                    i,
                    format!("op {label} still has dead objects it could restore"),
                ));
            }
            self.oracle.ops.remove(&label);
            self.history.remove(&label);
        }
        Ok(())
    }
}
