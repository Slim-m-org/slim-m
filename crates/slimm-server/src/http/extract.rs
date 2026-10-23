// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The bearer-token authentication extractor, shared by every authenticated
//! route, plus the `Json`, `Query` and `Bytes` extractors every handler in
//! this crate uses in their place: same wire behaviour as axum's own, but a
//! malformed or oversized request rejects with [`ApiError`] instead of
//! axum's default plain text.

use std::net::SocketAddr;

use axum::extract::{ConnectInfo, FromRequest, FromRequestParts, Request};
use axum::http::header::AUTHORIZATION;
use axum::http::request::Parts;
use axum::response::{IntoResponse, Response};
use serde::Serialize;
use serde::de::DeserializeOwned;

use super::AppState;
use super::error::ApiError;
use crate::ids::UserId;
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{BOT_TOKEN_PREFIX, SessionContext};

/// The session a request is authenticated as, resolved from its bearer access
/// token. Rejects with 401 when the header is absent or the token is invalid.
///
/// A bot presents a bot token instead, which resolves to a session of its own
/// (see `docs/decisions/0028-bot-accounts.md`). The two are told apart by the
/// token's prefix rather than by trying both tables, so a person's request
/// still costs exactly one indexed lookup. The prefix is a routing hint and
/// never an authorization one - the hash is what authenticates either way.
pub(crate) struct Authed(pub(crate) SessionContext);

impl FromRequestParts<AppState> for Authed {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let token = parts
            .headers
            .get(AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            .and_then(|header| header.strip_prefix("Bearer "))
            .map(str::to_owned)
            .ok_or(ApiError::Unauthorized)?;
        let ctx = if token.starts_with(BOT_TOKEN_PREFIX) {
            state.store.authenticate_bot(&token).await?
        } else {
            state.store.authenticate(&token).await?
        }
        .ok_or(ApiError::Unauthorized)?;
        Ok(Authed(ctx))
    }
}

/// The caller's identity for rate-limiting purposes: the authenticated user when
/// there is one, otherwise the peer address. Authenticated callers are keyed by
/// user so a limit follows the account across devices and networks, rather than
/// being shed by reconnecting from a new address.
///
/// The unauthenticated key is the peer address unless the operator has said how
/// many proxies sit in front of this server (`trusted_hops`). A forwarded header
/// is unsigned and anyone may send one, so believing it by default would let a
/// caller mint a fresh bucket per request.
///
/// What makes a non-zero setting safe is counting from the *right*. A proxy
/// appends the address it saw, so the rightmost entry was written by the nearest
/// proxy and each step left is one hop further out. A caller can prepend as many
/// entries as they like and never reach the slot `trusted_hops` selects.
///
/// This matters more than it looks: with no setting and a reverse proxy in
/// front - which is what `deploy/` ships - every unauthenticated caller in the
/// world shares one bucket, so one client can hold the password bucket empty and
/// nobody can sign in. Caddy has no built-in per-IP limit to do this instead.
pub(crate) fn limit_key(
    parts: &Parts,
    ctx: Option<&SessionContext>,
    trusted_hops: usize,
) -> String {
    if let Some(ctx) = ctx {
        return format!("u:{}", ctx.user_id);
    }
    super::proxy_hint::observe(parts, trusted_hops);
    if trusted_hops > 0
        && let Some(addr) = forwarded_for(parts, trusted_hops)
    {
        return match addr.parse::<std::net::IpAddr>() {
            Ok(ip) => anonymous_key(ip),
            Err(_) => format!("ip:{addr}"),
        };
    }
    parts
        .extensions
        .get::<ConnectInfo<SocketAddr>>()
        .map(|ConnectInfo(addr)| anonymous_key(addr.ip()))
        .unwrap_or_else(|| "ip:unknown".to_owned())
}

/// One key per IPv4 address, but one per IPv6 /64: a single subscriber
/// usually holds a whole /64, so keying each address would let one network
/// mint fresh buckets without end (issue 2068).
fn anonymous_key(ip: std::net::IpAddr) -> String {
    match ip {
        std::net::IpAddr::V4(v4) => format!("ip:{v4}"),
        std::net::IpAddr::V6(v6) => match v6.to_ipv4_mapped() {
            Some(v4) => format!("ip:{v4}"),
            None => {
                let prefix = u128::from(v6) & !((1u128 << 64) - 1);
                format!("ip:{}/64", std::net::Ipv6Addr::from(prefix))
            }
        },
    }
}

/// The address `hops` from the right of `X-Forwarded-For`, or `None` when the
/// header is absent or too short to have one.
///
/// Too short is deliberately `None` rather than the leftmost entry: falling back
/// to whatever the client sent is exactly the spoof this counts from the right to
/// avoid, and the peer address is a safe answer where this has none.
fn forwarded_for(parts: &Parts, hops: usize) -> Option<String> {
    let header = parts.headers.get("x-forwarded-for")?.to_str().ok()?;
    let addrs: Vec<&str> = header
        .split(',')
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .collect();
    addrs
        .len()
        .checked_sub(hops)
        .and_then(|index| addrs.get(index))
        .map(|addr| (*addr).to_owned())
}

/// Enforces the rate limit for `class`, keyed by the caller.
pub(crate) fn enforce(
    state: &AppState,
    parts: &Parts,
    ctx: Option<&SessionContext>,
    class: Class,
) -> Result<(), ApiError> {
    let key = limit_key(parts, ctx, state.limiter.trusted_hops());
    state.limiter.admit(class, &key).map_err(ApiError::from)
}

/// An unauthenticated request that has passed the rate limit for its class.
/// Used by the password and refresh endpoints, which are reachable by anyone.
pub(crate) struct RateLimited<const C: u8>;

/// Class codes for [`RateLimited`] and [`AuthedLimited`], since const generics
/// cannot take an enum.
pub(crate) const PASSWORD: u8 = 0;
pub(crate) const REFRESH: u8 = 1;
pub(crate) const INVITE_CHECK: u8 = 2;
pub(crate) const WRITE: u8 = 3;
pub(crate) const READ: u8 = 4;
pub(crate) const UPLOAD: u8 = 5;
pub(crate) const CANVAS: u8 = 6;
pub(crate) const ASSET: u8 = 7;
pub(crate) const GIF: u8 = 8;
/// A cheap authenticated read, never [`RateLimited`]: every
/// `AuthedLimited<AUTHED_READ>` site is reached only after `Authed` already
/// resolved a session, so this code has no unauthenticated caller to serve
/// the way [`READ`] still does for `/version`. See [`Class::AuthedRead`] for
/// the budget and the workload it is sized against.
pub(crate) const AUTHED_READ: u8 = 9;

/// Unfurling a pasted link; see [`Class::LinkPreview`].
pub(crate) const LINK_PREVIEW: u8 = 10;

/// Running a module command, direct or shared; see [`Class::Module`].
pub(crate) const MODULE: u8 = 11;

/// Presenting a second factor; see [`Class::Totp`].
pub(crate) const TOTP: u8 = 12;

/// The connection test's latency ping; see [`Class::DiagnosticPing`].
pub(crate) const DIAGNOSTIC_PING: u8 = 13;

/// The connection test's speed transfers; see [`Class::DiagnosticTransfer`].
pub(crate) const DIAGNOSTIC_TRANSFER: u8 = 14;

/// Panics on an unknown code rather than falling back.
///
/// It used to end `_ => Class::Refresh`, which meant a new code compiled clean
/// and silently charged a budget twenty times looser on refill than Password's -
/// on endpoints that are unauthenticated and expensive. There is no safe default
/// here, so there is no default: every code is named, and the panic is
/// unreachable for any code this module defines.
fn class_of(code: u8) -> Class {
    match code {
        MODULE => Class::Module,
        TOTP => Class::Totp,
        PASSWORD => Class::Password,
        REFRESH => Class::Refresh,
        INVITE_CHECK => Class::InviteCheck,
        WRITE => Class::Write,
        READ => Class::Read,
        UPLOAD => Class::Upload,
        CANVAS => Class::Canvas,
        ASSET => Class::Asset,
        GIF => Class::Gif,
        LINK_PREVIEW => Class::LinkPreview,
        AUTHED_READ => Class::AuthedRead,
        DIAGNOSTIC_PING => Class::DiagnosticPing,
        DIAGNOSTIC_TRANSFER => Class::DiagnosticTransfer,
        other => unreachable!("no rate-limit class for code {other}"),
    }
}

impl<const C: u8> FromRequestParts<AppState> for RateLimited<C> {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        enforce(state, parts, None, class_of(C))?;
        Ok(RateLimited)
    }
}

/// An authenticated request that has also paid its rate limit.
///
/// One extractor rather than the three-part idiom it replaces (`Authed(ctx)`
/// plus `parts: Parts` plus a remembered `enforce(...)` call), because the
/// charge being a line somebody has to remember is exactly how it went missing:
/// eight routes charged nothing, and this project had already found and fixed
/// the same omission once before on message edit.
///
/// Declaring the class in the signature makes "no limit" a visible, reviewable
/// choice instead of an absence. It also drops the `parts: Parts` argument,
/// which axum satisfies by cloning every header on the request.
pub(crate) struct AuthedLimited<const C: u8>(pub(crate) SessionContext);

impl<const C: u8> FromRequestParts<AppState> for AuthedLimited<C> {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        // Authenticate first: the charge belongs on the account, not an address.
        let Authed(ctx) = Authed::from_request_parts(parts, state).await?;
        enforce(state, parts, Some(&ctx), class_of(C))?;
        Ok(AuthedLimited(ctx))
    }
}

/// A JSON request body, and a JSON response: a drop-in for [`axum::Json`]
/// usable in both positions, so swapping the import is the whole migration.
pub(crate) struct Json<T>(pub(crate) T);

impl<T: DeserializeOwned> FromRequest<AppState> for Json<T> {
    type Rejection = ApiError;

    async fn from_request(req: Request, state: &AppState) -> Result<Self, Self::Rejection> {
        let axum::Json(value) = axum::Json::<T>::from_request(req, state).await?;
        Ok(Json(value))
    }
}

impl<T: Serialize> IntoResponse for Json<T> {
    fn into_response(self) -> Response {
        axum::Json(self.0).into_response()
    }
}

/// A query-string extractor: a drop-in for [`axum::extract::Query`].
pub(crate) struct Query<T>(pub(crate) T);

impl<T: DeserializeOwned> FromRequestParts<AppState> for Query<T> {
    type Rejection = ApiError;

    async fn from_request_parts(
        parts: &mut Parts,
        state: &AppState,
    ) -> Result<Self, Self::Rejection> {
        let axum::extract::Query(value) =
            axum::extract::Query::<T>::from_request_parts(parts, state).await?;
        Ok(Query(value))
    }
}

/// The raw request body: a drop-in for [`axum::body::Bytes`], used by the
/// three routes that accept a binary upload rather than JSON.
pub(crate) struct Bytes(pub(crate) axum::body::Bytes);

impl FromRequest<AppState> for Bytes {
    type Rejection = ApiError;

    async fn from_request(req: Request, state: &AppState) -> Result<Self, Self::Rejection> {
        let bytes = axum::body::Bytes::from_request(req, state).await?;
        Ok(Bytes(bytes))
    }
}

/// Refuses a caller without the deployment-wide `MANAGE_SERVER` bit: the one
/// gate the Dock, analytics, retention, storage, emoji and metrics routes
/// share (decision 0021 names them as one settings surface). Called from each
/// handler rather than layered as middleware, so `tests/openapi_429_coverage.rs`'s
/// static per-handler scan still sees the rate-limit charge beside it.
pub(crate) async fn require_manage_server(
    state: &AppState,
    user_id: UserId,
) -> Result<(), ApiError> {
    require_base_permission(state, user_id, Permissions::MANAGE_SERVER).await?;
    Ok(())
}

/// Refuses a caller without `MANAGE_ROLES`, handing back the caller's own base
/// permissions so a role edit can also check it grants no bit the caller lacks.
pub(crate) async fn require_manage_roles(
    state: &AppState,
    user_id: UserId,
) -> Result<Permissions, ApiError> {
    require_base_permission(state, user_id, Permissions::MANAGE_ROLES).await
}

/// Refuses a bot principal outright. Used by `http::bots` so a bot cannot
/// provision another bot; see `docs/decisions/0028-bot-accounts.md`.
pub(crate) async fn require_human(state: &AppState, user_id: UserId) -> Result<(), ApiError> {
    if state.store.is_bot(user_id).await? {
        return Err(ApiError::Forbidden);
    }
    Ok(())
}

/// Refuses with a reason of its own, so a client can tell it from a missing permission.
pub(crate) const SECOND_FACTOR_REQUIRED: &str =
    "turn on two-factor sign-in in your account settings before using administrator powers";

/// Refuses a caller without `bit` deployment-wide, and refuses an administrator
/// the deployment's `required_for_elevated` policy says is owed a second factor.
/// Sign-in and enrolment never come through here, so that refusal cannot strand anyone.
pub(crate) async fn require_base_permission(
    state: &AppState,
    user_id: UserId,
    bit: Permissions,
) -> Result<Permissions, ApiError> {
    let permissions = state.store.base_permissions(user_id).await?;
    if !permissions.contains(bit) {
        return Err(ApiError::Forbidden);
    }
    if permissions.contains(Permissions::ADMINISTRATOR)
        && state.store.elevated_factor_missing(user_id).await?
    {
        return Err(ApiError::ForbiddenBecause(SECOND_FACTOR_REQUIRED));
    }
    Ok(permissions)
}

#[cfg(test)]
mod tests {
    use super::{
        ASSET, AUTHED_READ, CANVAS, GIF, INVITE_CHECK, LINK_PREVIEW, PASSWORD, READ, REFRESH,
        UPLOAD, WRITE, anonymous_key, class_of, forwarded_for,
    };
    use crate::ratelimit::Class;
    use axum::http::Request;
    use axum::http::request::Parts;

    /// Each code maps to its own class, and none share one - a swap here would
    /// silently charge a route the wrong budget, which is exactly the bug the
    /// old `_ => Refresh` fallback caused before this match went exhaustive.
    #[test]
    fn every_rate_limit_code_maps_to_its_own_class() {
        let pairs = [
            (PASSWORD, Class::Password),
            (REFRESH, Class::Refresh),
            (INVITE_CHECK, Class::InviteCheck),
            (WRITE, Class::Write),
            (READ, Class::Read),
            (UPLOAD, Class::Upload),
            (CANVAS, Class::Canvas),
            (ASSET, Class::Asset),
            (GIF, Class::Gif),
            (LINK_PREVIEW, Class::LinkPreview),
            (AUTHED_READ, Class::AuthedRead),
            (super::DIAGNOSTIC_PING, Class::DiagnosticPing),
            (super::DIAGNOSTIC_TRANSFER, Class::DiagnosticTransfer),
        ];
        let mut seen = std::collections::HashSet::new();
        for (code, class) in pairs {
            assert_eq!(class_of(code), class, "code {code} maps to the wrong class");
            assert!(seen.insert(class), "two codes share {class:?}");
        }
    }

    /// An unrecognised code panics rather than defaulting: a new code must be
    /// named here, not silently charged some other class's budget.
    #[test]
    fn an_unknown_code_panics_rather_than_defaulting() {
        let prior = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let result = std::panic::catch_unwind(|| class_of(200));
        std::panic::set_hook(prior);
        assert!(
            result.is_err(),
            "an undefined code must not resolve to a class"
        );
    }

    fn parts(xff: Option<&str>) -> Parts {
        let mut builder = Request::builder();
        if let Some(value) = xff {
            builder = builder.header("x-forwarded-for", value);
        }
        builder.body(()).unwrap().into_parts().0
    }

    #[test]
    fn a_missing_header_selects_nothing() {
        assert_eq!(forwarded_for(&parts(None), 1), None);
    }

    /// The client is counted `hops` from the right, so entries a caller
    /// prepends can never reach the selected slot - the whole reason the count
    /// is from the right and not the left.
    #[test]
    fn a_prepended_entry_cannot_change_the_selected_address() {
        assert_eq!(
            forwarded_for(&parts(Some("2.2.2.2")), 1).as_deref(),
            Some("2.2.2.2")
        );
        assert_eq!(
            forwarded_for(&parts(Some("spoofed, 2.2.2.2")), 1).as_deref(),
            Some("2.2.2.2")
        );
    }

    #[test]
    fn the_hop_count_is_taken_from_the_right() {
        // Two trusted hops over "a, b, c" is two from the right: "b".
        assert_eq!(
            forwarded_for(&parts(Some("a, b, c")), 2).as_deref(),
            Some("b")
        );
    }

    /// A header with fewer entries than trusted hops selects nothing rather
    /// than wrapping to the leftmost, so a short forged header falls back to
    /// the socket peer instead of being believed.
    #[test]
    fn fewer_entries_than_hops_selects_nothing() {
        assert_eq!(forwarded_for(&parts(Some("only")), 2), None);
        assert_eq!(forwarded_for(&parts(Some("only")), 0), None);
    }

    /// A trailing comma is dropped, not counted: without that, one trusted hop
    /// over `"2.2.2.2, "` would select the empty entry and key everyone who
    /// sends a trailing comma into one bucket.
    #[test]
    fn empty_and_whitespace_entries_are_dropped_before_counting() {
        assert_eq!(
            forwarded_for(&parts(Some("2.2.2.2, ")), 1).as_deref(),
            Some("2.2.2.2")
        );
        assert_eq!(
            forwarded_for(&parts(Some("a,, b")), 1).as_deref(),
            Some("b")
        );
    }

    #[test]
    fn an_ipv6_caller_is_keyed_by_its_slash_64_and_ipv4_by_its_address() {
        let key = |s: &str| anonymous_key(s.parse().unwrap());
        assert_eq!(key("2001:db8:1:2:aaaa::1"), "ip:2001:db8:1:2::/64");
        assert_eq!(
            key("2001:db8:1:2:ffff:ffff:ffff:ffff"),
            "ip:2001:db8:1:2::/64"
        );
        assert_ne!(key("2001:db8:1:3::1"), key("2001:db8:1:2::1"));
        assert_eq!(key("192.0.2.7"), "ip:192.0.2.7");
        assert_eq!(key("::ffff:192.0.2.7"), "ip:192.0.2.7");
    }
}
