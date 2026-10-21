// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reusing a member's live invite, so the invite button hands out one code until it is spent.

use super::invites::Invite;
use super::{Store, now_ms};
use crate::ids::UserId;

impl Store {
    /// The caller's live invite with these limits, minted only when there is none, so a repeated
    /// click shares one code; `None` when none is live and the creator is at `cap`.
    pub async fn live_or_new_invite(
        &self,
        created_by: UserId,
        max_uses: Option<i64>,
        expires_at: Option<i64>,
        cap: i64,
    ) -> anyhow::Result<Option<Invite>> {
        if let Some(found) = self
            .live_invite_matching(created_by, max_uses, expires_at.is_some())
            .await?
        {
            return Ok(Some(found));
        }
        self.create_invite_capped(created_by, max_uses, expires_at, cap)
            .await
    }

    async fn live_invite_matching(
        &self,
        created_by: UserId,
        max_uses: Option<i64>,
        expires: bool,
    ) -> anyhow::Result<Option<Invite>> {
        let now = now_ms();
        let expires = i64::from(expires);
        let row = sqlx::query!(
            r#"SELECT code AS "code!", max_uses, uses AS "uses!", expires_at,
                      created_at AS "created_at!"
               FROM invites
               WHERE created_by = ?1 AND role_grant IS NULL AND revoked_at IS NULL
                 AND max_uses IS ?2 AND (expires_at IS NOT NULL) = ?3
                 AND (expires_at IS NULL OR expires_at > ?4)
                 AND (max_uses IS NULL OR uses < max_uses)
               ORDER BY created_at DESC LIMIT 1"#,
            created_by,
            max_uses,
            expires,
            now
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(row.map(|r| Invite {
            code: r.code,
            max_uses: r.max_uses,
            uses: r.uses,
            expires_at: r.expires_at,
            created_at: r.created_at,
            revoked: false,
            role_grant: None,
            created_by_name: None,
        }))
    }
}
