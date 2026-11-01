// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a module hooks into (decision 0100): interceptors on a message before
//! it is stored, and deny-only permission checks. The manifest declares each
//! hook; the admin owns its order and whether a failure refuses the action.

use std::sync::atomic::Ordering;

use sqlx::Row;

use crate::ids::MessageId;
use crate::store::Store;

/// Which family a hook belongs to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookKind {
    Interceptor,
    Permission,
}

impl HookKind {
    pub fn as_str(self) -> &'static str {
        match self {
            HookKind::Interceptor => "interceptor",
            HookKind::Permission => "permission",
        }
    }

    fn parse(text: &str) -> Option<Self> {
        match text {
            "interceptor" => Some(HookKind::Interceptor),
            "permission" => Some(HookKind::Permission),
            _ => None,
        }
    }
}

/// A hook as a manifest declares it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookDecl {
    pub kind: HookKind,
    pub hook: String,
    /// The interceptor phase; empty for a permission hook.
    pub phase: String,
    /// The message fields an interceptor is sent.
    pub reads: Vec<String>,
}

/// A hook as installed: the declaration plus what the admin set.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModuleHook {
    pub module_id: String,
    pub decl: HookDecl,
    pub priority: i64,
    pub fail_closed: bool,
}

/// The admin's change to one hook; a `None` leaves that setting alone.
#[derive(Debug, Clone, Copy, Default)]
pub struct HookChange {
    pub priority: Option<i64>,
    pub fail_closed: Option<bool>,
}

/// Priority a hook starts at, so the admin can slot others before and after it.
pub const DEFAULT_PRIORITY: i64 = 100;

/// Replaces a module's hook rows with its manifest's, keeping the admin's settings for any that remain.
pub(super) async fn write_hooks(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    id: &str,
    decls: &[HookDecl],
) -> anyhow::Result<()> {
    let kept = sqlx::query(
        "SELECT kind, hook, phase, priority, fail_closed FROM module_hooks WHERE module_id = ?",
    )
    .bind(id)
    .fetch_all(&mut **tx)
    .await?;
    sqlx::query("DELETE FROM module_hooks WHERE module_id = ?")
        .bind(id)
        .execute(&mut **tx)
        .await?;
    for decl in decls {
        let before = kept.iter().find(|row| {
            row.get::<String, _>("kind") == decl.kind.as_str()
                && row.get::<String, _>("hook") == decl.hook
                && row.get::<String, _>("phase") == decl.phase
        });
        let priority = before.map_or(DEFAULT_PRIORITY, |row| row.get("priority"));
        let fail_closed = before.is_some_and(|row| row.get::<i64, _>("fail_closed") != 0);
        sqlx::query(
            "INSERT INTO module_hooks (module_id, kind, hook, phase, reads, priority, fail_closed)
             VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(id)
        .bind(decl.kind.as_str())
        .bind(&decl.hook)
        .bind(&decl.phase)
        .bind(serde_json::to_string(&decl.reads)?)
        .bind(priority)
        .bind(i64::from(fail_closed))
        .execute(&mut **tx)
        .await?;
    }
    Ok(())
}

impl Store {
    /// Changes every time a module is installed, removed, enabled, disabled or reconfigured,
    /// so a cache of what modules hook into knows when to rebuild.
    pub fn module_epoch(&self) -> u64 {
        self.module_epoch.load(Ordering::Acquire)
    }

    pub(in crate::store) fn touch_modules(&self) {
        self.module_epoch.fetch_add(1, Ordering::AcqRel);
    }

    /// Every hook of every installed module, in no particular order.
    pub async fn module_hooks(&self) -> anyhow::Result<Vec<ModuleHook>> {
        let rows = sqlx::query(
            "SELECT module_id, kind, hook, phase, reads, priority, fail_closed FROM module_hooks",
        )
        .fetch_all(&self.pool)
        .await?;
        Ok(rows
            .into_iter()
            .filter_map(|row| {
                let kind = HookKind::parse(&row.get::<String, _>("kind"))?;
                let reads: String = row.get("reads");
                Some(ModuleHook {
                    module_id: row.get("module_id"),
                    decl: HookDecl {
                        kind,
                        hook: row.get("hook"),
                        phase: row.get("phase"),
                        reads: serde_json::from_str(&reads).unwrap_or_default(),
                    },
                    priority: row.get("priority"),
                    fail_closed: row.get::<i64, _>("fail_closed") != 0,
                })
            })
            .collect())
    }

    /// Applies the admin's change to one hook. `Ok(false)` when no such hook exists.
    pub async fn update_module_hook(
        &self,
        module_id: &str,
        key: (HookKind, &str, &str),
        change: HookChange,
    ) -> anyhow::Result<bool> {
        let (kind, hook, phase) = key;
        let affected = sqlx::query(
            "UPDATE module_hooks
             SET priority = COALESCE(?, priority), fail_closed = COALESCE(?, fail_closed)
             WHERE module_id = ? AND kind = ? AND hook = ? AND phase = ?",
        )
        .bind(change.priority)
        .bind(change.fail_closed.map(i64::from))
        .bind(module_id)
        .bind(kind.as_str())
        .bind(hook)
        .bind(phase)
        .execute(&self.pool)
        .await?
        .rows_affected();
        self.touch_modules();
        Ok(affected > 0)
    }

    /// Stores what a module annotated a message with, replacing an earlier note from it.
    pub async fn save_message_annotations(
        &self,
        message: MessageId,
        module_id: &str,
        data: &str,
    ) -> anyhow::Result<()> {
        sqlx::query(
            "INSERT INTO message_annotations (message_id, module_id, data) VALUES (?, ?, ?)
             ON CONFLICT(message_id, module_id) DO UPDATE SET data = excluded.data",
        )
        .bind(message)
        .bind(module_id)
        .bind(data)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    /// What `module_id` annotated `message` with, as stored JSON text.
    pub async fn message_annotations(
        &self,
        message: MessageId,
        module_id: &str,
    ) -> anyhow::Result<Option<String>> {
        Ok(sqlx::query_scalar(
            "SELECT data FROM message_annotations WHERE message_id = ? AND module_id = ?",
        )
        .bind(message)
        .bind(module_id)
        .fetch_optional(&self.pool)
        .await?)
    }
}
