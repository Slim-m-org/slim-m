// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /direct-route`: where a signed-in native client on the deployment's own network can
//! reach this server directly.
//!
//! This used to ride on the unauthenticated `/version`, which handed anyone on the internet
//! the deployment's private LAN address; it now needs a session.

use axum::Router;
use axum::routing::get;
use serde::Serialize;

use super::AppState;
use super::error::ApiError;
use super::extract::{AUTHED_READ, AuthedLimited, Json};

/// The direct-route route, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new().route("/direct-route", get(direct_route))
}

#[derive(Serialize)]
struct DirectRouteDto {
    /// `host:port` of the same TLS endpoint over the deployment's own network; empty unless
    /// the operator sets `SLIMM_DIRECT_ADDRESSES`.
    addresses: Vec<String>,
}

async fn direct_route(
    AuthedLimited(_ctx): AuthedLimited<AUTHED_READ>,
) -> Result<Json<DirectRouteDto>, ApiError> {
    Ok(Json(DirectRouteDto {
        addresses: direct_addresses(std::env::var("SLIMM_DIRECT_ADDRESSES").ok()),
    }))
}

/// `SLIMM_DIRECT_ADDRESSES`, comma separated, read here rather than carried on [`AppState`]
/// because that struct is built literally across the integration tests. An entry that is not
/// `host:port` is dropped with a warning rather than advertised for clients to trip over.
fn direct_addresses(raw: Option<String>) -> Vec<String> {
    let Some(raw) = raw else {
        return Vec::new();
    };
    raw.split(',')
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .filter(|entry| {
            let valid = is_host_port(entry);
            if !valid {
                tracing::warn!(
                    entry,
                    "SLIMM_DIRECT_ADDRESSES entry is not host:port; ignoring it"
                );
            }
            valid
        })
        .map(str::to_owned)
        .collect()
}

fn is_host_port(entry: &str) -> bool {
    let Some((host, port)) = entry.rsplit_once(':') else {
        return false;
    };
    !host.is_empty()
        && !host.contains(['/', ' ', '@'])
        && port.parse::<u16>().is_ok_and(|port| port != 0)
}

#[cfg(test)]
mod tests {
    use super::direct_addresses;

    #[test]
    fn unset_or_blank_advertises_nothing() {
        assert!(direct_addresses(None).is_empty());
        assert!(direct_addresses(Some(" , ".to_owned())).is_empty());
    }

    #[test]
    fn host_port_entries_are_kept_and_anything_else_dropped() {
        let parsed = direct_addresses(Some(
            "10.0.0.100:443, nas.lan:8443,https://x:1,10.0.0.5,host:0,host:99999".to_owned(),
        ));
        assert_eq!(parsed, ["10.0.0.100:443", "nas.lan:8443"]);
    }
}
