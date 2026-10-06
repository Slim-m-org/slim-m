// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! LiveKit room access: minting the capability tokens a client joins with, and
//! evicting somebody who should no longer be in a room.
//!
//! [`VoiceService`] is a two-state thing rather than an error path, the same
//! shape as [`crate::push::PushSender`]. A text-only self-host is a supported
//! way to run this and should not have to stand up an SFU, so an unconfigured
//! deployment simply reports that voice is unavailable.
//!
//! Three things about the token matter more than the rest:
//!
//! - **The room name is derived here, never taken from the client.** It is a
//!   pure function of the channel id ([`room_for_channel`]), so asking for a
//!   token is asking for a specific channel and the permission check that
//!   follows is about that channel. A client-supplied room name would let
//!   somebody with voice rights in one channel mint a token for another.
//! - **The grants are derived from the permission bitfield**, not from a role
//!   name or a flag: `CONNECT` is what lets you in at all, `SPEAK` is what
//!   lets you publish, `USE_CANVAS` is what lets you send data. Someone with
//!   listen-only rights gets a token that cannot publish, so the SFU enforces
//!   it too rather than trusting the client to hide a button.
//! - **The TTL is short.** A LiveKit token is a bearer credential the server
//!   cannot revoke once handed out, so a kicked participant is removed through
//!   the room service ([`VoiceService::remove_participant`]) and their token
//!   expires quickly enough that re-joining means asking again, and being
//!   re-checked.
//!
//! A kick or a timeout is a deliberate eviction; a terminated app is not, and
//! nothing tells this service about it directly, since a killed process runs
//! no code and the SFU's own reconnect grace period is not this project's to
//! set. [`VoiceService::sweep_stale_calls_at`] is what closes that: a live
//! client refreshes its own entry on an interval, and a refresh that stops
//! arriving is what the sweep, run from `lib.rs`, treats as gone. See
//! `voice::heartbeat` for the bound this actually gives.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as BASE64URL;
use hmac::{Hmac, Mac};
use serde::Serialize;
use sha2::Sha256;

use crate::config::Config;
use crate::ids::{ChannelId, UserId};
use crate::permissions::Permissions;

mod call_record;
mod heartbeat;
mod live_state;
mod ring;
mod room_lifecycle;
mod roster;
mod token;
mod webhook;
pub(crate) use call_record::record_finished_call;
use heartbeat::{CallHeartbeats, STALE_AFTER as HEARTBEAT_STALE_AFTER};
pub use live_state::RoomLiveState;
pub use ring::{CallRingOutcome, CallRings, RING_TIMEOUT};
pub use roster::RoomParticipant;
use token::{Claims, VideoGrant, http_url_for, unix_secs};
pub use webhook::{WebhookError, WebhookEvent, channel_for_room, is_screen_share_source};

/// How long a join token is good for.
///
/// Short on purpose: this is a bearer credential, so the window in which a
/// participant removed from a room could walk back in with the same token is
/// exactly this long. Long enough to cover a slow join and a reconnect,
/// nowhere near long enough to be worth saving.
const TOKEN_TTL_SECS: u64 = 120;

/// The SFU accepts this token without asking us, so the TTL is the only thing
/// bounding how long a removed participant could rejoin with one they already
/// hold. Enforced at compile time so raising it is a deliberate act.
const _: () = assert!(TOKEN_TTL_SECS <= 300);

/// How long the server's own room-admin token is good for. Only ever used for
/// one immediate call, so it needs no room to spare.
const ADMIN_TOKEN_TTL_SECS: u64 = 30;

/// A minted room credential, and everything the client needs to use it.
#[derive(Debug, Clone, Serialize)]
pub struct RoomToken {
    /// The SFU to connect to.
    pub url: String,
    /// The room to join. Derived from the channel, echoed so the client does
    /// not have to know the derivation rule.
    pub room: String,
    pub token: String,
    /// Unix milliseconds, so a client can re-mint before it lapses rather
    /// than discovering the expiry by being disconnected.
    pub expires_at: i64,
    /// Whether this token allows publishing audio, so the UI can show a
    /// listen-only state up front instead of after the SFU refuses.
    pub can_publish: bool,
}

/// Why a token could not be minted.
#[derive(Debug)]
pub enum VoiceError {
    /// This deployment has no SFU configured, so it has no voice at all.
    Unavailable,
    Internal(anyhow::Error),
}

impl From<anyhow::Error> for VoiceError {
    fn from(err: anyhow::Error) -> Self {
        VoiceError::Internal(err)
    }
}

/// The room a channel's voice happens in.
///
/// A pure function of the channel id, so it is stable across restarts and
/// impossible for a client to influence.
pub fn room_for_channel(channel_id: ChannelId) -> String {
    format!("channel-{channel_id}")
}

/// Mints LiveKit room tokens and evicts participants.
#[derive(Clone)]
pub struct VoiceService {
    inner: Option<std::sync::Arc<Enabled>>,
    /// Ephemeral, independent of `inner`: it costs nothing to keep even when
    /// no SFU is configured, and a `VoiceService::new` that later reloads a
    /// config with voice freshly enabled starts this bookkeeping empty either way.
    heartbeats: CallHeartbeats,
    /// Ephemeral, the same independence from `inner` [`Self::heartbeats`] has;
    /// see `voice::ring`'s own module doc.
    rings: CallRings,
    /// Ephemeral like its siblings above; see `voice::live_state`'s own doc.
    live_state: RoomLiveState,
}

struct Enabled {
    url: String,
    api_key: String,
    api_secret: String,
    http: reqwest::Client,
    /// The room service base, derived from the client URL by swapping the
    /// WebSocket scheme for its HTTP equivalent. LiveKit serves both on the
    /// same host, and deriving it means one setting instead of two that can
    /// disagree.
    service_url: String,
}

impl VoiceService {
    /// Builds a service from config. Disabled unless the URL, key, and secret
    /// are all present, and logs which of the two it is once at startup.
    pub fn new(config: &Config) -> anyhow::Result<Self> {
        let inner = match config.livekit_settings() {
            Some((url, key, secret)) => {
                let service_url = http_url_for(&url)?;
                tracing::info!(%url, "voice enabled");
                Some(std::sync::Arc::new(Enabled {
                    url,
                    api_key: key,
                    api_secret: secret,
                    http: reqwest::Client::builder()
                        .timeout(std::time::Duration::from_secs(5))
                        .build()
                        .expect("building the livekit room service client"),
                    service_url,
                }))
            }
            None => {
                tracing::info!(
                    "SLIMM_LIVEKIT_URL / _API_KEY / _API_SECRET not all set; voice is disabled"
                );
                None
            }
        };
        Ok(Self {
            inner,
            heartbeats: CallHeartbeats::new(),
            rings: CallRings::new(),
            live_state: RoomLiveState::new(),
        })
    }

    /// A service with no SFU behind it, for tests and text-only deployments.
    pub fn disabled() -> Self {
        Self {
            inner: None,
            heartbeats: CallHeartbeats::new(),
            rings: CallRings::new(),
            live_state: RoomLiveState::new(),
        }
    }

    /// A service wired to an explicit key and secret, for tests that need to
    /// inspect a real signed token without standing up an SFU.
    pub fn for_test(url: &str, api_key: &str, api_secret: &str) -> Self {
        Self {
            inner: Some(std::sync::Arc::new(Enabled {
                url: url.to_owned(),
                api_key: api_key.to_owned(),
                api_secret: api_secret.to_owned(),
                http: reqwest::Client::new(),
                service_url: http_url_for(url).expect("test url"),
            })),
            heartbeats: CallHeartbeats::new(),
            rings: CallRings::new(),
            live_state: RoomLiveState::new(),
        }
    }

    pub fn is_enabled(&self) -> bool {
        self.inner.is_some()
    }

    /// Whether the configured SFU answers right now, for the `/metrics`
    /// reachability gauge - the check `compose-smoke` already runs by hand
    /// against the room service, made ongoing so an operator learns of a
    /// crashlooping LiveKit without a healthy-looking server hiding it.
    ///
    /// `None` when no SFU is configured, since there is nothing to ask.
    /// Otherwise a plain, unauthenticated HTTP round trip to the room
    /// service's own base address: any response at all, of any status,
    /// means the process behind it is up and answering, which is the
    /// question this asks - "is it there", not "was this request valid".
    /// Bounded by the same 5-second client timeout every other call to the
    /// room service already uses, so a hung SFU cannot stall a scrape
    /// indefinitely.
    pub async fn probe_reachable(&self) -> Option<bool> {
        let enabled = self.inner.as_ref()?;
        Some(enabled.http.get(&enabled.service_url).send().await.is_ok())
    }

    /// Mints a join token for `user_id` in `channel_id`.
    ///
    /// The caller is responsible for having checked that the user may connect;
    /// what this does is turn the permissions it is handed into the matching
    /// SFU grants, so the two cannot drift apart at the call site.
    pub fn mint(
        &self,
        channel_id: ChannelId,
        user_id: UserId,
        permissions: Permissions,
        display_name: &str,
    ) -> Result<RoomToken, VoiceError> {
        let Some(enabled) = self.inner.as_ref() else {
            return Err(VoiceError::Unavailable);
        };

        let room = room_for_channel(channel_id);
        let can_publish = permissions.contains(Permissions::SPEAK);
        let can_publish_data = permissions.contains(Permissions::USE_CANVAS);
        let now = unix_secs();
        let expires = now + TOKEN_TTL_SECS;

        let grants = VideoGrant {
            room: room.clone(),
            room_join: true,
            can_subscribe: true,
            can_publish,
            can_publish_data,
            // The display name is set below; no reason to let a client rewrite it mid-call.
            can_update_own_metadata: false,
            room_admin: false,
        };

        let token = self.sign(
            enabled,
            Claims {
                iss: &enabled.api_key,
                sub: &user_id.to_string(),
                name: Some(display_name),
                nbf: now,
                exp: expires,
                video: grants,
            },
        )?;

        Ok(RoomToken {
            url: enabled.url.clone(),
            room,
            token,
            expires_at: (expires as i64) * 1000,
            can_publish,
        })
    }

    /// Records that `user_id` is still on `channel_id`'s call as of now,
    /// reporting whether this was the first heartbeat recorded for this
    /// `(user, channel)` pair - a real join rather than a routine refresh.
    /// `http::voice`'s handler uses this rather than a separate
    /// [`Self::has_heartbeat`] check followed by a plain record: two
    /// concurrent first heartbeats for the same pair could otherwise both
    /// observe "not present yet" across the gap between those two calls and
    /// both publish [`crate::hub::Event::VoiceActivityChanged`]. See
    /// [`CallHeartbeats`] for what refreshing this staves off.
    pub fn record_heartbeat_reporting_new(&self, user_id: UserId, channel_id: ChannelId) -> bool {
        self.heartbeats.record_reporting_new(user_id, channel_id)
    }

    /// Drops `user_id`'s heartbeat entry for `channel_id` outright,
    /// reporting whether there really was something to forget - the same
    /// single lock-held check-and-remove [`Self::record_heartbeat_reporting_new`]
    /// uses for a join, so two concurrent clean hangups for the same pair
    /// cannot both observe "still present" and both publish.
    ///
    /// Called when a client reports leaving a call cleanly: it has already
    /// disconnected from the SFU on its own, so there is nothing left for the
    /// sweep to usefully evict, only a wasted [`Self::remove_participant`]
    /// call and a misleading "removed a voice participant with no recent
    /// heartbeat" log line waiting to happen forty seconds later.
    pub fn forget_heartbeat_reporting_removed(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
    ) -> bool {
        self.heartbeats
            .forget_reporting_removed(user_id, channel_id)
    }

    /// Whether a heartbeat is on record for this `(user, channel)`. A test's
    /// tool for confirming a handler actually reached
    /// [`Self::record_heartbeat_reporting_new`] after the fact; a live
    /// caller deciding whether to publish a signal wants
    /// [`Self::record_heartbeat_reporting_new`] or
    /// [`Self::forget_heartbeat_reporting_removed`] instead, which answer
    /// the same question without the race a separate read-then-write opens.
    pub fn has_heartbeat(&self, user_id: UserId, channel_id: ChannelId) -> bool {
        self.heartbeats.contains(user_id, channel_id)
    }

    /// [`Self::record_heartbeat`] with an explicit clock, so a test can put a
    /// heartbeat moments from staleness without a real sleep.
    pub fn record_heartbeat_at_for_test(
        &self,
        user_id: UserId,
        channel_id: ChannelId,
        now: std::time::Instant,
    ) {
        self.heartbeats.record_at(user_id, channel_id, now);
    }

    /// Every `(user, channel)` call whose heartbeat has gone stale as of
    /// `now`, handed back (and forgotten) for the caller to actually evict at
    /// the SFU. `lib.rs`'s own sweep uses this, passing the real clock, so a
    /// test can drive exactly the code that runs in production rather than a
    /// copy of it that could drift; a test is what wants a clock other than
    /// the real one.
    pub fn sweep_stale_calls_at(&self, now: std::time::Instant) -> Vec<(UserId, ChannelId)> {
        self.heartbeats.sweep_stale_at(HEARTBEAT_STALE_AFTER, now)
    }

    /// The shared, cloneable ring tracker (a cheap `Arc` clone), the same
    /// shape [`crate::hub::Hub::presence`] already uses to hand out shared
    /// ephemeral state: unlike [`Self::sweep_stale_calls_at`] and its
    /// heartbeat siblings above, a ring's own start/answer/decline/cancel/
    /// sweep methods live directly on [`CallRings`] rather than being
    /// mirrored here one by one, since every caller already reaches this
    /// through a `VoiceService` handle either way.
    pub fn rings(&self) -> CallRings {
        self.rings.clone()
    }

    /// Removes a participant from a channel's room immediately.
    ///
    /// Used when somebody loses the right to be there, which a token they
    /// already hold would otherwise let them keep exercising until it lapses.
    /// Best-effort by design: it is called from paths whose real work has
    /// already committed, so a failure is logged rather than propagated, and
    /// the short token TTL is the backstop.
    pub async fn remove_participant(
        &self,
        channel_id: ChannelId,
        user_id: UserId,
    ) -> Result<(), VoiceError> {
        // Ended on purpose, so a later sweep must not rediscover and re-call it.
        self.heartbeats.forget(user_id, channel_id);
        let Some(enabled) = self.inner.as_ref() else {
            return Err(VoiceError::Unavailable);
        };
        let room = room_for_channel(channel_id);
        let admin = self.admin_token(enabled, &room)?;

        let response = enabled
            .http
            .post(format!(
                "{}/twirp/livekit.RoomService/RemoveParticipant",
                enabled.service_url
            ))
            .bearer_auth(admin)
            .json(&serde_json::json!({ "room": room, "identity": user_id.to_string() }))
            .send()
            .await
            .map_err(|e| VoiceError::Internal(e.into()))?;

        if !response.status().is_success() {
            let status = response.status();
            // Kicking someone not in the room is the ordinary case, not an error.
            if status == reqwest::StatusCode::NOT_FOUND {
                return Ok(());
            }
            return Err(VoiceError::Internal(anyhow::anyhow!(
                "livekit room service refused the eviction: {status}"
            )));
        }
        Ok(())
    }

    /// A room-admin token good for one immediate call, the shape both
    /// [`Self::remove_participant`] and `roster`'s `list_participants` need.
    fn admin_token(&self, enabled: &Enabled, room: &str) -> Result<String, VoiceError> {
        let now = unix_secs();
        self.sign(
            enabled,
            Claims {
                iss: &enabled.api_key,
                sub: "slim-m-server",
                name: None,
                nbf: now,
                exp: now + ADMIN_TOKEN_TTL_SECS,
                video: VideoGrant {
                    room: room.to_owned(),
                    room_admin: true,
                    room_join: false,
                    can_subscribe: false,
                    can_publish: false,
                    can_publish_data: false,
                    can_update_own_metadata: false,
                },
            },
        )
    }

    /// Signs a claim set as an HS256 JWT, which is the format LiveKit takes.
    ///
    /// The header is a fixed string rather than something built from a struct:
    /// there is exactly one algorithm this ever uses, and writing it out means
    /// nothing can influence it.
    fn sign(&self, enabled: &Enabled, claims: Claims<'_>) -> Result<String, VoiceError> {
        const HEADER: &str = r#"{"alg":"HS256","typ":"JWT"}"#;
        let payload = serde_json::to_vec(&claims)
            .map_err(|e| VoiceError::Internal(anyhow::Error::from(e)))?;

        let signing_input = format!(
            "{}.{}",
            BASE64URL.encode(HEADER),
            BASE64URL.encode(&payload)
        );

        let mut mac = <Hmac<Sha256>>::new_from_slice(enabled.api_secret.as_bytes())
            .map_err(|e| VoiceError::Internal(anyhow::anyhow!("livekit secret rejected: {e}")))?;
        mac.update(signing_input.as_bytes());
        let signature = BASE64URL.encode(mac.finalize().into_bytes());

        Ok(format!("{signing_input}.{signature}"))
    }
}

#[cfg(test)]
mod tests;
