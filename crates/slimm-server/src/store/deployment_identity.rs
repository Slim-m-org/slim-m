// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who this deployment is: its identity keypair, the key a module caller id is
//! derived with, and its display name.

use super::Store;

impl Store {
    /// The server's long-lived identity keypair, generating and persisting
    /// one on the first call a fresh deployment ever makes. See
    /// [`crate::identity`] for what a client may and may not conclude from it.
    pub async fn server_identity(&self) -> anyhow::Result<crate::identity::ServerIdentity> {
        crate::identity::load_or_create(&self.pool).await
    }

    /// The secret a module's caller id is keyed with, so the id cannot be
    /// recomputed from a module id and a user id, both of which are public.
    pub async fn module_caller_key(&self) -> anyhow::Result<[u8; 32]> {
        crate::identity::derived_key(&self.pool, b"slim-module-caller-key-v2").await
    }

    /// This deployment's display name, shown to a prospective joiner (invite
    /// metadata) before they have an account.
    ///
    /// Backed by `server_meta` rather than a dedicated column: it is exactly
    /// the kind of singleton deployment-wide setting that table already
    /// exists for, seeded with a default by migration 0010. The fallback
    /// here is defensive only (every deployment gets the seeded row), not a
    /// substitute for it.
    pub async fn deployment_name(&self) -> anyhow::Result<String> {
        let value = sqlx::query_scalar!(
            r#"SELECT value AS "value!" FROM server_meta WHERE key = 'deployment_name'"#
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(value.unwrap_or_else(|| "slim-m".to_owned()))
    }
}
