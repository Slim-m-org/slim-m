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
    /// A per-op timestamp that never repeats for this `Store`, because a
    /// restore fence matches on it and two ops sharing a millisecond would let
    /// restoring a clear un-delete an unrelated removal. Seeded from the
    /// committed maximum so a restart cannot reuse one; see docs/internals.md.
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
                       WHERE kind IN ('place', 'remove', 'clear', 'restore', 'move', 'reorder', 'edit')"#
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
