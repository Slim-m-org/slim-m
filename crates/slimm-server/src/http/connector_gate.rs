// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a connector's token may call beyond the permission bits it was approved (decision
//! 0090, review of 2026-11-23). Many routes check no bit because every member may use them;
//! a connector is not a member using the app, so its token is held to this table first.

use axum::extract::MatchedPath;
use axum::http::request::Parts;

use super::error::ApiError;
use crate::permissions::Permissions;
use crate::store::ConnectorGrant;

const TURNED_OFF: ApiError = ApiError::ForbiddenBecause("an admin has turned this connector off");
const NOT_FOR_CONNECTORS: ApiError =
    ApiError::ForbiddenBecause("a connector's token cannot use this route");

/// What a route asks of a connector before its handler runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Rule {
    /// Its handler's own permission check is the whole answer.
    Handler,
    /// Never: an account's own settings, devices, notifications and the like are a person's.
    Never,
    /// Only with this bit approved, though the route itself checks none.
    Needs(Permissions),
}

/// Refuses a disabled connector everywhere but `GET /connectors/me`, which tells it why.
pub(super) fn check(parts: &Parts, grant: ConnectorGrant) -> Result<(), ApiError> {
    let route = parts
        .extensions
        .get::<MatchedPath>()
        .map(MatchedPath::as_str)
        .unwrap_or_default();
    let segments: Vec<&str> = route
        .trim_start_matches('/')
        .split('/')
        .map(|s| if s.starts_with('{') { "{}" } else { s })
        .collect();
    let method = parts.method.as_str();
    if (method, segments.as_slice()) == ("GET", ["connectors", "me"].as_slice()) {
        return Ok(());
    }
    if !grant.enabled {
        return Err(TURNED_OFF);
    }
    match rule(method, &segments) {
        Rule::Handler => Ok(()),
        Rule::Never => Err(NOT_FOR_CONNECTORS),
        Rule::Needs(bit) if grant.cap.contains(bit) => Ok(()),
        Rule::Needs(_) => Err(ApiError::Forbidden),
    }
}

fn rule(method: &str, segments: &[&str]) -> Rule {
    const VIEW: Rule = Rule::Needs(Permissions::VIEW_CHANNEL);
    match (method, segments) {
        ("POST", ["auth", "ws-ticket"]) | ("GET", ["me"]) => Rule::Handler,
        (
            _,
            [
                "auth"
                | "account"
                | "me"
                | "devices"
                | "push"
                | "notifications"
                | "notification-preferences"
                | "voice-notifications"
                | "favorites"
                | "saved"
                | "blocks"
                | "exports"
                | "diagnostics"
                | "debug-logs"
                | "reports"
                | "invites"
                | "invite"
                | "links"
                | "read-states"
                | "presence",
                ..,
            ],
        )
        | (_, ["users", "{}", "note"])
        | (_, ["messages", "{}", "save"])
        | (_, ["space", "rules", "accept"])
        | (
            _,
            [
                "voice",
                "rings" | "screen-stamps" | "transcription-notice",
                ..,
            ],
        ) => Rule::Never,
        (_, ["dms", ..]) => Rule::Needs(Permissions::SEND_MESSAGES),
        (_, ["attachments", ..]) => Rule::Needs(Permissions::ATTACH_FILES),
        (_, ["channels", "{}", "voice", ..]) => Rule::Needs(Permissions::CONNECT),
        (
            "GET",
            [
                "members" | "users" | "categories" | "emoji" | "soundboard" | "modules"
                | "direct-route" | "space",
                ..,
            ],
        )
        | ("GET", ["channels"])
        | (
            "GET",
            [
                "channels",
                "{}",
                "permissions" | "thread-parent" | "bot-commands" | "bot-ui",
            ],
        )
        | ("GET", ["bots", "{}", "commands"]) => VIEW,
        _ => Rule::Handler,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seg(path: &str) -> Vec<&str> {
        path.trim_start_matches('/').split('/').collect()
    }

    #[test]
    fn a_persons_own_routes_are_never_a_connectors() {
        for (m, p) in [
            ("PATCH", "/me"),
            ("POST", "/reports"),
            ("GET", "/devices"),
            ("POST", "/me/avatar"),
            ("DELETE", "/push"),
        ] {
            assert_eq!(rule(m, &seg(p)), Rule::Never, "{m} {p}");
        }
        assert_eq!(rule("GET", &seg("/me")), Rule::Handler);
        assert_eq!(rule("POST", &seg("/auth/ws-ticket")), Rule::Handler);
        assert_eq!(
            rule("GET", &seg("/members")),
            Rule::Needs(Permissions::VIEW_CHANNEL)
        );
        assert_eq!(rule("POST", &seg("/channels/{}/messages")), Rule::Handler);
        assert_eq!(
            rule("POST", &seg("/dms")),
            Rule::Needs(Permissions::SEND_MESSAGES)
        );
    }
}
