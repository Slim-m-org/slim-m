// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Builds a connector's gateway fresh on every start, so it runs the current supervisor
//! image and denies every runtime network that exists at that moment.

use serde_json::{Value, json};

use super::{Supervisor, egress_of};
use crate::error::{ApiError, Code};
use crate::net::Cidr;
use crate::runtime::encode;
use crate::sandbox::{self, GatewayPlan, Names};

impl Supervisor {
    pub(super) async fn recreate_gateway(&self, names: &Names) -> Result<(), ApiError> {
        let connector = self
            .owned_container(&names.container, names, "connector")
            .await?
            .ok_or_else(|| ApiError::new(Code::NotFound, "no such connector"))?;
        let (egress, egress_private, _) = egress_of(&connector);
        let networks = self.runtime.get("/networks").await?.json();
        let own = networks
            .as_array()
            .into_iter()
            .flatten()
            .find(|n| n.get("Name").and_then(Value::as_str) == Some(names.network.as_str()))
            .cloned()
            .unwrap_or(Value::Null);
        super::objects::require_isolated(&own, names)?;
        let plan = GatewayPlan {
            egress,
            egress_private,
            server: self.server().clone(),
            deny: deny_list(&networks, &self.config.lan_deny),
            clients: subnets_of(&networks, &names.network),
        };
        if plan.clients.is_empty() {
            return Err(ApiError::runtime("the connector network has no subnet"));
        }
        self.remove_container(&names.gateway, names, "gateway")
            .await?;
        let body = sandbox::gateway_container(names, &self.pinned_image().await?, &plan);
        self.create_container(&names.gateway, &body).await?;
        let connect = json!({"Container": names.gateway});
        let path = format!("/networks/{}/connect", encode(&self.config.egress_network));
        let reply = self.runtime.post(&path, Some(&connect)).await?;
        if !reply.ok() {
            return Err(ApiError::runtime(format!(
                "joining the egress network failed: {}",
                reply.message()
            )));
        }
        Ok(())
    }
}

/// Every subnet and gateway address of every runtime network, plus the operator's list.
pub fn deny_list(networks: &Value, operator: &[Cidr]) -> Vec<Cidr> {
    let mut deny: Vec<Cidr> = operator.to_vec();
    for network in networks.as_array().into_iter().flatten() {
        for config in ipam_configs(network) {
            deny.extend(
                config
                    .get("Subnet")
                    .and_then(Value::as_str)
                    .and_then(Cidr::parse),
            );
            deny.extend(
                config
                    .get("Gateway")
                    .and_then(Value::as_str)
                    .and_then(Cidr::parse),
            );
        }
    }
    deny
}

/// The subnets of the named network: the only addresses a gateway takes connections from.
pub fn subnets_of(networks: &Value, name: &str) -> Vec<Cidr> {
    networks
        .as_array()
        .into_iter()
        .flatten()
        .filter(|n| n.get("Name").and_then(Value::as_str) == Some(name))
        .flat_map(ipam_configs)
        .filter_map(|c| {
            c.get("Subnet")
                .and_then(Value::as_str)
                .and_then(Cidr::parse)
        })
        .collect()
}

fn ipam_configs(network: &Value) -> impl Iterator<Item = &Value> {
    network
        .pointer("/IPAM/Config")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_runtime_network_and_the_operator_list_are_denied() {
        let networks = json!([
            {"Name": "bridge", "IPAM": {"Config": [{"Subnet": "172.17.0.0/16", "Gateway": "172.17.0.1"}]}},
            {"Name": "host", "IPAM": {"Config": []}},
            {"Name": "slimm-n-x", "IPAM": {"Config": [{"Subnet": "172.30.0.0/16"}]}},
        ]);
        let deny = deny_list(&networks, &[Cidr::parse("192.168.1.0/24").unwrap()]);
        let ip = |t: &str| t.parse().unwrap();
        assert!(deny.iter().any(|c| c.contains(ip("172.17.0.1"))));
        assert!(deny.iter().any(|c| c.contains(ip("172.30.9.9"))));
        assert!(deny.iter().any(|c| c.contains(ip("192.168.1.7"))));
        assert_eq!(
            subnets_of(&networks, "slimm-n-x"),
            vec![Cidr::parse("172.30.0.0/16").unwrap()]
        );
    }
}
