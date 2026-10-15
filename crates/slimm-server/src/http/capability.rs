// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a client can check for before it commits to a server.
//!
//! slim-m's safety model is manual reporting plus blocking, and nothing else:
//! no automated scanning, no central authority to appeal to. A deployment
//! serving neither route is one where a member being harassed has no tool at
//! all, and they are entitled to learn that while they are still choosing.
//!
//! The list is read off the router rather than declared beside it. A hand-kept
//! list would only ever prove that somebody remembered to update it, which is
//! the one thing a safety guarantee cannot rest on.

use axum::Router;
use axum::body::Body;
use axum::http::{Method, Request, StatusCode, header};
use tower::ServiceExt as _;

/// An optional feature this build either serves or does not, named on
/// `/version` so a client can decide before it connects.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Capability {
    Block,
    Report,
    /// Whether this build serves the incoming-webhook delivery route at all.
    /// A client uses this to decide whether the (future) webhook admin
    /// surface is worth showing - `docs/decisions/0030-incoming-webhooks.md`
    /// names this exact use before that surface exists.
    Webhook,
    /// Whether large files can be sent as resumable parts; a client falls
    /// back to one request when this is absent.
    UploadSessions,
}

impl Capability {
    /// Every capability `/version` speaks about, in the order it reports them.
    pub const ALL: [Capability; 4] = [
        Capability::Block,
        Capability::Report,
        Capability::Webhook,
        Capability::UploadSessions,
    ];

    /// The name this goes over the wire under.
    pub fn wire_name(self) -> &'static str {
        match self {
            Capability::Block => "block",
            Capability::Report => "report",
            Capability::Webhook => "webhooks",
            Capability::UploadSessions => "upload_sessions",
        }
    }

    /// The request line that exists if and only if the capability does.
    ///
    /// Method as well as path, because both `/reports` routes are real and
    /// only one of them is this: `GET /reports` is the moderator's queue,
    /// while `POST /reports` is a member filing one. A path-only probe would
    /// read a deployment that kept the queue and dropped the intake as still
    /// offering reporting.
    fn backing_route(self) -> (Method, &'static str) {
        match self {
            Capability::Block => (Method::POST, "/blocks/00000000-0000-0000-0000-000000000000"),
            Capability::Report => (Method::POST, "/reports"),
            Capability::Webhook => (
                Method::POST,
                "/webhooks/00000000-0000-0000-0000-000000000000/probe",
            ),
            Capability::UploadSessions => (Method::POST, "/attachments/uploads"),
        }
    }
}

/// A method no route can be registered under, so a probe stops at routing.
const PROBE_METHOD: &[u8] = b"SLIMMPROBE";

/// Which of [`Capability::ALL`] the given router actually serves.
///
/// The probe asks with a method nothing can register and reads the `Allow`
/// header axum puts on the resulting 405, so routing answers on its own and
/// no handler ever runs: nothing authenticates, nothing is written, and a
/// report is not filed to discover whether reports can be filed.
pub async fn served_by(router: Router) -> Vec<Capability> {
    let mut served = Vec::new();
    for capability in Capability::ALL {
        if serves(router.clone(), capability).await {
            served.push(capability);
        }
    }
    served
}

async fn serves(router: Router, capability: Capability) -> bool {
    let (method, path) = capability.backing_route();
    let probe = Request::builder()
        .method(Method::from_bytes(PROBE_METHOD).expect("a valid method token"))
        .uri(path)
        .body(Body::empty())
        .expect("a valid probe request");
    let response = router.oneshot(probe).await.expect("routing cannot fail");
    if response.status() != StatusCode::METHOD_NOT_ALLOWED {
        return false;
    }
    response
        .headers()
        .get(header::ALLOW)
        .and_then(|allow| allow.to_str().ok())
        .is_some_and(|allow| allow.split(',').any(|allowed| allowed == method.as_str()))
}
