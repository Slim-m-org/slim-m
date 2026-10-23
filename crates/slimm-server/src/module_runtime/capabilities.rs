// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The mediated-capability surface, per decision 0023 - the gate a module's
//! `slim.host_call` requests pass through.
//!
//! The gate, and the capabilities behind it: [`super::kv`]'s `kv.store`,
//! [`super::post`]'s `message.post` and [`super::net`]'s `net.fetch`. A run gets [`CapabilitySurface::Enabled`]
//! only when an admin approved at least one host capability for the module at
//! install (`http::module_host`); every other run is [`CapabilitySurface::Disabled`],
//! so a module may import nothing and every `host_call` is refused. A capability
//! the module did not have approved, or one the host does not implement, is
//! refused even on an enabled run.
//!
//! Everything here fails closed: an off surface, an unapproved capability, a
//! malformed request, or a capability the host does not implement all return a
//! clean `{ "ok": false, "error": ... }`, never a trap and never anything from
//! outside the module. The module is never trusted to have sent a well-formed
//! or authorized request.

use std::sync::Arc;
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::json;

use super::kv::{self, KvBackend};
use super::log_read::{self, LogBackend};
use super::net::{self, HttpFetcher};
use super::post::{self, MessagePoster};

/// Most host calls one run may make, of any kind: room for every per-capability
/// budget at once, plus some refusals.
pub const MAX_HOST_CALLS_PER_RUN: u32 = 128;

/// Whether the capability surface is available to a module run, and - when it
/// is - the space-approved capability set, the module's identity and storage
/// backend, and this run's `kv.store` call budget.
#[derive(Clone, Default)]
pub enum CapabilitySurface {
    /// The surface is off (the default, and a module with no approved
    /// capabilities). A module may import nothing; `slim.host_call` is refused like any other import.
    #[default]
    Disabled,
    /// The surface is on for this run.
    Enabled {
        /// The capabilities the space approved for this module at install
        /// (decision 0021's `approved_capabilities`).
        approved: Vec<String>,
        /// The module this run belongs to; its `kv.store` data is keyed by it,
        /// so no module can reach another's.
        module_id: String,
        /// Where `kv.store` data lives - a trait seam so the capability's shape
        /// is judged without deciding how it persists (decision 0023).
        kv: Arc<dyn KvBackend>,
        /// Remaining `kv.store` calls this run may make, decremented per call.
        kv_calls_remaining: u32,
        /// Posts as the invoking user; `None` leaves `message.post` unavailable.
        poster: Option<Arc<dyn MessagePoster>>,
        /// Remaining `message.post` attempts this run may make.
        posts_remaining: u32,
        /// Dials approved hosts; `None` leaves `net.fetch` unavailable.
        fetcher: Option<Arc<dyn HttpFetcher>>,
        /// The hosts the admin approved with `net.fetch`.
        network_hosts: Vec<String>,
        /// Remaining `net.fetch` attempts this run may make.
        fetches_remaining: u32,
        /// The durable logs `log.read` reads; `None` leaves it unavailable.
        logs: Option<Arc<dyn LogBackend>>,
        /// Remaining host calls of any kind, refused ones included, so a loop
        /// of bad requests is bounded by more than the wall clock.
        calls_remaining: u32,
    },
}

impl CapabilitySurface {
    /// An enabled surface for `module_id` with `approved` capabilities and `kv`
    /// as its store backend, and a fresh per-run `kv.store` call budget.
    pub fn enabled(
        approved: Vec<String>,
        module_id: impl Into<String>,
        kv: Arc<dyn KvBackend>,
    ) -> Self {
        CapabilitySurface::Enabled {
            approved,
            module_id: module_id.into(),
            kv,
            kv_calls_remaining: kv::MAX_CALLS_PER_RUN,
            poster: None,
            posts_remaining: post::MAX_POSTS_PER_RUN,
            fetcher: None,
            network_hosts: Vec::new(),
            fetches_remaining: net::MAX_FETCHES_PER_RUN,
            logs: None,
            calls_remaining: MAX_HOST_CALLS_PER_RUN,
        }
    }

    /// Makes `net.fetch` available through `fetcher`, to `hosts` only. A
    /// no-op on a disabled surface.
    pub fn with_fetcher(mut self, new_fetcher: Arc<dyn HttpFetcher>, hosts: Vec<String>) -> Self {
        if let CapabilitySurface::Enabled {
            fetcher,
            network_hosts,
            ..
        } = &mut self
        {
            *fetcher = Some(new_fetcher);
            *network_hosts = hosts;
        }
        self
    }

    /// Makes `log.read` available through `logs`. A no-op on a disabled surface.
    pub fn with_logs(mut self, new_logs: Arc<dyn LogBackend>) -> Self {
        if let CapabilitySurface::Enabled { logs, .. } = &mut self {
            *logs = Some(new_logs);
        }
        self
    }

    /// Makes `message.post` available through `poster`. A no-op on a disabled
    /// surface.
    pub fn with_poster(mut self, new_poster: Arc<dyn MessagePoster>) -> Self {
        if let CapabilitySurface::Enabled { poster, .. } = &mut self {
            *poster = Some(new_poster);
        }
        self
    }

    /// Whether this run may link the single `slim.host_call` import: only when
    /// the surface is on and the space approved at least one capability for the
    /// module. A module importing it under any other condition is refused at
    /// instantiation (see `host.rs`).
    pub fn allows_host_call(&self) -> bool {
        matches!(self, CapabilitySurface::Enabled { approved, .. } if !approved.is_empty())
    }

    /// Dispatches one `host_call` request to the approved capability's handler,
    /// returning the UTF-8 JSON response bytes. Fails closed: an off surface, an
    /// unapproved capability, a malformed request, or a capability the host does
    /// not implement all return a clean `{ok:false,error}`.
    pub fn dispatch(&mut self, request: &[u8]) -> Vec<u8> {
        self.dispatch_before(request, None)
    }

    /// As [`dispatch`](Self::dispatch), with the run's `deadline` so a slow
    /// capability gives up while the module can still answer.
    pub fn dispatch_before(&mut self, request: &[u8], deadline: Option<Instant>) -> Vec<u8> {
        let CapabilitySurface::Enabled {
            approved,
            module_id,
            kv,
            kv_calls_remaining,
            poster,
            posts_remaining,
            fetcher,
            network_hosts,
            fetches_remaining,
            logs,
            calls_remaining,
        } = self
        else {
            return refusal("the capability surface is off");
        };
        if *calls_remaining == 0 {
            return refusal("host_call budget for this run is exhausted");
        }
        *calls_remaining -= 1;
        let parsed: HostCallRequest = match serde_json::from_slice(request) {
            Ok(parsed) => parsed,
            Err(_) => return refusal("malformed host_call request"),
        };
        if !approved.iter().any(|c| c == &parsed.capability) {
            return refusal(&format!("capability not approved: {}", parsed.capability));
        }
        match parsed.capability.as_str() {
            "kv.store" => kv::handle(kv.as_ref(), module_id, kv_calls_remaining, request),
            "message.post" => match poster {
                Some(poster) => post::handle(poster.as_ref(), posts_remaining, request),
                None => refusal("message.post needs a channel"),
            },
            "net.fetch" => match fetcher {
                Some(fetcher) => {
                    let remaining = deadline.map_or(Duration::MAX, |d| {
                        d.saturating_duration_since(Instant::now())
                    });
                    net::handle(
                        fetcher.as_ref(),
                        network_hosts,
                        fetches_remaining,
                        (request, remaining),
                    )
                }
                None => refusal("net.fetch is not available to this run"),
            },
            "log.read" => logs.as_ref().map_or_else(
                || refusal("log.read is not available to this run"),
                |logs| log_read::handle(logs.as_ref(), request),
            ),
            // Approved, but the host implements no such capability; it fails closed.
            other => refusal(&format!("capability not available: {other}")),
        }
    }
}

/// The envelope every `host_call` request shares: which capability it targets.
/// Its arguments are capability-specific and parsed by the handler, not here.
#[derive(Deserialize)]
struct HostCallRequest {
    capability: String,
}

fn refusal(message: &str) -> Vec<u8> {
    serde_json::to_vec(&json!({ "ok": false, "error": message }))
        .unwrap_or_else(|_| br#"{"ok":false,"error":"host error"}"#.to_vec())
}

#[cfg(test)]
mod tests {
    use super::super::kv::InMemoryKv;
    use super::*;

    fn text(bytes: &[u8]) -> String {
        String::from_utf8(bytes.to_vec()).unwrap()
    }

    fn enabled(approved: &[&str]) -> CapabilitySurface {
        CapabilitySurface::enabled(
            approved
                .iter()
                .map(std::string::ToString::to_string)
                .collect(),
            "m",
            Arc::new(InMemoryKv::default()),
        )
    }

    #[test]
    fn a_disabled_surface_allows_no_host_call_and_refuses_every_request() {
        let mut surface = CapabilitySurface::Disabled;
        assert!(!surface.allows_host_call());
        assert!(
            text(&surface.dispatch(br#"{"capability":"kv.store"}"#)).contains("surface is off")
        );
    }

    #[test]
    fn enabled_with_no_approved_capability_allows_no_host_call() {
        assert!(!enabled(&[]).allows_host_call());
    }

    #[test]
    fn enabled_with_an_approved_capability_allows_host_call() {
        assert!(enabled(&["kv.store"]).allows_host_call());
    }

    #[test]
    fn an_unapproved_capability_is_refused() {
        let mut surface = enabled(&["message.post"]);
        let out = text(&surface.dispatch(br#"{"capability":"kv.store","op":"list"}"#));
        assert!(out.contains("not approved: kv.store"), "{out}");
    }

    #[test]
    fn an_approved_post_with_no_poster_is_refused_cleanly() {
        // The gate passes (approved) but the host has no such capability.
        let mut surface = enabled(&["message.post"]);
        let out = text(&surface.dispatch(br#"{"capability":"message.post"}"#));
        assert!(out.contains("message.post needs a channel"), "{out}");
        assert!(out.contains(r#""ok":false"#), "{out}");
    }

    #[test]
    fn refused_calls_spend_the_run_budget_too() {
        let mut surface = enabled(&["kv.store"]);
        for _ in 0..MAX_HOST_CALLS_PER_RUN {
            surface.dispatch(b"not json");
        }
        let out = text(&surface.dispatch(br#"{"capability":"kv.store","op":"list"}"#));
        assert!(
            out.contains("host_call budget for this run is exhausted"),
            "{out}"
        );
    }

    #[test]
    fn an_approved_kv_store_request_routes_to_the_capability() {
        let mut surface = enabled(&["kv.store"]);
        let set = text(
            &surface.dispatch(br#"{"capability":"kv.store","op":"set","key":"a","value":"1"}"#),
        );
        assert!(set.contains(r#""ok":true"#), "{set}");
        let get = text(&surface.dispatch(br#"{"capability":"kv.store","op":"get","key":"a"}"#));
        assert!(get.contains(r#""value":"1""#), "{get}");
    }

    #[test]
    fn a_malformed_request_is_refused_not_panicked() {
        let mut surface = enabled(&["kv.store"]);
        assert!(text(&surface.dispatch(b"not json")).contains("malformed"));
    }
}
