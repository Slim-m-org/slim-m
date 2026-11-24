// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The background watcher: every [`TICK`] it looks at LiveKit, the disk, the sweeps, the backup
//! status, the push relay and the module breaker, and opens or closes the matching alerts.

use std::collections::HashSet;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use super::backup_status::BackupReport;
use super::watch::{self, LivekitWatch};
use super::{AlertKind, Notifier};
use crate::push::PushSender;
use crate::state::AppState;
use crate::store::{Store, now_ms};
use crate::sweeps::RECORDED_SWEEPS;
use crate::voice::VoiceService;

/// How often conditions are re-checked; the LiveKit grace period is measured in these.
const TICK: Duration = Duration::from_secs(30);

/// What the monitor needs from the process config.
#[derive(Debug, Clone)]
pub struct MonitorSettings {
    pub data_dir: PathBuf,
    pub backup_status_dir: Option<String>,
    pub min_disk_free_mb: u64,
}

impl MonitorSettings {
    pub fn from_config(config: &crate::config::Config) -> Self {
        let data_dir = std::path::Path::new(&config.database_path)
            .parent()
            .filter(|dir| !dir.as_os_str().is_empty())
            .map_or_else(|| PathBuf::from("."), PathBuf::from);
        Self {
            data_dir,
            backup_status_dir: config.backup_status_dir.clone(),
            min_disk_free_mb: config.alert_min_disk_free_mb,
        }
    }
}

/// Watches for the conditions and keeps the alerts in step with them.
pub struct Monitor {
    notifier: Notifier,
    store: Store,
    voice: VoiceService,
    push: PushSender,
    settings: MonitorSettings,
    livekit: LivekitWatch,
    open: HashSet<(AlertKind, String)>,
    /// Conditions this process has confirmed closed, so only the first look writes a resolve.
    closed: HashSet<(AlertKind, String)>,
}

impl Monitor {
    pub fn new(state: &AppState, settings: MonitorSettings) -> Self {
        Self {
            notifier: Notifier::from_state(state),
            store: state.store.clone(),
            voice: state.voice.clone(),
            push: state.push.clone(),
            settings,
            livekit: LivekitWatch::default(),
            open: HashSet::new(),
            closed: HashSet::new(),
        }
    }

    /// One look at everything. `uptime` is how long this process has run.
    pub async fn tick(&mut self, now: i64, uptime: Duration) {
        let reachable = self.voice.probe_reachable().await;
        let livekit = self.livekit.observe(now, reachable);
        self.settle(AlertKind::Livekit, "", livekit).await;

        let disk = watch::free_bytes(&self.settings.data_dir)
            .and_then(|free| watch::disk_problem(free, self.settings.min_disk_free_mb));
        self.settle(AlertKind::DiskLow, "", disk).await;

        self.settle_sweeps(now, uptime).await;

        let backup = BackupReport::read(self.settings.backup_status_dir.as_deref()).problem(now);
        self.settle(AlertKind::Backup, "", backup).await;

        let relay = watch::relay_problem(self.push.relay_consecutive_failures());
        self.settle(AlertKind::PushRelay, "", relay).await;

        self.settle_modules().await;
    }

    async fn settle_sweeps(&mut self, now: i64, uptime: Duration) {
        let Ok(recorded) = self.store.sweep_statuses().await else {
            return;
        };
        let failing = watch::failing_sweeps(&RECORDED_SWEEPS, &recorded, now, uptime);
        for (name, _) in RECORDED_SWEEPS {
            let problem = failing
                .iter()
                .any(|f| f == name)
                .then(|| format!("The {name} sweep has not completed in several scheduled runs."));
            self.settle(AlertKind::SweepFailing, name, problem).await;
        }
    }

    /// A tripped breaker is raised where it trips; here it closes once the module runs again.
    async fn settle_modules(&mut self) {
        let kind = AlertKind::ModuleBreaker.as_str();
        let Ok(subjects) = self.store.open_admin_alert_subjects(kind).await else {
            return;
        };
        for module_id in subjects {
            let running = match self.store.installed_module(&module_id).await {
                Ok(Some(module)) => module.enabled,
                Ok(None) => true,
                Err(_) => continue,
            };
            if running {
                self.notifier
                    .resolve(AlertKind::ModuleBreaker, &module_id)
                    .await;
            }
        }
    }

    /// Moves the alert to match `problem`; the remembered state follows only a write that landed.
    async fn settle(&mut self, kind: AlertKind, subject: &str, problem: Option<String>) {
        let key = (kind, subject.to_owned());
        match problem {
            Some(detail) if !self.open.contains(&key) => {
                match self.notifier.try_raise(kind, subject, &detail).await {
                    Ok(()) => {
                        self.closed.remove(&key);
                        self.open.insert(key);
                    }
                    Err(err) => warn_unsettled(kind, "raise", &err),
                }
            }
            None if !self.closed.contains(&key) => {
                match self.notifier.try_resolve(kind, subject).await {
                    Ok(()) => {
                        self.open.remove(&key);
                        self.closed.insert(key);
                    }
                    Err(err) => warn_unsettled(kind, "resolve", &err),
                }
            }
            _ => {}
        }
    }
}

fn warn_unsettled(kind: AlertKind, action: &str, err: &anyhow::Error) {
    tracing::warn!(error = %err, kind = kind.as_str(), action, "admin alert write failed; retrying next tick");
}

/// Runs the monitor for the life of the process, first look after one [`TICK`].
pub fn spawn_monitor(state: AppState, settings: MonitorSettings) {
    let started = Instant::now();
    let mut monitor = Monitor::new(&state, settings);
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(TICK);
        ticker.tick().await;
        loop {
            ticker.tick().await;
            monitor.tick(now_ms(), started.elapsed()).await;
        }
    });
}
