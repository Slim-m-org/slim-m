// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What the supervisor checks before it will create anything: the runtime can enforce the
//! limits and the sandbox, or no connector runs at all (decision 0134).

use std::path::Path;

use serde::Serialize;
use serde_json::Value;

use crate::error::ApiError;
use crate::runtime::Runtime;
use crate::sandbox::{
    INSTANCE, MANAGED_BY, MANAGED_BY_VALUE, ROLE, isolated_network, network_is_isolated,
};

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
    wanted: Requirements,
) -> Result<Readiness, ApiError> {
    let version = runtime.get("/version").await?.json();
    let info = runtime.get("/info").await?.json();
    let mut readiness = judge_info(&version, &info, wanted);
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

/// The oldest Docker Engine that can make an internal network the host has no address on
/// (gateway mode `isolated`, 28.0.0); it also has the embedded-resolver fix for CVE-2024-29018.
pub const MIN_DOCKER: (u64, u64, u64) = (28, 0, 0);

/// What the runtime is asked to enforce beyond its defaults.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Requirements {
    /// An AppArmor or SELinux profile on every container; off only in tests on a host without either.
    pub lsm: bool,
}

impl Default for Requirements {
    fn default() -> Self {
        Self { lsm: true }
    }
}

/// The pure half: rootful Docker of at least [`MIN_DOCKER`], cgroup v2 with memory, cpu and
/// pids limits, a seccomp profile that is not unconfined, and AppArmor or SELinux.
pub fn judge_info(version: &Value, info: &Value, wanted: Requirements) -> Readiness {
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
    let rootless = options.iter().any(|o| o.contains("name=rootless"));
    let mut problems = Vec::new();
    if podman {
        problems.push(
            "Podman is not supported: only rootful Docker Engine 28.0.0 or newer (docs/connectors/operating.md)"
                .to_owned(),
        );
    } else {
        let raw = version
            .get("Version")
            .and_then(Value::as_str)
            .unwrap_or_default();
        match parse_version(raw) {
            Some(v) if v >= MIN_DOCKER => {}
            _ => problems.push(format!(
                "Docker Engine {raw:?} is older than 28.0.0, which connectors need"
            )),
        }
    }
    if rootless {
        problems.push(
            "rootless Docker is not supported: only rootful Docker Engine 28.0.0 or newer (docs/connectors/operating.md)"
                .to_owned(),
        );
    }
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
    let lsm = options
        .iter()
        .any(|o| o.contains("name=apparmor") || o.contains("name=selinux"));
    if wanted.lsm && !lsm {
        problems.push(
            "the runtime applies neither AppArmor nor SELinux, so containers would run unconfined; on an SELinux host set \"selinux-enabled\": true in /etc/docker/daemon.json"
                .to_owned(),
        );
    }
    Readiness {
        runtime: if podman { "podman" } else { "docker" },
        rootless,
        problems,
    }
}

/// `28.0.4`, `29.1.0-rc.1` and the like, as numbers; `None` for anything else.
pub fn parse_version(raw: &str) -> Option<(u64, u64, u64)> {
    let core = raw.split(['-', '+']).next()?;
    let mut parts = core.split('.').map(|p| p.parse::<u64>().ok());
    let major = parts.next()??;
    let minor = parts.next().unwrap_or(Some(0))?;
    let patch = parts.next().unwrap_or(Some(0))?;
    Some((major, minor, patch))
}

async fn probe_internal_network(runtime: &Runtime, instance: &str) -> Result<(), String> {
    let name = format!("slimm-probe-{instance}");
    let _ = runtime.delete(&format!("/networks/{name}")).await;
    let mut labels = serde_json::Map::new();
    labels.insert(MANAGED_BY.into(), MANAGED_BY_VALUE.into());
    labels.insert(INSTANCE.into(), instance.into());
    labels.insert(ROLE.into(), "probe".into());
    let body = isolated_network(&name, labels);
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
    if !network_is_isolated(&inspected) {
        return Err(
            "the runtime cannot make an internal network that gives the host no address on it (gateway mode isolated)"
                .to_owned(),
        );
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
    use serde_json::json;

    fn good_version() -> Value {
        json!({"Version": "28.0.0", "Components": [{"Name": "Engine"}]})
    }

    fn good_info() -> Value {
        json!({"CgroupVersion": "2", "MemoryLimit": true, "CpuCfsQuota": true, "PidsLimit": true,
               "SecurityOptions": ["name=apparmor", "name=seccomp,profile=builtin", "name=cgroupns"]})
    }

    fn judge(version: &Value, info: &Value) -> Readiness {
        judge_info(version, info, Requirements::default())
    }

    #[test]
    fn a_capable_docker_is_ready() {
        let r = judge(&good_version(), &good_info());
        assert!(r.ready(), "{:?}", r.problems);
        assert_eq!(r.runtime, "docker");
        assert!(!r.rootless);
        let mut info = good_info();
        info["SecurityOptions"] = json!(["name=seccomp,profile=builtin", "name=selinux"]);
        assert!(judge(&good_version(), &info).ready());
    }

    #[test]
    fn missing_limits_or_seccomp_are_named() {
        let mut info = good_info();
        info["CgroupVersion"] = json!("1");
        info["PidsLimit"] = json!(false);
        info["SecurityOptions"] = json!(["name=seccomp,profile=unconfined", "name=apparmor"]);
        let r = judge(&good_version(), &info);
        assert_eq!(r.problems.len(), 3, "{:?}", r.problems);
        info["SecurityOptions"] = json!(["name=apparmor"]);
        assert!(
            judge(&good_version(), &info)
                .problems
                .iter()
                .any(|p| p.contains("no seccomp"))
        );
    }

    #[test]
    fn an_engine_older_than_the_floor_is_refused() {
        for old in ["27.5.1", "26.1.4", "25.0.5", "", "dev"] {
            let r = judge(&json!({"Version": old}), &good_info());
            assert!(
                r.problems.iter().any(|p| p.contains("older than 28.0.0")),
                "{old}: {:?}",
                r.problems
            );
        }
        for new in ["28.0.0", "28.0.0-rc.2", "29.10.0"] {
            assert!(
                judge(&json!({"Version": new}), &good_info()).ready(),
                "{new}"
            );
        }
        assert_eq!(parse_version("28.0.0-rc.2"), Some((28, 0, 0)));
        assert_eq!(parse_version("x.1"), None);
    }

    #[test]
    fn podman_and_rootless_docker_are_refused_by_name() {
        let r = judge(
            &json!({"Version": "5.4.0", "Components": [{"Name": "Podman Engine"}]}),
            &good_info(),
        );
        assert_eq!(r.runtime, "podman");
        assert!(
            r.problems
                .iter()
                .any(|p| p.contains("Podman is not supported"))
        );
        let mut info = good_info();
        info["SecurityOptions"] = json!([
            "name=apparmor",
            "name=seccomp,profile=builtin",
            "name=rootless"
        ]);
        let r = judge(&good_version(), &info);
        assert!(r.rootless);
        assert!(
            r.problems
                .iter()
                .any(|p| p.contains("rootless Docker is not supported"))
        );
    }

    #[test]
    fn a_runtime_without_apparmor_or_selinux_is_refused() {
        let mut info = good_info();
        info["SecurityOptions"] = json!(["name=seccomp,profile=builtin", "name=cgroupns"]);
        let r = judge(&good_version(), &info);
        assert!(
            r.problems
                .iter()
                .any(|p| p.contains("neither AppArmor nor SELinux")),
            "{:?}",
            r.problems
        );
        assert!(judge_info(&good_version(), &info, Requirements { lsm: false }).ready());
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
