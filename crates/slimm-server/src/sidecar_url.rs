// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The shared "is this address safe to reach in cleartext" check for a
//! sidecar service an *operator* configures and trusts - the push relay
//! (`push::validate_relay_url`, before this existed) and the code runner
//! (`code_runner`). Not [`crate::net_guard`]: that module blocks private and
//! loopback ranges for a fetch of a *member-supplied* URL, the opposite
//! judgment call. Here, loopback and private-range addresses are exactly the
//! expected shape - an operator's own compose network - so they are allowed
//! over plain `http://`, and only a public host is held to `https://`.

use anyhow::Context;
use url::{Host, Url};

/// Refuses a sidecar URL that would send this server's traffic to it in
/// cleartext across a network the operator does not control. `https://` is
/// always fine; `http://` is allowed only for a loopback or private-range
/// host (RFC 1918 / RFC 4193), where there is nothing to leak to outside the
/// operator's own network. `var_name` names the setting in the error, so a
/// bad scheme fails loudly at startup with a message that says which
/// environment variable to fix.
pub(crate) fn validate(raw: &str, var_name: &str) -> anyhow::Result<()> {
    let url = Url::parse(raw).with_context(|| format!("{var_name} is not a valid URL: {raw:?}"))?;
    match url.scheme() {
        "https" => Ok(()),
        "http" if is_local(url.host()) => Ok(()),
        "http" => anyhow::bail!(
            "{var_name} ({raw}) uses http:// for a non-local host; \
             use https://, or point it at a loopback or private-range address"
        ),
        other => anyhow::bail!(
            "{var_name} ({raw}) has an unsupported scheme {other:?}; \
             it must be https:// (or http:// only for a loopback/private-range host)"
        ),
    }
}

/// Whether a sidecar host is loopback or private-range: the cases where an
/// unencrypted, operator-local connection is legitimate rather than a leak.
/// Matches the boundaries RFC 1918 and RFC 4193 define (so, for example,
/// 172.16.0.0/12 is private but 172.32.0.0 is not, and `localhost` counts
/// without a DNS lookup). A single-label name (`piston`, `push-relay`) is a
/// compose service or a LAN host, never a public DNS name, so it counts too,
/// as do the reserved local suffixes.
fn is_local(host: Option<Host<&str>>) -> bool {
    match host {
        Some(Host::Domain(domain)) => is_local_name(domain),
        Some(Host::Ipv4(addr)) => addr.is_loopback() || addr.is_private(),
        Some(Host::Ipv6(addr)) => addr.is_loopback() || addr.is_unique_local(),
        None => false,
    }
}

fn is_local_name(domain: &str) -> bool {
    let domain = domain.trim_end_matches('.').to_ascii_lowercase();
    !domain.contains('.')
        || [".localhost", ".local", ".internal", ".lan", ".home.arpa"]
            .iter()
            .any(|suffix| domain.ends_with(suffix))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requires_https_for_a_public_host() {
        assert!(validate("https://relay.example.com", "TEST").is_ok());
        assert!(validate("http://relay.example.com", "TEST").is_err());
        assert!(validate("ftp://relay.example.com", "TEST").is_err());
        assert!(validate("not a url", "TEST").is_err());
    }

    #[test]
    fn allows_http_for_loopback_and_private_ranges() {
        for ok in [
            "http://127.0.0.1:9000",
            "http://localhost:9000",
            "http://LOCALHOST:9000",
            "http://10.1.2.3",
            "http://172.16.0.1",
            "http://172.31.255.255",
            "http://192.168.1.1",
            "http://[::1]:9000",
            "http://piston:2000",
            "http://push-relay:8080",
            "http://jellyfin.lan:8096",
            "http://nas.home.arpa",
            "http://runner.internal",
        ] {
            assert!(
                validate(ok, "TEST").is_ok(),
                "{ok} should be allowed over http"
            );
        }
        assert!(
            validate("http://172.32.0.1", "TEST").is_err(),
            "RFC 1918's 172.16/12 ends at 172.31.255.255, so 172.32.0.0 is a \
             routable public address and must require https"
        );
        assert!(
            validate("http://piston.example.com", "TEST").is_err(),
            "a dotted public-looking name is not a compose service"
        );
    }

    #[test]
    fn error_message_names_the_offending_variable() {
        let err = validate("http://public.example.com", "SLIMM_CODE_RUNNER_URL")
            .unwrap_err()
            .to_string();
        assert!(err.contains("SLIMM_CODE_RUNNER_URL"), "{err}");
    }
}
