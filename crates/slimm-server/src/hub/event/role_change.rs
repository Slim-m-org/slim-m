// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a role looked like around a [`super::Event::RoleChanged`].
//!
//! Only what a member already sees in the member list (name, colour, grouping, mention rule).
//! The permission bits stay out: they remain gated behind MANAGE_ROLES.

use serde::Serialize;

use crate::store::Role;

/// A role's member-visible look.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RoleLook {
    pub name: String,
    pub color: Option<i64>,
    pub hoist: bool,
    pub mentionable: bool,
}

impl From<&Role> for RoleLook {
    fn from(role: &Role) -> Self {
        Self {
            name: role.name.clone(),
            color: role.color,
            hoist: role.hoist,
            mentionable: role.mentionable,
        }
    }
}

/// How a role changed, with the member-visible state either side of it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RoleChange {
    Created(RoleLook),
    Updated { before: RoleLook, after: RoleLook },
    Deleted(RoleLook),
}

impl RoleChange {
    pub fn created(role: &Role) -> Self {
        Self::Created(role.into())
    }

    pub fn updated(before: &Role, after: &Role) -> Self {
        Self::Updated {
            before: before.into(),
            after: after.into(),
        }
    }

    pub fn deleted(role: &Role) -> Self {
        Self::Deleted(role.into())
    }

    /// The wire word for this kind of change.
    pub fn kind(&self) -> &'static str {
        match self {
            Self::Created(_) => "created",
            Self::Updated { .. } => "updated",
            Self::Deleted(_) => "deleted",
        }
    }

    /// The state before the change, absent for a create.
    pub fn before(&self) -> Option<&RoleLook> {
        match self {
            Self::Created(_) => None,
            Self::Updated { before, .. } | Self::Deleted(before) => Some(before),
        }
    }

    /// The state after the change, absent for a delete.
    pub fn after(&self) -> Option<&RoleLook> {
        match self {
            Self::Deleted(_) => None,
            Self::Created(after) | Self::Updated { after, .. } => Some(after),
        }
    }
}
