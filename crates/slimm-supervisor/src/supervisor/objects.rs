// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Runtime objects by name, each checked against this instance's labels before it is touched.

use serde_json::Value;

use super::Supervisor;
use crate::error::{ApiError, Code};
use crate::runtime::{Reply, encode};
use crate::sandbox::{self, Names};

/// What a name points at: nothing, ours, or something the supervisor did not make.
pub enum Owned {
    Missing,
    Ours(Value),
    Foreign,
}

impl Supervisor {
    async fn fetch(
        &self,
        path: &str,
        names: &Names,
        role: &str,
        labels_at: &str,
    ) -> Result<Owned, ApiError> {
        let reply = self.runtime.get(path).await?;
        if reply.status.as_u16() == 404 {
            return Ok(Owned::Missing);
        }
        if !reply.status.is_success() {
            return Err(ApiError::runtime(reply.message()));
        }
        let json = reply.json();
        let labels = json.pointer(labels_at).cloned().unwrap_or(Value::Null);
        Ok(if names.owns(&labels, role) {
            Owned::Ours(json)
        } else {
            Owned::Foreign
        })
    }

    async fn container(&self, name: &str, names: &Names, role: &str) -> Result<Owned, ApiError> {
        self.fetch(
            &format!("/containers/{}/json", encode(name)),
            names,
            role,
            "/Config/Labels",
        )
        .await
    }

    /// The container if this instance made it for this connector; a foreign one is refused.
    pub(super) async fn owned_container(
        &self,
        name: &str,
        names: &Names,
        role: &str,
    ) -> Result<Option<Value>, ApiError> {
        match self.container(name, names, role).await? {
            Owned::Missing => Ok(None),
            Owned::Ours(json) => Ok(Some(json)),
            Owned::Foreign => Err(ApiError::policy(format!(
                "{name} exists but the supervisor did not create it"
            ))),
        }
    }

    pub(super) async fn ensure_network(&self, names: &Names) -> Result<(), ApiError> {
        match self
            .fetch(
                &format!("/networks/{}", encode(&names.network)),
                names,
                "network",
                "/Labels",
            )
            .await?
        {
            Owned::Ours(_) => Ok(()),
            Owned::Foreign => Err(ApiError::policy(format!(
                "{} exists but the supervisor did not create it",
                names.network
            ))),
            Owned::Missing => {
                let reply = self
                    .runtime
                    .post("/networks/create", Some(&sandbox::internal_network(names)))
                    .await?;
                expect_success(&reply, "creating the connector network")
            }
        }
    }

    pub(super) async fn ensure_volume(&self, names: &Names) -> Result<(), ApiError> {
        match self
            .fetch(
                &format!("/volumes/{}", encode(&names.volume)),
                names,
                "volume",
                "/Labels",
            )
            .await?
        {
            Owned::Foreign => {
                return Err(ApiError::policy(format!(
                    "{} exists but the supervisor did not create it",
                    names.volume
                )));
            }
            Owned::Ours(_) => {}
            Owned::Missing => {
                let reply = self
                    .runtime
                    .post("/volumes/create", Some(&sandbox::volume(names)))
                    .await?;
                expect_success(&reply, "creating the connector volume")?;
            }
        }
        self.chown_volume(names).await
    }

    async fn chown_volume(&self, names: &Names) -> Result<(), ApiError> {
        self.remove_container(&names.chown, names, "chown").await?;
        self.create_container(
            &names.chown,
            &sandbox::chown_container(names, &self.config.own_image),
        )
        .await?;
        self.start_container(&names.chown).await?;
        let waited = self
            .runtime
            .post(&format!("/containers/{}/wait", encode(&names.chown)), None)
            .await?;
        let status = waited.json().get("StatusCode").and_then(Value::as_i64);
        self.remove_container(&names.chown, names, "chown").await?;
        match status {
            Some(0) => Ok(()),
            _ => Err(ApiError::runtime(format!(
                "setting the volume owner failed ({})",
                waited.message()
            ))),
        }
    }

    pub(super) async fn create_container(&self, name: &str, body: &Value) -> Result<(), ApiError> {
        let reply = self
            .runtime
            .post(
                &format!("/containers/create?name={}", encode(name)),
                Some(body),
            )
            .await?;
        match reply.status.as_u16() {
            200 | 201 => Ok(()),
            404 => Err(ApiError::policy(format!(
                "the image is not available: {}",
                reply.message()
            ))),
            409 => Err(ApiError::new(Code::Conflict, reply.message())),
            400 => Err(ApiError::policy(format!(
                "the runtime refused the container: {}",
                reply.message()
            ))),
            _ => Err(ApiError::runtime(reply.message())),
        }
    }

    pub(super) async fn start_container(&self, name: &str) -> Result<(), ApiError> {
        let reply = self
            .runtime
            .post(&format!("/containers/{}/start", encode(name)), None)
            .await?;
        expect_success(&reply, "starting the container")
    }

    pub(super) async fn stop_container(&self, name: &str, timeout_s: u64) -> Result<(), ApiError> {
        let reply = self
            .runtime
            .post(
                &format!("/containers/{}/stop?t={timeout_s}", encode(name)),
                None,
            )
            .await?;
        if reply.status.as_u16() == 404 {
            return Ok(());
        }
        expect_success(&reply, "stopping the container")
    }

    /// Removes the container only if it is ours; a foreign one with the name is left alone.
    pub(super) async fn remove_container(
        &self,
        name: &str,
        names: &Names,
        role: &str,
    ) -> Result<(), ApiError> {
        if let Owned::Ours(_) = self.container(name, names, role).await? {
            let reply = self
                .runtime
                .delete(&format!("/containers/{}?force=true", encode(name)))
                .await?;
            if reply.status.as_u16() != 404 {
                expect_success(&reply, "removing the container")?;
            }
        }
        Ok(())
    }

    /// Container, gateway, network and, unless kept, the volume; unknown ids are a success.
    pub(super) async fn teardown(&self, names: &Names, keep_volume: bool) -> Result<(), ApiError> {
        self.remove_container(&names.container, names, "connector")
            .await?;
        self.remove_container(&names.gateway, names, "gateway")
            .await?;
        self.remove_container(&names.chown, names, "chown").await?;
        if let Owned::Ours(_) = self
            .fetch(
                &format!("/networks/{}", encode(&names.network)),
                names,
                "network",
                "/Labels",
            )
            .await?
        {
            let reply = self
                .runtime
                .delete(&format!("/networks/{}", encode(&names.network)))
                .await?;
            if reply.status.as_u16() != 404 {
                expect_success(&reply, "removing the connector network")?;
            }
        }
        if keep_volume {
            return Ok(());
        }
        if let Owned::Ours(_) = self
            .fetch(
                &format!("/volumes/{}", encode(&names.volume)),
                names,
                "volume",
                "/Labels",
            )
            .await?
        {
            let reply = self
                .runtime
                .delete(&format!("/volumes/{}", encode(&names.volume)))
                .await?;
            if reply.status.as_u16() != 404 {
                expect_success(&reply, "removing the connector volume")?;
            }
        }
        Ok(())
    }
}

fn expect_success(reply: &Reply, what: &str) -> Result<(), ApiError> {
    if reply.ok() {
        Ok(())
    } else {
        Err(ApiError::runtime(format!(
            "{what} failed: {}",
            reply.message()
        )))
    }
}
