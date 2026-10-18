// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! HTTP surface: liveness, version, the auth routes, and the message routes. The
//! WebSocket routes are added as the protocol is built.

use std::time::Duration;

use axum::extract::MatchedPath;
use axum::http::StatusCode;
use axum::{Extension, Router, extract::State, routing::get};
use tower::limit::ConcurrencyLimitLayer;
use tower_http::timeout::{RequestBodyTimeoutLayer, TimeoutLayer};
use tower_http::trace::TraceLayer;

use crate::auth::Auth;
use crate::code_runner::CodeRunner;
use crate::hub::Hub;
use crate::media::Media;
use crate::push::PushSender;
use crate::ratelimit::RateLimiter;
use crate::store::Store;
use crate::voice::VoiceService;

pub mod admin_audit;
mod analytics;
mod apps;
mod attachment_ids;
mod attachment_limit;
mod attachment_preview;
mod attachment_range;
mod attachment_uploads;
mod attachments;
mod auth;
mod bot_commands;
mod bot_ui;
mod bots;
pub mod build_id;
mod canvas;
use canvas::{canvas_media_slots, canvas_object_locks};
pub mod capability;
mod categories;
mod category_overwrites;
mod channels;
use channels::{
    channel_notification_prefs, channel_order, channel_permissions, channel_retention,
    channel_slow_mode, channel_validation,
};
pub(crate) mod code_fences;
mod code_runs;
mod device_client_info;
mod dms;
pub mod dock;
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
pub use version::capability_names;
mod interactions;
mod invite_page;
mod invites;
mod join_gate;
pub mod link_preview;
pub mod linked_accounts;
mod linked_avatar;
mod member_permissions;
mod members;
use members::{member_nicknames, members_bulk, members_list};
mod messages;
use messages::{
    message_components, message_dto, message_enrich, message_mentions, message_validation,
    messages_bulk, messages_bulk_window,
};
mod diagnostics;
mod direct_route;
mod metrics;
mod module_caller;
mod module_commands;
mod module_host;
mod module_net;
mod module_run;
mod module_schedule;
pub use module_schedule::run_due as run_scheduled_modules;
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
mod roles;
use roles::role_reorder;
mod route_timing;
mod safety;
mod saved_messages;
mod scene_limits;
mod search;
mod sign_in_alert;
mod space;
mod space_banner;
mod space_icon;
mod space_link_previews;
mod still_picture;
mod storage;
mod surface_state;
mod sync;
mod sync_ops;
mod threads;
mod totp;
mod user_avatars;
mod user_notes;
mod user_status;
mod users;
mod version;
mod viewable_message;
mod voice;
use voice::{voice_calls, voice_ring, voice_rooms, voice_webhook};
mod watch_session;
mod webhooks;
mod webhooks_admin;
mod welcome;
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
        .merge(diagnostics::transfer_routes())
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
        .route("/version", get(version::version))
        .merge(admin_audit::routes())
        .merge(analytics::routes())
        .merge(attachment_limit::routes())
        .merge(module_schedule::routes())
        .merge(channel_retention::routes())
        .merge(apps::routes())
        .merge(auth::routes())
        .merge(canvas::routes())
        .merge(canvas_media_slots::routes())
        .merge(canvas_object_locks::routes())
        .merge(categories::routes())
        .merge(category_overwrites::routes())
        .merge(channel_notification_prefs::routes())
        .merge(channels::routes())
        .merge(channel_order::routes())
        .merge(channel_permissions::routes())
        .merge(diagnostics::ping_routes())
        .merge(direct_route::routes())
        .merge(dock::routes())
        .merge(emoji::routes())
        .merge(invites::routes())
        .merge(invite_page::routes())
        .merge(space_link_previews::routes())
        .merge(members::routes())
        .merge(member_permissions::routes())
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
        .merge(join_gate::routes())
        .merge(space_banner::routes())
        .merge(space_icon::routes())
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
        .merge(voice_calls::routes())
        .merge(voice_ring::routes())
        .merge(voice_rooms::routes())
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
        .merge(linked_accounts::routes())
        .merge(attachments::routes())
        // Matched routes only, like the timing layer below; see `admin_audit`.
        .route_layer(axum::middleware::from_fn_with_state(
            state.clone(),
            admin_audit::record,
        ))
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

/// Minimal error so a failed liveness check returns 503 rather than panicking.
struct StatusError;

impl axum::response::IntoResponse for StatusError {
    fn into_response(self) -> axum::response::Response {
        (axum::http::StatusCode::SERVICE_UNAVAILABLE, "unavailable").into_response()
    }
}
