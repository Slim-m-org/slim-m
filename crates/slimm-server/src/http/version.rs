// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /version`: what a server says about itself before anyone signs in.

use axum::{Router, extract::State, routing::get};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde::Serialize;

use super::error::ApiError;
use super::extract::{Json, READ, RateLimited};
use super::{AppState, PROTOCOL_VERSION, build_id, capability, router};
use crate::store::JoinPolicy;

pub fn routes() -> Router<AppState> {
    Router::new().route("/version", get(version))
}

#[derive(Serialize)]
struct Version {
    name: &'static str,
    version: &'static str,
    /// Short git SHA of the build, so two deploys of one version differ.
    /// Absent when the build was not given one, never a placeholder.
    #[serde(skip_serializing_if = "Option::is_none")]
    build_id: Option<String>,
    protocol: u32,
    push_enabled: bool,
    /// Whether creating an account here needs an invite code. Onboarding
    /// needs this before an account exists, so it rides on /version.
    invite_required: bool,
    /// Whether the first account has registered. Lets a client open an empty
    /// deployment on owner-claim wording; `invite_required` alone cannot, as
    /// it reads true before anyone has joined.
    claimed: bool,
    /// Whether this deployment can search and attach GIFs at all (both
    /// `SLIMM_GIF_PROVIDER` and `SLIMM_GIF_API_KEY` are set). The same
    /// two-state shape as `push_enabled`: absent is meaningless here since
    /// this field always exists, so a client reads `false` as "no GIF picker
    /// on this deployment" rather than needing a third "unknown" state.
    gif_search_enabled: bool,
    /// When the space icon was set; here because `/space/settings` is admin-only.
    #[serde(skip_serializing_if = "Option::is_none")]
    icon_updated_at: Option<i64>,
    /// Whether this deployment unfurls pasted links into preview cards
    /// (`SLIMM_LINK_PREVIEWS` is set). Same two-state shape as
    /// `gif_search_enabled`: a client reads `false` as "do not ask this
    /// deployment for link previews".
    link_previews_enabled: bool,
    /// The tallest resolution a screen share may publish at. Enforcement is
    /// entirely client-side (see `client/packages/rtc/lib/src/screen_share_control.dart`),
    /// so every client - not only one with MANAGE_SERVER, which is all
    /// `GET /space/screen-share` allows - needs this before it can cap its
    /// own capture, the same reason `invite_required` rides on `/version`
    /// rather than staying behind `/space/settings`.
    screen_share_max_height: i64,
    /// The largest single attachment upload the server accepts, in bytes, so a
    /// client can refuse an oversize pick before sending any of it.
    max_attachment_bytes: u64,
    /// The oldest client this deployment will keep serving, or `None` for no
    /// floor at all, which is the default and the ordinary case.
    ///
    /// The wire is additive, so an old client keeps working across a server
    /// upgrade; this is the one lever an operator has for the case where it
    /// genuinely cannot - a client with a data-loss bug, or one that reads a
    /// shape this server no longer sends. A client below it stops and offers
    /// to update rather than running against a server it cannot speak to.
    /// Being a floor rather than a nudge, it is deliberately awkward to set:
    /// see decision 0025.
    #[serde(skip_serializing_if = "Option::is_none")]
    min_client_version: Option<String>,
    /// The optional features this build serves, read off the router itself.
    /// See [`capability`] for why it is not a list kept by hand.
    capabilities: Vec<&'static str>,
    identity: ServerIdentityDto,
}

/// The capability list for this build, computed on first ask and kept.
///
/// Which routes are mounted is a property of the binary, not of the request
/// or the deployment's configuration, so asking once is the whole answer; the
/// alternative is rebuilding the router on every unauthenticated `/version`.
static CAPABILITIES: std::sync::OnceLock<Vec<&'static str>> = std::sync::OnceLock::new();

async fn capabilities(state: AppState) -> Vec<&'static str> {
    if let Some(cached) = CAPABILITIES.get() {
        return cached.clone();
    }
    let names = capability_names(router(state)).await;
    CAPABILITIES.get_or_init(|| names).clone()
}

/// The `/version` capability list a router serves, as wire names.
///
/// Extracted as its own seam so a test can feed it a router that serves a
/// different set. `capabilities` above is then a trivial one-liner over the
/// real router, but the derivation, empty case included, is provable here
/// against a bare router where a hardcoded `["block", "report"]` would give
/// itself away.
pub async fn capability_names(router: Router) -> Vec<&'static str> {
    capability::served_by(router)
        .await
        .into_iter()
        .map(capability::Capability::wire_name)
        .collect()
}

/// The wire shape of [`crate::identity::ServerIdentity`]. Kept as a distinct
/// DTO (rather than deriving `Serialize` on the domain type itself) so the
/// domain module never has to think about base64 or hex, only bytes.
#[derive(Serialize)]
struct ServerIdentityDto {
    /// Standard base64 of the 32-byte Ed25519 public key. This, not
    /// `fingerprint`, is what a client should actually pin and compare
    /// byte-for-byte on every later connect.
    public_key: String,
    /// 32 lowercase hex characters (a truncated SHA-256 of the public key),
    /// with no separators, for a client to store or compare programmatically.
    fingerprint: String,
    /// The same fingerprint, split into eight 4-character hex groups, ready
    /// for the onboarding design's two-rows-of-four display.
    fingerprint_groups: Vec<String>,
    /// Four indices into the client's six-entry cursor colour palette
    /// (`AppCanvasColors.cursors`), deterministically derived from the
    /// fingerprint, for an at-a-glance colour strip alongside the hex.
    color_strip: [u8; 4],
}

/// Build version, the wire-protocol envelope version a client negotiates,
/// whether this deployment can deliver push at all, what optional features it
/// serves, and the server's trust-on-first-use identity.
///
/// All of it is here rather than behind auth because onboarding needs it
/// before an account exists: someone choosing a LAN-only server should learn
/// their phone will not get notifications while they can still choose
/// differently, someone joining a server with no report or block route should
/// learn there is no recourse here before they commit, and the "connect by
/// address" flow shows the fingerprint before anyone has signed in. All of it
/// reveals deployment configuration only, never user data.
async fn version(
    _limited: RateLimited<READ>,
    State(state): State<AppState>,
) -> Result<Json<Version>, ApiError> {
    let identity = state.store.server_identity().await?;
    Ok(Json(Version {
        name: "slim-m",
        version: env!("CARGO_PKG_VERSION"),
        build_id: build_id::current(),
        protocol: PROTOCOL_VERSION,
        push_enabled: state.push.is_enabled(),
        invite_required: state.store.join_policy().await? == JoinPolicy::Invite,
        claimed: state.store.is_bootstrapped().await?,
        gif_search_enabled: state.gifs.is_enabled(),
        icon_updated_at: state.store.space_landing().await?.icon_updated_at,
        link_previews_enabled: state.link_previews.is_enabled(),
        screen_share_max_height: state.store.screen_share_max_height().await?,
        max_attachment_bytes: state.media.max_attachment_bytes(),
        min_client_version: min_client_version(),
        capabilities: capabilities(state).await,
        identity: ServerIdentityDto {
            public_key: BASE64.encode(identity.public_key()),
            fingerprint: identity.fingerprint_hex(),
            fingerprint_groups: identity.fingerprint_groups(),
            color_strip: identity.color_strip(),
        },
    }))
}

/// `SLIMM_MIN_CLIENT_VERSION`, empty read as unset.
///
/// Read here rather than carried on [`AppState`] from [`crate::config::Config`],
/// unlike every other deployment setting: `AppState` is built literally at 157
/// sites across the integration tests, and threading one immutable string
/// through all of them buys nothing this read does not already give. It is
/// also the one setting whose right value is a property of the build being
/// deployed rather than of the deployment, so it belongs beside the version
/// it qualifies.
fn min_client_version() -> Option<String> {
    std::env::var("SLIMM_MIN_CLIENT_VERSION")
        .ok()
        .filter(|value| !value.trim().is_empty())
}
