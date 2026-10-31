// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The hooks that are live right now, rebuilt lazily when any module changes.
//! A message send reads this on every call, so the idle case is two atomic
//! loads and no allocation, lock or query.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, RwLock};

use crate::http::module_compat::incompatibility;
use crate::http::module_host::effective_capabilities;
use crate::store::{HookDecl, HookKind, InstalledModule, Store};

use super::super::dock::{INTERCEPTOR_CAPABILITY, PERMISSION_CAPABILITY};

/// One live hook: the module it belongs to and how the admin set it.
pub(crate) struct Entry {
    pub(super) module: Arc<InstalledModule>,
    pub(super) decl: HookDecl,
    pub(super) fail_closed: bool,
    priority: i64,
}

/// Every live hook, each family already in the order it runs.
#[derive(Default)]
pub(crate) struct Snapshot {
    pub(super) interceptors: Vec<Entry>,
    pub(super) permissions: Vec<Entry>,
}

impl Snapshot {
    /// Whether `module_id` has an annotate interceptor, so its events may carry annotations.
    pub(crate) fn annotates(&self, module_id: &str) -> bool {
        self.interceptors
            .iter()
            .any(|e| e.module.id == module_id && e.decl.phase == "annotate")
    }

    fn is_empty(&self) -> bool {
        self.interceptors.is_empty() && self.permissions.is_empty()
    }
}

pub struct Registry {
    seen: AtomicU64,
    idle: AtomicBool,
    current: RwLock<Arc<Snapshot>>,
    rebuilding: tokio::sync::Mutex<()>,
}

impl Default for Registry {
    fn default() -> Self {
        Self {
            seen: AtomicU64::new(u64::MAX),
            idle: AtomicBool::new(true),
            current: RwLock::default(),
            rebuilding: tokio::sync::Mutex::new(()),
        }
    }
}

impl Registry {
    /// Whether no module hooks into anything right now.
    pub async fn is_idle(&self, store: &Store) -> bool {
        self.active(store).await.is_none()
    }

    /// The live hooks, or `None` when there are none.
    pub(crate) async fn active(&self, store: &Store) -> Option<Arc<Snapshot>> {
        if self.seen.load(Ordering::Acquire) != store.module_epoch() {
            self.rebuild(store).await;
        }
        if self.idle.load(Ordering::Acquire) {
            return None;
        }
        Some(self.current.read().map(|s| s.clone()).unwrap_or_default())
    }

    async fn rebuild(&self, store: &Store) {
        let _one_at_a_time = self.rebuilding.lock().await;
        let epoch = store.module_epoch();
        if self.seen.load(Ordering::Acquire) == epoch {
            return;
        }
        match build(store).await {
            Ok(snapshot) => {
                self.idle.store(snapshot.is_empty(), Ordering::Release);
                if let Ok(mut current) = self.current.write() {
                    *current = Arc::new(snapshot);
                }
                self.seen.store(epoch, Ordering::Release);
            }
            Err(err) => tracing::warn!(%err, "could not rebuild the module hook list"),
        }
    }
}

async fn build(store: &Store) -> anyhow::Result<Snapshot> {
    let modules = store.list_installed_modules().await?;
    let mut snapshot = Snapshot::default();
    let mut ranked: Vec<(i64, Entry)> = Vec::new();
    for hook in store.module_hooks().await? {
        let Some(module) = modules.iter().find(|m| m.id == hook.module_id) else {
            continue;
        };
        if !live(module, hook.decl.kind) {
            continue;
        }
        ranked.push((
            module.installed_at,
            Entry {
                module: Arc::new(module.clone()),
                decl: hook.decl,
                fail_closed: hook.fail_closed,
                priority: hook.priority,
            },
        ));
    }
    ranked.sort_by(|(a_at, a), (b_at, b)| {
        (
            phase_rank(&a.decl),
            a.priority,
            a_at,
            &a.module.id,
            &a.decl.hook,
        )
            .cmp(&(
                phase_rank(&b.decl),
                b.priority,
                b_at,
                &b.module.id,
                &b.decl.hook,
            ))
    });
    for (_, entry) in ranked {
        match entry.decl.kind {
            HookKind::Interceptor => snapshot.interceptors.push(entry),
            HookKind::Permission => snapshot.permissions.push(entry),
        }
    }
    Ok(snapshot)
}

/// The fixed order of an interceptor phase; a permission hook has none.
fn phase_rank(decl: &HookDecl) -> usize {
    super::super::dock::PHASES
        .iter()
        .position(|p| *p == decl.phase)
        .unwrap_or(0)
}

/// Whether the module may be asked at all: on, in range, and approved for this kind of hook.
fn live(module: &InstalledModule, kind: HookKind) -> bool {
    let capability = match kind {
        HookKind::Interceptor => INTERCEPTOR_CAPABILITY,
        HookKind::Permission => PERMISSION_CAPABILITY,
    };
    module.enabled
        && incompatibility(module).is_none()
        && effective_capabilities(module)
            .iter()
            .any(|c| c == capability)
}
