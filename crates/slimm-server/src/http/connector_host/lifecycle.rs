// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What install, enable, disable and uninstall ask of the supervisor for a host-run connector.

use std::collections::BTreeMap;

use super::client::{CreateBody, Limits, Listed, SupervisorError};
use super::{HostRun, HostRunner};
use crate::http::AppState;
use crate::http::error::ApiError;
use crate::store::HostRun as HostRunRecord;

/// Told when the supervisor cannot take a request; the reason is in the Dock's status.
pub(crate) const UNAVAILABLE: ApiError = ApiError::Coded {
    status: axum::http::StatusCode::SERVICE_UNAVAILABLE,
    message: "the connector runtime is unavailable; try again once it is back",
    code: "connector_runtime_unavailable",
};

/// Told when a manifest asks to be host-run and the operator has not set the supervisor up.
pub(crate) const NOT_SET_UP: ApiError = ApiError::NotConfigured(
    "this server is not set up to run connectors; an operator has to turn the connector supervisor on",
);

impl HostRunner {
    pub(crate) fn require_available(&self) -> Result<(), ApiError> {
        match self.unavailable_reason() {
            None => Ok(()),
            Some(_) => Err(UNAVAILABLE),
        }
    }

    /// Creates the container with a fresh token: a container made again never reuses one.
    pub(crate) async fn create(
        &self,
        state: &AppState,
        record: &HostRunRecord,
    ) -> Result<(), SupervisorError> {
        let actor = record
            .principal
            .ok_or_else(|| SupervisorError::Unavailable("the connector has no principal".into()))?;
        let (token, revoked) = state
            .store
            .reissue_connector_token(&record.module_id, actor)
            .await
            .map_err(|err| {
                SupervisorError::Unavailable(format!("minting the connector's token failed: {err}"))
            })?
            .ok_or_else(|| {
                SupervisorError::Unavailable("the connector is no longer installed".into())
            })?;
        crate::http::session_revocation::sessions_revoked_by_id(state, revoked);
        let body = create_body(&self.api_url, record, token);
        self.client.create(&record.run_id, &body).await
    }

    /// Brings an enabled connector to running from whatever state the supervisor reports.
    pub(crate) async fn ensure_running(
        &self,
        state: &AppState,
        record: &HostRunRecord,
        listed: Option<&Listed>,
    ) -> Result<(), SupervisorError> {
        match listed.map(|l| l.state.as_str()) {
            Some("running") => Ok(()),
            Some("created" | "exited") => self.client.start(&record.run_id).await,
            _ => {
                self.client.remove(&record.run_id, true).await?;
                self.create(state, record).await?;
                self.client.start(&record.run_id).await
            }
        }
    }

    /// Records what happened, so the admin sees the reason on the connector.
    pub(crate) async fn note(
        &self,
        state: &AppState,
        module_id: &str,
        result: &Result<(), SupervisorError>,
    ) {
        let (error, refused) = match result {
            Ok(()) => (None, false),
            Err(err) => (Some(err.detail().to_owned()), err.is_policy()),
        };
        if let Err(err) = state
            .store
            .set_host_run_error(module_id, error.as_deref(), refused)
            .await
        {
            tracing::warn!(%err, module = module_id, "could not record a host-run connector's state");
        }
    }
}

/// The create body: the connector's address for the server and its token, in both the
/// names decision 0134 uses and the ones the slimbots library reads.
pub(crate) fn create_body<'a>(
    api_url: &str,
    record: &'a HostRunRecord,
    token: String,
) -> CreateBody<'a> {
    let env = BTreeMap::from([
        ("SLIMM_API_URL", api_url.to_owned()),
        ("SLIMM_URL", api_url.to_owned()),
        ("SLIMM_TOKEN", token.clone()),
        ("SLIMM_BOT_TOKEN", token),
        ("SLIMM_CONNECTOR", "1".to_owned()),
    ]);
    CreateBody {
        image: &record.spec.image,
        env,
        limits: Limits {
            memory_mib: record.spec.memory_mib,
            cpus: record.spec.cpus,
            pids: record.spec.pids,
            volume_mib: record.spec.volume_mib,
        },
        egress: &record.spec.egress,
        egress_private: record.spec.egress_private,
        volume: record.spec.volume,
    }
}

/// After an install or update: replace any old container, create the new one, and start it
/// if the connector is enabled. Failures are kept on the connector for the admin and the
/// monitor retries what can be retried.
pub(crate) async fn after_install(state: &AppState, runner: &HostRun, record: &HostRunRecord) {
    let _pass = runner.pause_monitor().await;
    let result = async {
        runner.client.remove(&record.run_id, true).await?;
        runner.create(state, record).await?;
        if record.enabled {
            runner.client.start(&record.run_id).await?;
        }
        Ok(())
    }
    .await;
    runner.note(state, &record.module_id, &result).await;
    runner.nudge();
}

/// Enabling clears the crash breaker and any refusal; the monitor starts it.
pub(crate) async fn after_enable(
    state: &AppState,
    runner: &HostRun,
    module_id: &str,
) -> Result<(), ApiError> {
    let _pass = runner.pause_monitor().await;
    runner.forget_crashes(module_id);
    state
        .store
        .set_host_run_crash_disabled(module_id, None)
        .await?;
    if let Some(record) = state.store.host_run(module_id).await? {
        let result = match runner.client.list().await {
            Ok(listed) => {
                let found = listed.iter().find(|c| c.id == record.run_id);
                runner.ensure_running(state, &record, found).await
            }
            Err(err) => Err(err),
        };
        runner.set_running(module_id, result.is_ok());
        runner.note(state, module_id, &result).await;
    }
    runner.nudge();
    Ok(())
}

/// A disabled connector's token is already powerless; stopping the container follows.
pub(crate) async fn after_disable(state: &AppState, runner: &HostRun, module_id: &str) {
    runner.set_running(module_id, false);
    if let Ok(Some(record)) = state.store.host_run(module_id).await
        && let Err(err) = runner.client.stop(&record.run_id).await
    {
        tracing::info!(
            module = module_id,
            reason = err.detail(),
            "stopping a disabled connector waits for the supervisor"
        );
    }
    runner.nudge();
}

/// Removes the container, gateway and network, and the volume unless `keep_volume`.
/// Asking for the volume to go is refused while the supervisor cannot do it, with the connector
/// turned off so the monitor does not bring it back; keeping it only logs, the monitor finishes.
pub(crate) async fn before_uninstall(
    state: &AppState,
    runner: &HostRun,
    module_id: &str,
    keep_volume: bool,
) -> Result<(), ApiError> {
    let Some(record) = state.store.host_run(module_id).await? else {
        return Ok(());
    };
    if !keep_volume {
        runner.require_available()?;
        state.store.set_module_enabled(module_id, false).await?;
        runner.set_running(module_id, false);
    }
    match runner.client.remove(&record.run_id, keep_volume).await {
        Ok(()) => Ok(()),
        Err(err) if keep_volume => {
            tracing::warn!(module = module_id, run = %record.run_id, reason = err.detail(),
                "could not remove an uninstalled connector's container; the monitor removes it later and keeps its volume");
            Ok(())
        }
        Err(err) => {
            tracing::warn!(module = module_id, run = %record.run_id, reason = err.detail(),
                "could not remove a connector's container and volume; the uninstall waits");
            Err(UNAVAILABLE)
        }
    }
}

/// An update that stops asking for the host: the run id is about to be forgotten, so the
/// volume goes with the container, since nothing could name it afterwards.
pub(crate) async fn remove_dropped(runner: &HostRun, record: &HostRunRecord) {
    if let Err(err) = runner.client.remove(&record.run_id, false).await {
        tracing::warn!(module = %record.module_id, run = %record.run_id, reason = err.detail(),
            "could not remove a connector that left the host; the monitor removes the container later and keeps its volume");
    }
}
