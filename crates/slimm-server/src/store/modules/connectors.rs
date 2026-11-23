// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Installing, re-keying and removing a connector (decision 0090): a module
//! whose logic is an external program, so the install is its principal and a
//! bot token instead of an artifact.
//!
//! The principal's roles grant what the admin approved, and the approval is
//! also stored as the principal's ceiling (`store::permissions::connector_cap`),
//! so a role it is given later cannot widen what the token reaches. Uninstall
//! revokes the token and strips every grant in the same transaction that
//! deletes the module row, so the principal is never left uncapped with a
//! live credential.

use super::module_metadata::insert_module_metadata;
use super::module_schedule::principal_username;
use super::platform::write_platform;
use super::{DockProvenance, InstallModuleRequest, InstalledModule};
use crate::ids::{SessionId, UserId};
use crate::permissions::Permissions;
use crate::store::bot_token::{mint_bot_token, revoke_bot_tokens};
use crate::store::moderation_audit::{ModerationAction, ModerationAudit, record_moderation_audit};
use crate::store::roles::role_bots::{assign_to_bot, ensure_bots_role, set_managed_role};
use crate::store::{Store, now_ms};

/// One connector install as the admin approved it.
pub struct ConnectorInstall<'a> {
    pub module: InstallModuleRequest<'a>,
    pub provenance: &'a DockProvenance<'a>,
    /// The core permissions the token may use, already checked against what was asked and what the admin holds.
    pub approved: Permissions,
    pub installed_by: UserId,
}

/// The installed connector, and its token the one time it is legible.
pub struct InstalledConnector {
    pub module: InstalledModule,
    /// `Some` only when this install minted the principal's token.
    pub token: Option<String>,
}

type Tx<'t> = sqlx::Transaction<'t, sqlx::Sqlite>;

impl Store {
    /// Installs or updates a connector, creating its principal and token on first install.
    pub async fn install_connector(
        &self,
        install: ConnectorInstall<'_>,
    ) -> anyhow::Result<InstalledConnector> {
        let req = &install.module;
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        insert_module_metadata(&mut tx, req).await?;
        let approved = install.approved.bits();
        let manifest = install.provenance.manifest_json;
        sqlx::query!(
            "UPDATE installed_modules
             SET provider = 'connector', connector_permissions = ?, source_repo = ?,
                 manifest_json = ?, approved_host_capabilities = '[]', network_hosts = '[]',
                 local_network_approved = 0, schedules = '[]'
             WHERE id = ?",
            approved,
            install.provenance.source_repo,
            manifest,
            req.id
        )
        .execute(&mut *tx)
        .await?;
        write_platform(&mut tx, req.id, install.provenance.platform).await?;

        let (principal, token) = match live_principal(&mut tx, req.id).await? {
            Some(principal) => (principal, None),
            None => {
                let principal = insert_principal(&mut tx, req.id, req.name, now).await?;
                let token =
                    mint_bot_token(&mut tx, principal, req.name, install.installed_by, now).await?;
                (principal, Some(token))
            }
        };
        sqlx::query!(
            "UPDATE users SET display_name = ? WHERE id = ?",
            req.name,
            principal
        )
        .execute(&mut *tx)
        .await?;
        let (_, granted) =
            set_managed_role(&mut tx, principal, req.name, install.approved, now).await?;
        let action = match token {
            Some(_) => ModerationAction::BotCreate,
            None => ModerationAction::BotPermissionGrant,
        };
        let reason = format!("connector {}: {granted}", req.id);
        record_moderation_audit(
            &mut tx,
            ModerationAudit {
                actor_id: install.installed_by,
                subject_id: principal,
                action,
                reason: Some(&reason),
                until: None,
                created_at: now,
            },
        )
        .await?;
        tx.commit().await?;
        self.touch_modules();
        let module = self
            .installed_module(req.id)
            .await?
            .ok_or_else(|| anyhow::anyhow!("install of {} did not persist", req.id))?;
        Ok(InstalledConnector { module, token })
    }

    /// Replaces the connector's token; `None` when `module_id` is not an installed connector.
    /// The old token's sessions are returned for `Event::SessionRevoked`.
    pub async fn reissue_connector_token(
        &self,
        module_id: &str,
        reissued_by: UserId,
    ) -> anyhow::Result<Option<(String, Vec<SessionId>)>> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        let Some(principal) = live_principal(&mut tx, module_id).await? else {
            return Ok(None);
        };
        let name =
            sqlx::query_scalar!("SELECT name FROM installed_modules WHERE id = ?", module_id)
                .fetch_one(&mut *tx)
                .await?;
        let revoked = revoke_bot_tokens(&mut tx, principal, now).await?;
        let token = mint_bot_token(&mut tx, principal, &name, reissued_by, now).await?;
        record_moderation_audit(
            &mut tx,
            ModerationAudit {
                actor_id: reissued_by,
                subject_id: principal,
                action: ModerationAction::BotTokenReissue,
                reason: None,
                until: None,
                created_at: now,
            },
        )
        .await?;
        tx.commit().await?;
        Ok(Some((token, revoked)))
    }

    /// Uninstalls a connector: its token, every grant its principal holds, and
    /// the module row go in one transaction. `None` when it was not installed.
    pub async fn uninstall_connector(
        &self,
        module_id: &str,
        removed_by: UserId,
    ) -> anyhow::Result<Option<Vec<SessionId>>> {
        let now = now_ms();
        let mut tx = self.begin_write().await?;
        let principal = live_principal(&mut tx, module_id).await?;
        let mut revoked = Vec::new();
        if let Some(principal) = principal {
            revoked = revoke_bot_tokens(&mut tx, principal, now).await?;
            strip_grants(&mut tx, principal).await?;
            let reason = format!("connector {module_id} uninstalled");
            record_moderation_audit(
                &mut tx,
                ModerationAudit {
                    actor_id: removed_by,
                    subject_id: principal,
                    action: ModerationAction::BotRevoke,
                    reason: Some(&reason),
                    until: None,
                    created_at: now,
                },
            )
            .await?;
        }
        let deleted = sqlx::query!(
            "DELETE FROM installed_modules WHERE id = ? AND provider = 'connector'",
            module_id
        )
        .execute(&mut *tx)
        .await?
        .rows_affected();
        tx.commit().await?;
        self.touch_modules();
        Ok((deleted > 0).then_some(revoked))
    }

    /// The connector whose principal is `user_id`, if it is one.
    pub async fn connector_of(&self, user_id: UserId) -> anyhow::Result<Option<InstalledModule>> {
        let id = sqlx::query_scalar!(
            "SELECT id FROM installed_modules WHERE bot_user_id = ? AND provider = 'connector'",
            user_id
        )
        .fetch_optional(&self.pool)
        .await?;
        match id {
            Some(id) => self.installed_module(&id).await,
            None => Ok(None),
        }
    }
}

/// The module's principal, unless it was deleted behind the module's back.
async fn live_principal(tx: &mut Tx<'_>, module_id: &str) -> anyhow::Result<Option<UserId>> {
    Ok(sqlx::query_scalar!(
        r#"SELECT u.id AS "id!: UserId" FROM installed_modules m
           JOIN users u ON u.id = m.bot_user_id
           WHERE m.id = ? AND m.provider = 'connector' AND u.deleted_at IS NULL"#,
        module_id
    )
    .fetch_optional(&mut **tx)
    .await?)
}

async fn insert_principal(
    tx: &mut Tx<'_>,
    module_id: &str,
    name: &str,
    now: i64,
) -> anyhow::Result<UserId> {
    let id = UserId::generate();
    let username = principal_username(module_id, id);
    sqlx::query!(
        "INSERT INTO users (id, username, display_name, created_at, is_bot) VALUES (?, ?, ?, ?, 1)",
        id,
        username,
        name,
        now
    )
    .execute(&mut **tx)
    .await?;
    let bots_role = ensure_bots_role(tx, now).await?;
    assign_to_bot(tx, id, bots_role).await?;
    sqlx::query!(
        "UPDATE installed_modules SET bot_user_id = ? WHERE id = ?",
        id,
        module_id
    )
    .execute(&mut **tx)
    .await?;
    Ok(id)
}

/// Every role, own role and overwrite that grants the principal anything.
async fn strip_grants(tx: &mut Tx<'_>, principal: UserId) -> anyhow::Result<()> {
    set_managed_role(tx, principal, "", Permissions::NONE, 0).await?;
    sqlx::query!("DELETE FROM member_roles WHERE user_id = ?", principal)
        .execute(&mut **tx)
        .await?;
    sqlx::query!(
        "DELETE FROM channel_overwrites WHERE target_type = 'member' AND target_id = ?",
        principal
    )
    .execute(&mut **tx)
    .await?;
    sqlx::query!(
        "DELETE FROM category_overwrites WHERE target_type = 'member' AND target_id = ?",
        principal
    )
    .execute(&mut **tx)
    .await?;
    Ok(())
}
