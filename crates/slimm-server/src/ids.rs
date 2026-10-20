// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Entity and event identity.
//!
//! Identity is a client-generatable UUIDv7 (its 48-bit millisecond prefix makes
//! it time-ordered, which keeps SQLite B-tree locality good). Ordering is a
//! separate per-scope [`Seq`], so the two jobs are never conflated. The newtypes
//! stop a channel id from being passed where a message id is expected, and the
//! `sqlx(transparent)` derive stores them as the underlying 16-byte BLOB.

use uuid::Uuid;

macro_rules! uuid_id {
    ($name:ident, $doc:literal) => {
        #[doc = $doc]
        #[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, sqlx::Type)]
        #[sqlx(transparent)]
        pub struct $name(pub Uuid);

        impl $name {
            /// Mint a fresh, time-ordered identity.
            pub fn generate() -> Self {
                Self(Uuid::now_v7())
            }
        }

        impl std::fmt::Display for $name {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                write!(f, "{}", self.0)
            }
        }
    };
}

uuid_id!(UserId, "A user identity.");
uuid_id!(ChannelId, "A channel identity.");
uuid_id!(MessageId, "A message identity.");
uuid_id!(DeviceId, "A device identity.");
uuid_id!(SessionId, "A login-session identity.");
uuid_id!(RoleId, "A role identity.");
uuid_id!(CanvasObjectId, "A canvas object identity.");
uuid_id!(
    CanvasOpId,
    "A canvas op identity: client-minted for a mutation, server-minted for a place."
);
uuid_id!(EmojiId, "A custom emoji identity.");
uuid_id!(ExportId, "A data export job identity.");
uuid_id!(
    FamilyId,
    "A refresh-token family identity: rotation keeps the id, reuse revokes it."
);
uuid_id!(
    ChannelCategoryId,
    "A channel category identity: a rail section a channel of any kind may be placed in."
);
uuid_id!(
    CallRingId,
    "A DM call's ring-attempt identity: minted fresh per ring, never persisted, so a client can tell today's ring apart from a rapid retry of the same call."
);
uuid_id!(
    InteractionId,
    "A button click awaiting its bot's answer, chosen by the clicking client so a retry is the same click."
);
uuid_id!(
    WebhookId,
    "An incoming webhook's own identity, distinct from the users.id of the principal it authenticates as."
);

/// A per-scope monotonic order key. Deliberately a distinct type from identity:
/// it answers "in what order", not "which one".
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, sqlx::Type)]
#[sqlx(transparent)]
pub struct Seq(pub i64);
