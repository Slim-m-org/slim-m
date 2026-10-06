// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The mediated-capability surface, per decision 0023 - the gate a module's
//! `slim.host_call` requests pass through.
//!
//! The gate, and the capabilities behind it: [`super::kv`]'s `kv.store` and
//! [`super::post`]'s `message.post`. A run gets [`CapabilitySurface::Enabled`]
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

use serde::Deserialize;
use serde_json::json;

use super::kv::{self, KvBackend};
use super::post::{self, MessagePoster};

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
        }
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
        let CapabilitySurface::Enabled {
            approved,
            module_id,
            kv,
            kv_calls_remaining,
            poster,
            posts_remaining,
        } = self
        else {
            return refusal("the capability surface is off");
        };
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
            approved.iter().map(|s| s.to_string()).collect(),
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
