// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What the supervisor checks before it will create anything: the runtime can enforce the
//! limits and the sandbox, or no connector runs at all (decision 0134).

use std::path::Path;

use serde::Serialize;
use serde_json::{Value, json};

use crate::error::ApiError;
use crate::runtime::Runtime;
use crate::sandbox::{INSTANCE, MANAGED_BY, MANAGED_BY_VALUE, ROLE};

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct Readiness {
    pub runtime: &'static str,
    pub rootless: bool,
    pub problems: Vec<String>,
}

impl Readiness {
    pub fn ready(&self) -> bool {
        self.problems.is_empty()
    }
}

/// Reads `/version` and `/info`, checks the egress network and the supervisor's own image,
/// and creates and removes an internal network as a probe.
pub async fn check(
    runtime: &Runtime,
    instance: &str,
    egress_network: &str,
    own_image: &str,
) -> Result<Readiness, ApiError> {
    let version = runtime.get("/version").await?.json();
    let info = runtime.get("/info").await?.json();
    let mut readiness = judge_info(&version, &info);
    match runtime.get(&format!("/networks/{egress_network}")).await? {
        reply if reply.status.is_success() => {
            if reply.json().get("Internal").and_then(Value::as_bool) == Some(true) {
                readiness.problems.push(format!(
                    "egress network {egress_network} is internal, so gateways cannot reach out"
                ));
            }
        }
        _ => readiness
            .problems
            .push(format!("egress network {egress_network} does not exist")),
    }
    if !runtime
        .get(&format!("/images/{own_image}/json"))
        .await?
        .status
        .is_success()
        && let Err(err) = runtime.pull(own_image).await
    {
        readiness.problems.push(format!(
            "the supervisor image {own_image} is not available: {}",
            err.detail
        ));
    }
    if let Err(problem) = probe_internal_network(runtime, instance).await {
        readiness.problems.push(problem);
    }
    Ok(readiness)
}

/// The pure half: cgroup v2 with memory, cpu and pids limits, and a seccomp profile that is not unconfined.
pub fn judge_info(version: &Value, info: &Value) -> Readiness {
    let components = version.get("Components").and_then(Value::as_array);
    let podman = components.is_some_and(|c| {
        c.iter().any(|x| {
            x.get("Name")
                .and_then(Value::as_str)
                .is_some_and(|n| n.to_ascii_lowercase().contains("podman"))
        })
    });
    let options: Vec<&str> = info
        .get("SecurityOptions")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    let mut problems = Vec::new();
    if info.get("CgroupVersion").and_then(Value::as_str) != Some("2") {
        problems.push("the runtime is not on cgroup v2".to_owned());
    }
    for (field, what) in [
        ("MemoryLimit", "memory"),
        ("CpuCfsQuota", "cpu"),
        ("PidsLimit", "pids"),
    ] {
        if info.get(field).and_then(Value::as_bool) != Some(true) {
            problems.push(format!(
                "the cgroup {what} controller is not available to the runtime"
            ));
        }
    }
    let seccomp = options.iter().find(|o| o.contains("name=seccomp"));
    match seccomp {
        None => problems.push("the runtime has no seccomp profile".to_owned()),
        Some(opt) if opt.contains("profile=unconfined") => {
            problems.push("the runtime's seccomp profile is unconfined".to_owned())
        }
        Some(_) => {}
    }
    Readiness {
        runtime: if podman { "podman" } else { "docker" },
        rootless: options.iter().any(|o| o.contains("name=rootless")),
        problems,
    }
}

async fn probe_internal_network(runtime: &Runtime, instance: &str) -> Result<(), String> {
    let name = format!("slimm-probe-{instance}");
    let _ = runtime.delete(&format!("/networks/{name}")).await;
    let body = json!({
        "Name": name, "Driver": "bridge", "Internal": true,
        "Labels": {MANAGED_BY: MANAGED_BY_VALUE, INSTANCE: instance, ROLE: "probe"},
    });
    let created = runtime
        .post("/networks/create", Some(&body))
        .await
        .map_err(|e| e.detail)?;
    if !created.status.is_success() {
        return Err(format!(
            "the runtime cannot create an internal network: {}",
            created.message()
        ));
    }
    let inspected = runtime
        .get(&format!("/networks/{name}"))
        .await
        .map_err(|e| e.detail)?
        .json();
    let _ = runtime.delete(&format!("/networks/{name}")).await;
    if inspected.get("Internal").and_then(Value::as_bool) != Some(true) {
        return Err("the runtime made the probe network routable".to_owned());
    }
    Ok(())
}

/// The instance id, made once and kept, so two deployments on one host never share connectors.
pub fn instance_id(state_dir: &Path) -> std::io::Result<String> {
    let path = state_dir.join("instance-id");
    if let Ok(existing) = std::fs::read_to_string(&path) {
        let existing = existing.trim().to_owned();
        if existing.len() == 16 && existing.chars().all(|c| c.is_ascii_hexdigit()) {
            return Ok(existing);
        }
    }
    std::fs::create_dir_all(state_dir)?;
    let id = uuid::Uuid::now_v7().simple().to_string()[16..].to_owned();
    std::fs::write(&path, &id)?;
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn good_info() -> Value {
        json!({"CgroupVersion": "2", "MemoryLimit": true, "CpuCfsQuota": true, "PidsLimit": true,
               "SecurityOptions": ["name=seccomp,profile=builtin", "name=cgroupns"]})
    }

    #[test]
    fn a_capable_docker_is_ready() {
        let r = judge_info(&json!({"Components": [{"Name": "Engine"}]}), &good_info());
        assert!(r.ready(), "{:?}", r.problems);
        assert_eq!(r.runtime, "docker");
        assert!(!r.rootless);
    }

    #[test]
    fn missing_limits_or_seccomp_are_named() {
        let mut info = good_info();
        info["CgroupVersion"] = json!("1");
        info["PidsLimit"] = json!(false);
        info["SecurityOptions"] = json!(["name=seccomp,profile=unconfined", "name=rootless"]);
        let r = judge_info(&json!({"Components": [{"Name": "Podman Engine"}]}), &info);
        assert_eq!(r.runtime, "podman");
        assert!(r.rootless);
        assert_eq!(r.problems.len(), 3, "{:?}", r.problems);
        info["SecurityOptions"] = json!([]);
        assert!(
            judge_info(&json!({}), &info)
                .problems
                .iter()
                .any(|p| p.contains("no seccomp"))
        );
    }

    #[test]
    fn the_instance_id_is_kept() {
        let dir =
            std::env::temp_dir().join(format!("slimm-sup-state-{}", uuid::Uuid::now_v7().simple()));
        let first = instance_id(&dir).unwrap();
        assert_eq!(instance_id(&dir).unwrap(), first);
        assert_eq!(first.len(), 16);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
