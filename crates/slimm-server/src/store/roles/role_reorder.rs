// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Setting the deployment's role order: `PATCH /roles/reorder`.
//!
//! Mirrors `store::channel_order`'s shape closely: validate the submitted
//! list is exactly the live set, diff against current positions inside one
//! write transaction, and report only what actually moved. `@everyone` is
//! excluded from that live set rather than merely left untouched - it holds
//! no explicit membership, so it can never sit below anyone's "own highest
//! held role" ceiling, and reordering it would be meaningless.

use std::collections::{HashMap, HashSet};

use sqlx::SqliteConnection;

use super::super::{Role, Store};
use crate::ids::{RoleId, UserId};

/// The result of a successful reorder.
pub struct RoleReorderOutcome {
    /// Every role, in its new order (matching [`Store::list_roles`]).
    pub roles: Vec<Role>,
    /// Which roles actually changed position. A caller submitting the
    /// arrangement it already has gets an empty list, the same convention
    /// `store::channel_order::ReorderOutcome::moved` uses.
    pub moved: Vec<RoleId>,
}

/// Why setting the role order failed structurally, before any escalation
/// question is even asked.
#[derive(Debug)]
pub enum ReorderRolesError {
    /// The ids named did not add up to exactly the live non-`@everyone`
    /// roles: some were repeated, some were left out, or some are not live
    /// roles at all.
    Mismatch {
        missing: Vec<RoleId>,
        extra: Vec<RoleId>,
    },
    /// The order moved a role at or above the caller's highest role, or put one above it.
    AboveCaller,
    Internal(anyhow::Error),
}

impl From<sqlx::Error> for ReorderRolesError {
    fn from(err: sqlx::Error) -> Self {
        ReorderRolesError::Internal(err.into())
    }
}

impl From<anyhow::Error> for ReorderRolesError {
    fn from(err: anyhow::Error) -> Self {
        ReorderRolesError::Internal(err)
    }
}

async fn live_non_everyone_roles(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
) -> Result<Vec<(RoleId, i64)>, sqlx::Error> {
    let rows = sqlx::query!(
        r#"SELECT id AS "id!: RoleId", position AS "position!: i64"
           FROM roles WHERE is_everyone = 0"#
    )
    .fetch_all(&mut **tx)
    .await?;
    Ok(rows.into_iter().map(|r| (r.id, r.position)).collect())
}

/// The position a new role takes: the bottom, just above `@everyone`.
pub(in crate::store) const BOTTOM_POSITION: i64 = 1;

/// Lifts every role one step so a new one fits at [`BOTTOM_POSITION`] without tying another.
pub(in crate::store) async fn open_bottom_slot(conn: &mut SqliteConnection) -> sqlx::Result<()> {
    sqlx::query!("UPDATE roles SET position = position + 1 WHERE is_everyone = 0")
        .execute(&mut *conn)
        .await?;
    Ok(())
}

async fn top_position_in(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    user_id: UserId,
) -> Result<Option<i64>, sqlx::Error> {
    sqlx::query_scalar!(
        r#"SELECT MAX(r.position) AS "position: i64" FROM member_roles mr
               JOIN roles r ON r.id = mr.role_id WHERE mr.user_id = ?"#,
        user_id
    )
    .fetch_one(&mut **tx)
    .await
}

/// How many roles at the head of `ordered` stay where they are: those at or above `top`.
///
/// Refuses unless they lead the list, highest first, so nothing below `top` rises past them.
fn held_head(
    before: &HashMap<RoleId, i64>,
    ordered: &[RoleId],
    top: Option<i64>,
) -> Result<usize, ReorderRolesError> {
    let reaches = |position: i64| top.is_some_and(|top| position < top);
    let held = before.values().filter(|p| !reaches(**p)).count();
    let head = ordered[..held].iter().map(|id| before[id]);
    let in_place = head.clone().all(|p| !reaches(p))
        && head
            .clone()
            .zip(head.skip(1))
            .all(|(above, below)| above >= below);
    if in_place {
        Ok(held)
    } else {
        Err(ReorderRolesError::AboveCaller)
    }
}

/// New positions: the reordered tail takes `tail..1` and the held head keeps its own spacing and
/// ties, lifted just enough to stay above that tail.
fn new_positions(
    before: &HashMap<RoleId, i64>,
    ordered: &[RoleId],
    held: usize,
) -> Vec<(RoleId, i64)> {
    let tail = (ordered.len() - held) as i64;
    let lowest_held = ordered[..held].iter().map(|id| before[id]).min();
    let lift = lowest_held.map_or(0, |low| (tail + 1 - low).max(0));
    let head = ordered[..held].iter().map(|id| (*id, before[id] + lift));
    let rest = ordered[held..]
        .iter()
        .enumerate()
        .map(|(index, id)| (*id, tail - index as i64));
    head.chain(rest).collect()
}

/// Refuses `ordered` unless it names exactly the ids in `live` - no more, no
/// fewer, no repeats - the same all-or-nothing validation
/// `store::channel_order::validate_live_set` applies to a channel drag.
fn validate_live_set(live: &[(RoleId, i64)], ordered: &[RoleId]) -> Result<(), ReorderRolesError> {
    let live_set: HashSet<RoleId> = live.iter().map(|(id, _)| *id).collect();
    let given_set: HashSet<RoleId> = ordered.iter().copied().collect();
    if given_set.len() != ordered.len() || live_set != given_set {
        let mut seen = HashSet::new();
        let mut extra = Vec::new();
        for id in ordered {
            let repeated = !seen.insert(*id);
            if (repeated || !live_set.contains(id)) && !extra.contains(id) {
                extra.push(*id);
            }
        }
        return Err(ReorderRolesError::Mismatch {
            missing: live_set.difference(&given_set).copied().collect(),
            extra,
        });
    }
    Ok(())
}

impl Store {
    /// Sets every non-`@everyone` role's position from its index in `ordered`, top first, the last
    /// getting `1` so every role outranks `@everyone`. Refuses a list that is not exactly the live
    /// non-`@everyone` roles.
    pub async fn reorder_roles(
        &self,
        ordered: &[RoleId],
    ) -> Result<RoleReorderOutcome, ReorderRolesError> {
        self.reorder_roles_below(ordered, None).await
    }

    /// [`Store::reorder_roles`] for a `caller` who must not reach above themselves (`None` for the
    /// Space owner): the roles at or above their highest must lead `ordered` in their current
    /// order, and keep their positions and ties; only the roles below are renumbered.
    ///
    /// One write transaction from the first read, so a concurrent create or delete cannot slip
    /// between the checks and the write.
    pub async fn reorder_roles_below(
        &self,
        ordered: &[RoleId],
        caller: Option<UserId>,
    ) -> Result<RoleReorderOutcome, ReorderRolesError> {
        let mut tx = self.begin_write().await?;
        let live = live_non_everyone_roles(&mut tx).await?;
        validate_live_set(&live, ordered)?;

        let before: HashMap<RoleId, i64> = live.into_iter().collect();
        let held = match caller {
            Some(user_id) => held_head(&before, ordered, top_position_in(&mut tx, user_id).await?)?,
            None => 0,
        };

        let mut moved = Vec::new();
        for (id, position) in new_positions(&before, ordered, held) {
            if before.get(&id) == Some(&position) {
                continue;
            }
            moved.push(id);
            sqlx::query!("UPDATE roles SET position = ? WHERE id = ?", position, id)
                .execute(&mut *tx)
                .await?;
        }
        tx.commit().await?;

        let roles = self.list_roles().await?;
        Ok(RoleReorderOutcome { roles, moved })
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::{ReorderRolesError, held_head, new_positions};
    use crate::ids::RoleId;

    fn ids(n: usize) -> Vec<RoleId> {
        (0..n).map(|_| RoleId::generate()).collect()
    }

    fn at(ids: &[RoleId], positions: &[i64]) -> HashMap<RoleId, i64> {
        ids.iter().copied().zip(positions.iter().copied()).collect()
    }

    #[test]
    fn the_owner_renumbers_everything_top_down() {
        let r = ids(3);
        let before = at(&r, &[100, 7, 7]);
        let order = [r[2], r[0], r[1]];
        assert_eq!(
            new_positions(&before, &order, 0),
            vec![(r[2], 3), (r[0], 2), (r[1], 1)]
        );
    }

    #[test]
    fn a_held_head_keeps_its_gaps_and_ties_and_only_the_tail_is_renumbered() {
        let r = ids(5);
        let before = at(&r, &[100, 9, 9, 4, 2]);
        let order = [r[0], r[2], r[1], r[4], r[3]];
        assert_eq!(held_head(&before, &order, Some(9)).unwrap(), 3);
        assert_eq!(
            new_positions(&before, &order, 3),
            vec![(r[0], 100), (r[2], 9), (r[1], 9), (r[4], 2), (r[3], 1)]
        );
    }

    #[test]
    fn a_held_head_lifts_as_one_when_the_tail_would_reach_it() {
        let r = ids(4);
        let before = at(&r, &[3, 2, 0, 0]);
        let order = [r[0], r[1], r[3], r[2]];
        assert_eq!(
            new_positions(&before, &order, 2),
            vec![(r[0], 4), (r[1], 3), (r[3], 2), (r[2], 1)]
        );
    }

    #[test]
    fn nothing_below_the_caller_may_rise_into_or_above_the_held_head() {
        let r = ids(4);
        let before = at(&r, &[4, 3, 2, 1]);
        let refused = |order: [RoleId; 4]| {
            matches!(
                held_head(&before, &order, Some(3)),
                Err(ReorderRolesError::AboveCaller)
            )
        };
        assert!(refused([r[0], r[2], r[1], r[3]]));
        assert!(refused([r[1], r[0], r[2], r[3]]));
        assert!(refused([r[2], r[0], r[1], r[3]]));
        assert!(!refused([r[0], r[1], r[3], r[2]]));
    }

    #[test]
    fn a_caller_holding_no_role_holds_every_role_in_place() {
        let r = ids(2);
        let before = at(&r, &[2, 1]);
        assert_eq!(held_head(&before, &[r[0], r[1]], None).unwrap(), 2);
        assert!(held_head(&before, &[r[1], r[0]], None).is_err());
    }
}
