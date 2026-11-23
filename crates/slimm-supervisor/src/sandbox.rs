// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The fixed container policy: every security field of a connector, its gateway and the
//! volume chown helper is set here, and the server can choose none of them (decision 0134).

use serde_json::{Value, json};

use crate::net::{Cidr, HostPort};
use crate::policy::Spec;

pub const MANAGED_BY: &str = "org.slim-m.managed-by";
pub const MANAGED_BY_VALUE: &str = "slimm-supervisor";
pub const INSTANCE: &str = "org.slim-m.instance";
pub const CONNECTOR: &str = "org.slim-m.connector";
pub const ROLE: &str = "org.slim-m.role";
pub const SPEC: &str = "org.slim-m.spec";
pub const EGRESS: &str = "org.slim-m.egress";
pub const EGRESS_PRIVATE: &str = "org.slim-m.egress-private";
pub const VOLUME: &str = "org.slim-m.volume";

pub const CONNECTOR_USER: &str = "65532:65532";
pub const GATEWAY_ALIAS: &str = "slimm-gateway";
pub const GATEWAY_PORT: u16 = 3128;
const GATEWAY_MEMORY_MIB: i64 = 64;
const GATEWAY_NANO_CPUS: i64 = 250_000_000;
const GATEWAY_PIDS: i64 = 64;
const MIB: i64 = 1024 * 1024;

/// The runtime object names for one connector under one supervisor instance.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Names {
    pub instance: String,
    pub id: String,
    pub container: String,
    pub gateway: String,
    pub network: String,
    pub volume: String,
    pub chown: String,
}

impl Names {
    pub fn new(instance: &str, id: &str) -> Self {
        let tail = format!("{instance}-{id}");
        Self {
            instance: instance.to_owned(),
            id: id.to_owned(),
            container: format!("slimm-c-{tail}"),
            gateway: format!("slimm-g-{tail}"),
            network: format!("slimm-n-{tail}"),
            volume: format!("slimm-v-{tail}"),
            chown: format!("slimm-o-{tail}"),
        }
    }

    /// The labels every object of this connector carries; `role` tells them apart.
    pub fn labels(&self, role: &str) -> serde_json::Map<String, Value> {
        let mut labels = serde_json::Map::new();
        labels.insert(MANAGED_BY.into(), MANAGED_BY_VALUE.into());
        labels.insert(INSTANCE.into(), self.instance.clone().into());
        labels.insert(CONNECTOR.into(), self.id.clone().into());
        labels.insert(ROLE.into(), role.into());
        labels
    }

    /// Whether `labels` say this object belongs to this connector of this instance.
    pub fn owns(&self, labels: &Value, role: &str) -> bool {
        let get = |key: &str| labels.get(key).and_then(Value::as_str);
        get(MANAGED_BY) == Some(MANAGED_BY_VALUE)
            && get(INSTANCE) == Some(self.instance.as_str())
            && get(CONNECTOR) == Some(self.id.as_str())
            && get(ROLE) == Some(role)
    }
}

/// The hardening every container the supervisor makes shares.
fn hardened_host_config(network_mode: &str, memory_bytes: i64, nano_cpus: i64, pids: i64) -> Value {
    json!({
        "Privileged": false,
        "CapDrop": ["ALL"],
        "CapAdd": [],
        "SecurityOpt": ["no-new-privileges:true"],
        "ReadonlyRootfs": true,
        "Tmpfs": {"/tmp": "rw,noexec,nosuid,nodev,size=64m"},
        "Binds": [],
        "Mounts": [],
        "Devices": [],
        "Sysctls": {},
        "PortBindings": {},
        "PublishAllPorts": false,
        "NetworkMode": network_mode,
        "IpcMode": "private",
        "PidMode": "",
        "UTSMode": "",
        "UsernsMode": "",
        "CgroupnsMode": "private",
        "Init": true,
        "Memory": memory_bytes,
        "MemorySwap": memory_bytes,
        "NanoCpus": nano_cpus,
        "PidsLimit": pids,
        "OomKillDisable": false,
        "RestartPolicy": {"Name": "no"},
        "LogConfig": {"Type": "json-file", "Config": {"max-size": "10m", "max-file": "3"}},
    })
}

/// The proxy variables, in both cases since tools disagree on which they read.
pub fn proxy_env() -> Vec<String> {
    let proxy = format!("http://{GATEWAY_ALIAS}:{GATEWAY_PORT}");
    ["HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy"]
        .iter()
        .map(|k| format!("{k}={proxy}"))
        .chain(
            ["NO_PROXY", "no_proxy"]
                .iter()
                .map(|k| format!("{k}={GATEWAY_ALIAS}")),
        )
        .collect()
}

pub fn connector_container(names: &Names, spec: &Spec) -> Value {
    let mut env: Vec<String> = spec.env.iter().map(|(k, v)| format!("{k}={v}")).collect();
    env.extend(proxy_env());
    let mut host = hardened_host_config(
        &names.network,
        spec.memory_mib as i64 * MIB,
        spec.nano_cpus(),
        spec.pids as i64,
    );
    if spec.volume {
        host["Mounts"] = json!([{"Type": "volume", "Source": names.volume, "Target": "/data", "ReadOnly": false}]);
    }
    let mut labels = names.labels("connector");
    labels.insert(SPEC.into(), spec.fingerprint().into());
    labels.insert(
        EGRESS.into(),
        serde_json::to_string(&spec.egress)
            .unwrap_or_default()
            .into(),
    );
    labels.insert(
        EGRESS_PRIVATE.into(),
        if spec.egress_private { "1" } else { "0" }.into(),
    );
    labels.insert(VOLUME.into(), if spec.volume { "1" } else { "0" }.into());
    json!({
        "Image": spec.image,
        "User": CONNECTOR_USER,
        "Env": env,
        "Labels": labels,
        "ExposedPorts": {},
        "NetworkDisabled": false,
        "HostConfig": host,
    })
}

/// What a gateway is told: the approved pairs, the server, the Private approval, the deny
/// list and the subnet its only clients come from.
#[derive(Debug, Clone, PartialEq)]
pub struct GatewayPlan {
    pub egress: Vec<HostPort>,
    pub egress_private: bool,
    pub server: HostPort,
    pub deny: Vec<Cidr>,
    pub clients: Vec<Cidr>,
}

pub fn gateway_container(names: &Names, image: &str, plan: &GatewayPlan) -> Value {
    let join = |items: Vec<String>| items.join(",");
    let env = vec![
        format!(
            "SLIMM_GATEWAY_ALLOW={}",
            join(plan.egress.iter().map(ToString::to_string).collect())
        ),
        format!("SLIMM_GATEWAY_SERVER={}", plan.server),
        format!("SLIMM_GATEWAY_PRIVATE={}", u8::from(plan.egress_private)),
        format!(
            "SLIMM_GATEWAY_DENY={}",
            join(plan.deny.iter().map(ToString::to_string).collect())
        ),
        format!(
            "SLIMM_GATEWAY_CLIENTS={}",
            join(plan.clients.iter().map(ToString::to_string).collect())
        ),
        format!("SLIMM_GATEWAY_PORT={GATEWAY_PORT}"),
    ];
    let host = hardened_host_config(
        &names.network,
        GATEWAY_MEMORY_MIB * MIB,
        GATEWAY_NANO_CPUS,
        GATEWAY_PIDS,
    );
    json!({
        "Image": image,
        "Cmd": ["gateway"],
        "User": CONNECTOR_USER,
        "Env": env,
        "Labels": names.labels("gateway"),
        "HostConfig": host,
        "NetworkingConfig": {"EndpointsConfig": {names.network.clone(): {"Aliases": [GATEWAY_ALIAS]}}},
    })
}

/// The one-shot that hands the fresh volume to 65532: root with only `CHOWN`, no network.
pub fn chown_container(names: &Names, image: &str) -> Value {
    let mut host = hardened_host_config("none", 32 * MIB, GATEWAY_NANO_CPUS, 16);
    host["CapAdd"] = json!(["CHOWN"]);
    host["Mounts"] =
        json!([{"Type": "volume", "Source": names.volume, "Target": "/data", "ReadOnly": false}]);
    json!({
        "Image": image,
        "Cmd": ["chown-data"],
        "User": "0:0",
        "Labels": names.labels("chown"),
        "HostConfig": host,
    })
}

pub fn internal_network(names: &Names) -> Value {
    json!({
        "Name": names.network,
        "Driver": "bridge",
        "Internal": true,
        "Attachable": false,
        "EnableIPv6": false,
        "Labels": names.labels("network"),
    })
}

pub fn volume(names: &Names) -> Value {
    json!({"Name": names.volume, "Labels": names.labels("volume")})
}

#[cfg(test)]
mod tests;
