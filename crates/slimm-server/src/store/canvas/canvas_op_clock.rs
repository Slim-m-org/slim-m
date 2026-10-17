// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `Store::now_ms_unique`: the per-op timestamp two of `restore`'s
//! authorization fences depend on for uniqueness - `restore_candidates`'s
//! `clear` branch matches a whole batch of un-delete candidates against
//! `WHERE deleted_at = target.created_at`, and `apply_restore`'s own `remove`
//! branch checks the identical fence per object - so a collision here is a
//! collision in both.
//!
//! Split out of `canvas_ops_write.rs`, which crossed the 500-line hard limit:
//! the clock is a self-contained concern with its own invariant (never repeat
//! a value for as long as one `Store` exists), worth a file whose name says
//! what it is rather than sitting at the bottom of the write path it backs.

use std::sync::atomic::{AtomicI64, Ordering};

use tokio::sync::OnceCell;

use super::super::{Store, now_ms};

/// Backs [`Store::now_ms_unique`]: an in-memory counter plus a flag for
/// whether it has been seeded from the database yet. One lives on each
/// `Store` (see that field's own doc for why that, rather than a process-wide
/// `static`, is what closes the restart gap [`Store::now_ms_unique`]
/// documents).
pub(in crate::store) struct CanvasOpClock {
    last: AtomicI64,
    seeded: OnceCell<()>,
}

impl Default for CanvasOpClock {
    fn default() -> Self {
        Self {
            last: AtomicI64::new(0),
            seeded: OnceCell::new(),
        }
    }
}

impl CanvasOpClock {
    /// The monotonic step itself, once the clock is known to be seeded: pure
    /// and I/O-free, which is what lets `tests::a_tight_loop_never_repeats_a_value`
    /// below drive it directly without a database or an async runtime.
    fn advance(&self) -> i64 {
        let mut last = self.last.load(Ordering::Acquire);
        loop {
            let next = now_ms().max(last + 1);
            match self
                .last
                .compare_exchange_weak(last, next, Ordering::AcqRel, Ordering::Acquire)
            {
                Ok(_) => return next,
                Err(actual) => last = actual,
            }
        }
    }
}

impl Store {
    /// A per-op timestamp, unlike plain `now_ms()`, guaranteed never to
    /// repeat for as long as this `Store` exists.
    ///
    /// `canvas_objects.deleted_at` doubles as the fence `restore_candidates`'s
    /// `clear` branch matches a whole batch of un-delete candidates against
    /// (`WHERE deleted_at = target.created_at`), on the stated assumption
    /// that "the single writer this database has means no other write can
    /// share that millisecond." That conflates strict ordering with distinct
    /// values: two sequential `submit_canvas_op` calls can read the same
    /// wall-clock millisecond from `SystemTime::now()`, which is well within
    /// reach on a fast SQLite/WAL commit. A `remove` and an unrelated `clear`
    /// sharing one timestamp would let restoring the `clear` silently
    /// un-delete whatever the `remove` touched too - even a member's own
    /// removal of their own object, with no `MANAGE_CANVAS` involved in that
    /// removal at all.
    ///
    /// Every canvas-op write already runs inside `Store::begin_write`'s
    /// exclusive `BEGIN IMMEDIATE` lock, so calls into this function are
    /// already totally ordered within one process's lifetime; the in-memory
    /// counter alone only has to break a tie between two reads of the same
    /// millisecond, not coordinate concurrency none of these calls can have.
    ///
    /// A bare in-memory counter resets to zero on every process restart,
    /// though, and a burst of concurrent submissions just before a crash can
    /// have pushed it several milliseconds ahead of the wall clock; if the
    /// process restarts fast enough for real time to still be inside that
    /// window, the first post-restart call could return a value a
    /// still-live, un-restored fence already depends on being unique. Seeding
    /// the counter from `MAX(created_at)` already committed to `canvas_ops`,
    /// once per `Store` (so once per process, since a restart constructs a
    /// fresh `Store` rather than reusing one that outlived it), closes that:
    /// the seed is read inside the caller's own write-locked transaction, so
    /// no call on this `Store` can race ahead of it, and the database itself
    /// cannot move backward across a restart the way an in-memory counter
    /// does. This does not, and cannot, protect two separate processes
    /// writing the same database file at once - each would seed and then
    /// advance its own counter independently - but nothing in this project's
    /// single-process architecture is meant to allow that in the first place.
    ///
    /// The seed query names every kind explicitly rather than a bare
    /// `SELECT MAX(created_at)`: over a `canvas_ops` growing without bound
    /// (`move`/`reorder` rows are never swept, see `canvas_ops_sweep.rs`'s
    /// own module doc), an unfiltered `MAX` cannot use an index at all and
    /// pays for a full table scan under this same write lock. Matching the
    /// `canvas_op_kind` CHECK constraint's own list against the
    /// `canvas_ops_kind_created_at` index turns that into one index descent
    /// per kind - a handful of steps regardless of table size, the same
    /// optimization that also makes the sweep's own per-kind queries cheap.
    pub(in crate::store) async fn now_ms_unique(
        &self,
        tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    ) -> Result<i64, sqlx::Error> {
        let clock = &self.canvas_op_clock;
        clock
            .seeded
            .get_or_try_init(|| async {
                // See this function's own doc for why every kind is named.
                let max = sqlx::query_scalar!(
                    r#"SELECT MAX(created_at) AS "max: i64" FROM canvas_ops
                       WHERE kind IN ('place', 'remove', 'clear', 'restore', 'move', 'reorder')"#
                )
                .fetch_one(&mut **tx)
                .await?;
                if let Some(max) = max {
                    clock.last.fetch_max(max, Ordering::AcqRel);
                }
                Ok::<(), sqlx::Error>(())
            })
            .await?;

        Ok(clock.advance())
    }
}

#[cfg(test)]
mod tests {
    use super::CanvasOpClock;

    /// A tight loop with no I/O reliably lands several calls in the same
    /// real millisecond on any machine, which is exactly the case
    /// `Store::now_ms_unique`'s own doc names as reachable in production
    /// between two real `submit_canvas_op` calls. Deterministic, unlike a
    /// test that tries to race two HTTP requests against the clock.
    #[test]
    fn a_tight_loop_never_repeats_a_value() {
        let clock = CanvasOpClock::default();
        let mut previous = clock.advance();
        for _ in 0..10_000 {
            let next = clock.advance();
            assert!(next > previous, "{next} did not advance past {previous}");
            previous = next;
        }
    }
}
