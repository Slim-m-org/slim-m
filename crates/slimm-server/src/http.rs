// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! HTTP surface: liveness, version, the auth routes, and the message routes. The
//! WebSocket routes are added as the protocol is built.

use std::time::Duration;

use axum::extract::MatchedPath;
use axum::http::StatusCode;
use axum::{Extension, Router, extract::State, routing::get};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde::Serialize;
use tower::limit::ConcurrencyLimitLayer;
use tower_http::timeout::{RequestBodyTimeoutLayer, TimeoutLayer};
use tower_http::trace::TraceLayer;

use crate::auth::Auth;
use crate::code_runner::CodeRunner;
use crate::hub::Hub;
use crate::media::Media;
use crate::push::PushSender;
use crate::ratelimit::RateLimiter;
use crate::store::{JoinPolicy, Store};
use crate::voice::VoiceService;
use error::ApiError;
use extract::{Json, READ, RateLimited};

mod analytics;
mod apps;
mod attachment_ids;
mod attachment_range;
mod attachments;
mod auth;
mod bot_commands;
mod bot_ui;
mod bots;
pub mod build_id;
mod canvas;
mod canvas_media_slots;
mod canvas_object_locks;
mod canvas_ops;
mod canvas_ops_write;
mod canvas_write;
pub mod capability;
mod categories;
mod channel_notification_prefs;
mod channel_order;
mod channel_permissions;
mod channel_slow_mode;
mod channel_validation;
mod channels;
pub(crate) mod code_fences;
mod code_runs;
mod device_client_info;
mod dms;
pub mod dock;
mod dock_lifecycle;
mod dock_sources;
pub(crate) mod embeds;
mod emoji;
mod ephemeral_anchor;
mod ephemeral_messages;
mod ephemeral_report;
mod error;
mod escalation;
mod extract;
pub mod gifs;
pub(crate) use crate::hidden_chars;
mod interactions;
mod invites;
pub mod link_preview;
mod member_nicknames;
mod members;
mod members_bulk;
mod members_list;
mod message_components;
mod message_dto;
mod message_enrich;
mod message_forwards;
mod message_get;
mod message_history;
mod message_mentions;
mod message_validation;
mod messages;
mod messages_bulk;
mod messages_bulk_window;
mod metrics;
mod module_caller;
mod module_commands;
mod module_host;
mod module_permissions;
mod notification_schedule;
mod overwrites;
pub mod panic_guard;
mod pins;
mod polls;
mod post_commit;
mod presence;
mod push;
mod quiet_hours;
mod reaction_emoji;
mod reactions;
mod read_states;
mod read_sync;
mod reauth;
mod recovery;
mod reports;
mod reports_cursor;
mod reports_guards;
mod reports_mine;
mod role_reorder;
mod roles;
mod route_timing;
mod safety;
mod saved_messages;
mod scene_limits;
mod search;
mod sign_in_alert;
mod space;
mod storage;
mod sync;
mod sync_ops;
mod threads;
mod totp;
mod user_avatars;
mod user_notes;
mod user_status;
mod users;
mod viewable_message;
mod voice;
mod voice_ring;
mod voice_webhook;
mod watch_session;
mod webhooks;
mod webhooks_admin;
mod ws;

/// The wire-protocol envelope version a client negotiates on connect. Bumped
/// only for a breaking change to the envelope; additive changes keep it.
pub(crate) const PROTOCOL_VERSION: u32 = 1;

/// How long one HTTP request may take before it is abandoned.
///
/// The socket surface has had a bound like this from the start, with a comment
/// saying why: a peer that stops reading could otherwise wedge its task
/// indefinitely. The HTTP surface had none, against a process whose measured
/// idle RSS is 7 MB and whose committed budget is under 30 MB. Generous enough
/// for the heaviest real request (a bundled `/sync`) and far short of forever.
/// An attachment upload gets [`Media::upload_timeout`] instead: a gigabyte over
/// a home uplink needs minutes.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

/// How long a request body may trickle in before it is abandoned.
///
/// Separate from [`REQUEST_TIMEOUT`] because this is the cheaper attack: a
/// request that declares a body and then sends a byte a minute holds a task and
/// its partial buffer for as long as it likes. Caddy's own read-body timeout
/// defaults to unlimited, so the shipped proxy does not cover this either.
const BODY_READ_TIMEOUT: Duration = Duration::from_secs(15);

/// How many HTTP requests may be in flight at once.
///
/// The equivalent of `hub::MAX_CONNECTIONS` for the other surface, and set to
/// the same order of magnitude for the same reason: past some number, admitting
/// more work makes every request slower rather than serving anybody. Requests
/// over it queue rather than fail, so a burst is absorbed and a flood is
/// bounded.
const MAX_INFLIGHT_REQUESTS: usize = 1024;

/// What every handler shares: the persistence layer, the auth service, and the
/// fan-out hub. Cloning is cheap (a pool handle and a couple of `Arc`s).
#[derive(Clone)]
pub struct AppState {
    pub store: Store,
    pub auth: Auth,
    pub hub: Hub,
    pub limiter: RateLimiter,
    pub push: PushSender,
    pub voice: VoiceService,
    pub media: Media,
    pub gifs: gifs::GifSearch,
    pub link_previews: link_preview::LinkPreviews,
    pub dock: dock::Dock,
    pub code_runner: CodeRunner,
}

/// Wraps `router` so a panicking handler answers 500 and the process keeps
/// serving; see [`panic_guard`]. Public so a test can wrap a route that panics.
pub fn guard_panics<S: Clone + Send + Sync + 'static>(router: Router<S>) -> Router<S> {
    router
        .layer(axum::middleware::from_fn(panic_guard::mark_request))
        .layer(panic_guard::catch_layer())
}

/// Builds the router over the shared application state.
///
/// The trailing `TraceLayer` is given a `make_span_with` that labels its span
/// by the matched route *template* (`MatchedPath`), never the raw request
/// URI `TraceLayer::new_for_http()` records by default. Several routes carry
/// a caller-controlled credential in the path itself - most pressingly
/// `/webhooks/{webhook_id}/{token}`, whose token is a bearer credential in
/// plaintext - and the default span would write it into every debug-level
/// log line. `route_timing::record` already reads `MatchedPath` the same way
/// for the same reason (unbounded cardinality from a caller-supplied id or
/// search term), and the template is strictly more useful in a log besides:
/// "which route" beats "which exact URL" for grepping. See
/// `docs/decisions/0030-incoming-webhooks.md`'s "Leak" section.
pub fn router(state: AppState) -> Router {
    // Fresh per call, like `state.limiter`; see `route_timing`'s own doc.
    let route_timings = route_timing::RouteTimings::new();
    let uploads = attachments::upload_routes()
        .route_layer(axum::middleware::from_fn(route_timing::record))
        .layer(Extension(route_timings.clone()))
        .layer(ConcurrencyLimitLayer::new(MAX_INFLIGHT_REQUESTS))
        .layer(TimeoutLayer::with_status_code(
            StatusCode::GATEWAY_TIMEOUT,
            state.media.upload_timeout(),
        ))
        .layer(RequestBodyTimeoutLayer::new(BODY_READ_TIMEOUT));
    let app = Router::new()
        .route("/healthz", get(healthz))
        .route("/version", get(version))
        .merge(analytics::routes())
        .merge(apps::routes())
        .merge(auth::routes())
        .merge(canvas::routes())
        .merge(canvas_media_slots::routes())
        .merge(canvas_object_locks::routes())
        .merge(categories::routes())
        .merge(channel_notification_prefs::routes())
        .merge(channels::routes())
        .merge(channel_order::routes())
        .merge(channel_permissions::routes())
        .merge(dock::routes())
        .merge(emoji::routes())
        .merge(invites::routes())
        .merge(members::routes())
        .merge(member_nicknames::routes())
        .merge(members_bulk::routes())
        .merge(messages::routes())
        .merge(messages_bulk::router())
        .merge(messages_bulk_window::router())
        .merge(metrics::routes())
        .merge(code_runs::routes())
        .merge(module_commands::routes())
        .merge(module_permissions::routes())
        .merge(overwrites::routes())
        .merge(presence::routes())
        .merge(reactions::routes())
        .merge(push::routes())
        .merge(quiet_hours::routes())
        .merge(notification_schedule::routes())
        .merge(pins::routes())
        .merge(saved_messages::routes())
        .merge(recovery::routes())
        .merge(reports::routes())
        .merge(roles::routes())
        .merge(role_reorder::routes())
        .merge(safety::routes())
        .merge(dms::routes())
        .merge(search::routes())
        .merge(space::routes())
        .merge(totp::routes())
        .merge(storage::routes())
        .merge(sync::routes())
        .merge(read_states::routes())
        .merge(threads::routes())
        .merge(bots::routes())
        .merge(bot_commands::routes())
        .merge(bot_ui::routes())
        .merge(ephemeral_messages::routes())
        .merge(interactions::routes())
        .merge(message_components::routes())
        .merge(voice::routes())
        .merge(voice_ring::routes())
        .merge(voice_webhook::routes())
        .merge(watch_session::routes())
        .merge(webhooks::routes())
        .merge(webhooks_admin::routes())
        .merge(polls::routes())
        .merge(users::routes())
        .merge(members_list::routes())
        .merge(user_notes::routes())
        .merge(gifs::routes())
        .merge(link_preview::routes())
        .merge(attachments::routes())
        // Only applies to a route above, once matched; see `route_timing`.
        .route_layer(axum::middleware::from_fn(route_timing::record))
        // Outer to the line above, so its `Extension` is on the request already.
        .layer(Extension(route_timings))
        // Bounded, and the socket is deliberately outside this: see below.
        .layer(ConcurrencyLimitLayer::new(MAX_INFLIGHT_REQUESTS))
        .layer(TimeoutLayer::with_status_code(
            StatusCode::GATEWAY_TIMEOUT,
            REQUEST_TIMEOUT,
        ))
        .layer(RequestBodyTimeoutLayer::new(BODY_READ_TIMEOUT))
        .merge(uploads)
        .merge(ws::routes());
    guard_panics(app)
        // Route-template span labeling; see this function's own doc comment.
        .layer(
            TraceLayer::new_for_http().make_span_with(|request: &axum::extract::Request| {
                let route = request
                    .extensions()
                    .get::<MatchedPath>()
                    .map(MatchedPath::as_str)
                    .unwrap_or("unmatched");
                tracing::info_span!("http_request", method = %request.method(), route)
            }),
        )
        .with_state(state)
}

/// Liveness probe: 200 while the process is serving and the database answers.
///
/// Deliberately the one route that charges no rate limit. A probe is what an
/// orchestrator calls to decide whether this process is alive, and a 429 there
/// reads as unhealthy and gets the container restarted - so throttling it turns
/// a flood into an outage rather than preventing one. It costs one indexed
/// `SELECT 1`, and the request timeout and concurrency limit on the router bound
/// it the same way they bound everything else.
async fn healthz(State(state): State<AppState>) -> Result<&'static str, StatusError> {
    state.store.ping().await.map_err(|_| StatusError)?;
    Ok("ok")
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
        link_previews_enabled: state.link_previews.is_enabled(),
        screen_share_max_height: state.store.screen_share_max_height().await?,
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

/// Minimal error so a failed liveness check returns 503 rather than panicking.
struct StatusError;

impl axum::response::IntoResponse for StatusError {
    fn into_response(self) -> axum::response::Response {
        (axum::http::StatusCode::SERVICE_UNAVAILABLE, "unavailable").into_response()
    }
}
