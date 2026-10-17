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

use super::super::{Role, Store};
use crate::ids::RoleId;

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
    /// Sets every non-`@everyone` role's position from its index in
    /// `ordered`: the first id (top of the pane's list) gets `ordered.len()`,
    /// the last gets `1`, so every reordered role always outranks
    /// `@everyone`'s bootstrap default of `0` - matching the pane always
    /// drawing `@everyone` last regardless of where the drag left the roles
    /// above it.
    ///
    /// Refuses a list that is not exactly the live non-`@everyone` roles.
    /// One transaction from the first read (see [`Store::begin_write`]), so
    /// a concurrent create or delete cannot land between validation and
    /// write and silently invalidate it.
    pub async fn reorder_roles(
        &self,
        ordered: &[RoleId],
    ) -> Result<RoleReorderOutcome, ReorderRolesError> {
        let mut tx = self.begin_write().await?;
        let live = live_non_everyone_roles(&mut tx).await?;
        validate_live_set(&live, ordered)?;

        let before: HashMap<RoleId, i64> = live.into_iter().collect();
        let total = ordered.len() as i64;

        let mut moved = Vec::new();
        for (index, id) in ordered.iter().enumerate() {
            let position = total - index as i64;
            if before.get(id) == Some(&position) {
                continue;
            }
            moved.push(*id);
            sqlx::query!("UPDATE roles SET position = ? WHERE id = ?", position, id)
                .execute(&mut *tx)
                .await?;
        }
        tx.commit().await?;

        let roles = self.list_roles().await?;
        Ok(RoleReorderOutcome { roles, moved })
    }
}
