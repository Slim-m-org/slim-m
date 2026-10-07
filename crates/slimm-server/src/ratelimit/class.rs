// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The traffic classes [`super::RateLimiter`] meters, and their budgets.
//!
//! Split out of `ratelimit.rs` to keep that file under the review budget;
//! the limiter mechanism itself (buckets, sweeping, counting) stays there.

/// Declares [`Class`] and [`Class::ALL`] from one list. They were two
/// hand-kept lists, and a class missing from the second compiled clean and
/// was simply never counted.
macro_rules! classes {
    ($( $(#[$doc:meta])* $name:ident, )+) => {
        /// A traffic class and its budget: a sustained refill rate and a burst size.
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
        pub enum Class {
            $( $(#[$doc])* $name, )+
        }

        impl Class {
            /// Every variant, for `/metrics` to enumerate a stable label set from.
            pub const ALL: [Class; [$(Class::$name),+].len()] = [$(Class::$name),+];
        }
    };
}

classes! {
    /// Password endpoints (register, login). Tight, because each request can
    /// cost an Argon2id hash, but sized for the case that actually happens:
    /// several people signing up together from one office or household, who
    /// share an address and so share this bucket.
    ///
    /// Measured 2026-09-15 at the old (5, 1/6) budget: enrolling a hundred
    /// accounts from one address took twenty minutes, and a codeless
    /// registration against a claimed deployment spends a token before it is
    /// refused, so a joining tester pays twice. The concurrency limit on
    /// hashing, not this, is what bounds the memory a burst of logins can
    /// take (`auth::Auth`, four permits of 19 MiB).
    Password,
    /// Token refresh. Cheap, but a leaked token should not be grindable.
    Refresh,
    /// Minting a WebSocket connect ticket.
    Ticket,
    /// Ordinary authenticated writes (send, edit, mark read).
    Write,
    /// Typing refresh frames over the WebSocket. A refresh every few seconds
    /// is normal client behavior, so the budget only needs to absorb a short
    /// burst (switching between channels while typing) while still refusing
    /// a tight loop; the tracker's own dedup already stops a well-behaved
    /// refresh from re-fanning-out, so this exists to bound the cost of a
    /// misbehaving one.
    Typing,
    /// Unauthenticated metadata reads that disclose nothing worth guessing at:
    /// `/version` and its capability list.
    ///
    /// Loose on purpose. The sign-in screen probes `/version` as somebody types
    /// a server address, so a tight budget here would refuse a legitimate user
    /// mid-keystroke; what this bounds is a flood, not a guess. `InviteCheck`
    /// stays tight because a hit there discloses real deployment metadata and
    /// this does not.
    ///
    /// Unauthenticated only - no `Authed`/`AuthedLimited` handler may charge
    /// this, enforced by `tests/rate_limit_coverage.rs`. An authenticated GET
    /// used to charge this too, on the reasoning that it was "just a read";
    /// that made every one of them fight `/version`'s own callers for a
    /// budget sized for a login screen, not a signed-in client. See
    /// [`Class::AuthedRead`] for where those moved.
    Read,
    /// Checking an invite code before signup. Unauthenticated, and a valid
    /// code now discloses real deployment metadata rather than a bare
    /// boolean, which raises what a successful guess is worth; tight for the
    /// same reason `Password` is.
    InviteCheck,
    /// Uploading an attachment or avatar. Far tighter than `Write`: each
    /// request can cost real megabytes of disk, so the budget that is fine
    /// for a burst of short text messages would let one account fill the
    /// volume as fast as it could open connections. Sized for a normal
    /// compose flow (a handful of files with one message, occasionally) while
    /// still bounding a sustained flood to a trickle.
    Upload,
    /// Canvas reads and writes.
    ///
    /// Its own class because both halves are gesture-driven at a rate `Write`
    /// and `Read` were never sized for: a short dash commits an object, and a
    /// pan re-reads the region as soon as the camera settles. A 429 on either
    /// is ink that was already on the drawer's own screen going missing, or a
    /// canvas that stops updating, so the budget is looser than `Write`'s
    /// while still refusing a tight loop. What bounds the *cost* rather than
    /// the rate is elsewhere: the per-object props ceiling, the per-channel
    /// object ceiling, and the viewport limit.
    Canvas,
    /// Canvas pointer-position frames over the WebSocket. Sent far more often
    /// than a typing refresh (a client throttles to roughly 12/second while
    /// the pointer is moving over the canvas), so the budget is sized around
    /// that sustained rate with headroom for a burst, rather than reused from
    /// [`Class::Typing`]'s much sparser one.
    CanvasCursor,
    /// In-flight stroke preview frames over the WebSocket - ephemeral,
    /// relayed but never persisted (see `Event::CanvasStrokePreview`).
    ///
    /// Unlike every other class, this one is denominated in *bytes*, not
    /// requests: a caller charges it through [`super::RateLimiter::check_weighted`]
    /// with the frame's own wire size as the cost, because a preview frame's
    /// size grows with how many points it carries while [`Class::CanvasCursor`]'s
    /// two-number frame never does - a per-request budget sized for a small
    /// frame would starve a legitimately larger one and a budget sized for a
    /// large one would let a flood of tiny frames spend far more bandwidth
    /// than a cursor ever could. This is the byte-rate half of the roadmap's
    /// split canvas rate limits; [`Class::Canvas`] (the persisted-op half) is
    /// unchanged.
    ///
    /// Sized so a capped 24-point frame (under 1.5 KiB) can be sent roughly
    /// eight times back to back before the burst runs out, and sustained
    /// drawing at the client's own throttle interval (90ms) stays inside the
    /// refill with headroom to spare.
    CanvasStrokePreview,
    /// Serving stored bytes back: an attachment, an avatar, a custom emoji
    /// image.
    ///
    /// Its own class because these are the one read shape a single screen
    /// legitimately fires dozens of at once - a member page resolves an
    /// avatar per member, and a transcript of image posts resolves one per
    /// message - so [`Class::Read`]'s budget, sized for a handful of
    /// page-level fetches, would stall a member list on any deployment past
    /// about twenty people. Sized instead for the largest honest burst a
    /// screen produces, with a refill that still refuses a sustained loop.
    ///
    /// What this bounds is the request *rate*, not the bytes behind it: an
    /// attachment may be megabytes where an avatar is kilobytes, and this
    /// charges them the same. Byte cost is bounded elsewhere, by the
    /// per-upload ceiling and the deployment-wide storage ceiling. If
    /// large-attachment flooding ever becomes real rather than theoretical,
    /// the answer is a byte-weighted charge through
    /// [`super::RateLimiter::check_weighted`], the way
    /// [`Class::CanvasStrokePreview`] already works - not a smaller budget
    /// here, which would break the avatar case this exists to serve.
    Asset,
    /// A cheap authenticated read: a list, a lookup, or a poll, never a
    /// mutation and never a real aggregation or outbound call.
    ///
    /// Every authenticated read used to be split between two other classes,
    /// both wrong for it: [`Class::Read`], whose own doc says it exists for
    /// *unauthenticated* metadata like `/version` and is tighter than
    /// [`Class::Write`] on the theory that nobody needs more than a handful
    /// of those - a theory that never held once an authenticated route
    /// started charging it too; or [`Class::Write`], which meant the voice
    /// roster, `/space/settings`, and the removed-members list shared one
    /// budget with token mint, heartbeat, and kick. This is the third class
    /// that should have existed from the start: every plain list/lookup GET
    /// behind `AuthedLimited<AUTHED_READ>` (`crate::http::extract`), plus
    /// the voice roster, `/space/settings`, `/members/removed`, and the
    /// cheap single-row analytics config reads (retention, canvas cap,
    /// screen-share cap). `/space/analytics`'s own stats query and
    /// `/metrics`'s live SFU probe are *not* here - both do real
    /// cross-table aggregation or an uncached outbound call, so they stay on
    /// [`Class::Write`]'s tighter budget even though they are GETs; see
    /// their own call sites for why.
    ///
    /// Sized against two concrete workloads rather than a round number.
    /// The sustained refill answers the polled voice roster: every unjoined
    /// voice channel a client is rendering re-fetches its roster every 15
    /// seconds (`voiceRosterPollInterval` in
    /// `client/packages/app/lib/src/providers/voice_roster.dart`), nudged
    /// early on a live join/leave rather than waiting out the interval. At
    /// this refill, over 100 simultaneously-open voice channels could each
    /// poll on their own 15-second cycle forever without ever touching the
    /// burst, leaving headroom for every other read a client makes in the
    /// same stretch. The burst answers a reconnect: `ChannelRefresher`
    /// (`client/packages/app/lib/src/providers/channel_refresher.dart`)
    /// fetches every channel's and DM's read marker concurrently the moment
    /// a dropped socket comes back, alongside the channel/category/DM lists
    /// and the notification-override and block lists two other controllers
    /// fire at the same time. A deployment with more open channels than the
    /// burst covers does not fail that reconnect: the extra read-marker
    /// fetches simply wait out the refill and land a couple of seconds
    /// later, the same graceful-degradation shape [`Class::Canvas`]'s own
    /// doc describes, not a 429 storm.
    AuthedRead,
    /// Searching a third-party GIF provider, and picking a result to attach.
    ///
    /// Tighter than [`Class::Read`] on purpose: unlike every other read this
    /// server serves, each request here is a real outbound call to a
    /// provider this deployment has its own, possibly-metered API key with -
    /// a client bug or a tight retype loop should not be able to spend that
    /// budget as fast as it can open connections. Sized for a person typing
    /// a query, pausing, then picking a result, not for a per-keystroke
    /// search; see `http::gifs` for the debounce that keeps it that shape in
    /// practice.
    Gif,
    /// Ringing someone on a DM call.
    ///
    /// Tighter than [`Class::Write`] for the same reason [`Class::Upload`]
    /// is: the request's real-world cost is nothing like an ordinary write.
    /// One ring fires an outbound push through the relay, wakes a device,
    /// starts a looping tone, and on desktop raises and focuses the callee's
    /// window. On `Write`'s budget a contact could legally re-ring five
    /// times a second forever - and because a fresh ring REPLACES the
    /// outstanding one by design (`voice::ring`), that needs no cooperation
    /// from the callee to sustain.
    ///
    /// Sized for how a person actually calls: a few attempts in a row when
    /// someone does not pick up, then a pause. The 30-second ring timeout
    /// means a legitimate cadence is roughly one ring per half minute, so a
    /// burst of 5 covers a redial flurry with room to spare while cutting
    /// the sustained rate by a factor of 25. Declining is deliberately NOT
    /// in this class: it wakes nobody and answering quickly is the behaviour
    /// to encourage.
    Ring,
    /// Unfurling a pasted link into a preview.
    ///
    /// Tight for the same reason as [`Class::Gif`]: each request is a real
    /// outbound fetch to a member-supplied URL, so a client bug or a paste
    /// loop should not be able to make the server hammer a third party as
    /// fast as it can open connections. Sized for a person pasting a handful
    /// of links, not a per-keystroke re-fetch; the client caches per URL.
    LinkPreview,
    /// Running a module command, both the direct route and the shared
    /// code-block one.
    ///
    /// Both routes charged [`Class::Write`] before this existed, and a playing
    /// scene asks for the next frame every 130ms. A Game of Life left running
    /// sailed through that burst and then failed outright - found by running
    /// one - and, worse, a board playing was spending the same allowance a
    /// person needs to send a message. Those are different workloads and
    /// should not share a bucket.
    ///
    /// Sized just above an animating scene's own tick so play does not spend
    /// its life being refused, and below [`Class::Canvas`] because a frame
    /// here costs a sandboxed execution rather than a row write. What bounds
    /// the *cost* of each call is the module's own `runtime.limits` - its fuel
    /// and wall-clock ceilings - not this, which bounds only the rate.
    Module,
    /// Running a fenced code block through this deployment's configured code
    /// runner (`crate::code_runner`), both the generic route and the shared
    /// message-scoped one - charged in addition to whatever [`Class::Module`]
    /// this same route already charges (`http::module_commands::execute_code_runner`).
    ///
    /// Its own class rather than sharing [`Class::Module`]'s budget: a run
    /// here is a real outbound call to an external service that spins up a
    /// sandboxed process per submission, closer in cost to [`Class::Gif`]
    /// and [`Class::LinkPreview`]'s "a real call to a provider" reasoning
    /// than to an in-process wasm command. Sized the same as those for the
    /// same reason - a person pressing Run a handful of times, not a
    /// per-keystroke loop. What bounds the *cost* of one run is the
    /// runner's own sandbox plus the explicit timeouts and memory ceiling
    /// this server asks it for (`code_runner::piston`), not this, which
    /// bounds only the rate.
    CodeRunner,
    /// Delivering an incoming webhook post (`POST
    /// /webhooks/{webhook_id}/{token}`), unauthenticated by anything but
    /// possession of the token.
    ///
    /// Sized against push cost, not write cost, for the reason
    /// [`Class::Ring`]'s own doc gives for the same move: one delivered post
    /// fans out over the hub and fires a push through the relay to
    /// everyone who can see the channel, so it "wakes a device, starts a
    /// looping tone" (there, one device; here, every phone in the
    /// community) far more like a ring than like an ordinary write.
    ///
    /// Two independent buckets share this one class rather than each
    /// getting its own: an address-keyed bucket, checked before the token
    /// lookup so an unknown-token flood costs a map probe rather than a
    /// database query, and a webhook-keyed bucket, checked after, on the
    /// principal id the token resolved to - `docs/decisions/0030-incoming-webhooks.md`'s
    /// own reasoning for why the second must never key on the caller's
    /// address, the same argument 0028 makes for a bot. Both share one
    /// budget because the cost this bounds - one successful delivery's
    /// fan-out - is identical regardless of which bucket is doing the
    /// asking.
    ///
    /// Sustained refill well under one per second, so a loop against a
    /// leaked URL cannot sustain more than a token every few seconds; burst
    /// generous enough for the honest bursts an alert feed produces, which
    /// are real - a flapping monitor retrying, or an importer that lands
    /// thirty episodes at once.
    Webhook,
    /// Receiving a LiveKit webhook (`POST /voice/webhook`), verified by its
    /// own JWT signature rather than a session. Address-keyed, since there
    /// is exactly one legitimate caller: the configured LiveKit deployment.
    ///
    /// Sized well above [`Class::Webhook`]: a busy multi-channel voice
    /// deployment can fan out several joins, leaves and track events within
    /// the same second, and each one only republishes to a hub already
    /// idempotent-checked (`voice::live_state`), so admitting a real burst
    /// costs nothing this budget needs to protect against. See
    /// `docs/decisions/0032-voice-participant-webhooks.md`.
    LiveKitWebhook,
    /// Pressing a bot's button. Charged per clicker, and tighter than
    /// [`Class::Write`]: each press wakes a bot, which may run real work, so a
    /// held-down key must not be able to drive it as fast as it can open
    /// connections. Sized for a person tapping a button a few times, not a loop.
    Interaction,
    /// A module's `message.post` host call (decision 0023), charged in
    /// addition to the [`Class::Module`] run that made it.
    ///
    /// Keyed per (module, invoking user): five posts in a burst, then one every
    /// six seconds. The same class is charged against the module as a whole at a
    /// quarter of a token per post, so many users together still cannot push one
    /// module past twenty in a burst. A module is admin-approved code, but a
    /// buggy loop in one should cost a channel a few messages, not a flood.
    ModulePost,
    /// The "a new device signed in" notice, keyed per account.
    ///
    /// Sustained refill of one per ten minutes after a burst of three, so a
    /// login loop (or someone probing a stolen password) cannot turn the
    /// account's other devices into a notification firehose. Sign-ins past
    /// the budget still succeed; only the notice is dropped.
    SignInAlert,
    /// Presenting a second factor: the sign-in challenge, and the enrolled
    /// member's own confirm/disable/reissue calls.
    ///
    /// Tighter than [`Class::Password`], which is the point of having it at
    /// all. A password has whatever entropy somebody chose; a TOTP code has
    /// exactly a million values and a recovery code is one of ten live at a
    /// time, so the rate a caller may present guesses at is a first-class
    /// control rather than a cost bound. Sized for a person who mistypes six
    /// digits a couple of times and then gets it right, not for a script.
    ///
    /// This is only the rate half. What bounds the *total* number of guesses
    /// against one account is the persistent lockout counter on the factor
    /// row (`store::totp_verify::record_failure`), which survives a restart
    /// and does not care which address is asking; see decision 0048 for why
    /// neither one alone is enough.
    ///
    /// The burst is deliberately *above* `totp::MAX_FAILURES`, and that
    /// ordering is load-bearing rather than incidental. At or below it, this
    /// bucket empties first and every refusal past that point is a 429 from
    /// the address's rate budget, so the per-account lockout never gets to
    /// fire and, worse, two people signing in from one office share one
    /// account's worth of attempts. Found by a test that asserted the lockout
    /// and was passing on the limiter's 429 instead; `all_tests` below now
    /// pins the relationship.
    Totp,
    /// A member's rich-presence activity (`PUT`/`DELETE /presence/activity`).
    ///
    /// A player reports a track change every few minutes at most, but a
    /// skipping listener can change it every few seconds and each accepted
    /// write fans out to every connected member. Burst six absorbs a skip
    /// streak; a refill of one per five seconds bounds the sustained rate.
    /// See `docs/decisions/0044-rich-presence.md`.
    PresenceActivity,
    /// A bot's watch-position tick (`POST /channels/{id}/watch-session/tick`).
    ///
    /// The bot sends one every 5 seconds per session, 0.2 a second, so this
    /// is its own class rather than [`Class::CanvasCursor`]'s 15. Burst four
    /// absorbs a retry after a stall; a refill of one per two seconds is
    /// two and a half times the honest rate and still refuses a loop.
    WatchTick,
}

impl Class {
    /// (burst, refill per second). For [`Class::CanvasStrokePreview`] the
    /// unit is bytes, not requests; see its own doc.
    pub(super) const fn budget(self) -> (f64, f64) {
        match self {
            Class::Password => (10.0, 1.0 / 3.0),
            Class::Refresh => (10.0, 1.0 / 2.0),
            Class::Ticket => (10.0, 1.0),
            Class::Write => (30.0, 5.0),
            Class::Typing => (10.0, 2.0),
            Class::Read => (20.0, 2.0),
            Class::InviteCheck => (10.0, 1.0 / 10.0),
            Class::Upload => (10.0, 1.0 / 20.0),
            Class::Canvas => (60.0, 10.0),
            Class::CanvasCursor => (30.0, 15.0),
            // See this variant's own doc comment for how these were sized.
            Class::CanvasStrokePreview => (12_288.0, 6_144.0),
            // A full member page plus a transcript's own avatars, at once.
            Class::Asset => (150.0, 25.0),
            Class::Gif => (10.0, 1.0),
            Class::LinkPreview => (10.0, 1.0),
            // See this variant's own doc comment for how these were sized.
            Class::Ring => (5.0, 1.0 / 5.0),
            // See this variant's own doc comment for the roster and reconnect math.
            Class::AuthedRead => (40.0, 8.0),
            // See this variant's own doc comment for how these were sized.
            Class::Module => (40.0, 8.0),
            // See this variant's own doc comment for how these were sized.
            Class::CodeRunner => (10.0, 1.0),
            // See this variant's own doc comment for how these were sized.
            Class::Webhook => (30.0, 1.0 / 3.0),
            // See this variant's own doc comment for how these were sized.
            Class::LiveKitWebhook => (120.0, 20.0),
            // A person pressing buttons: a short burst, then about one press a second.
            Class::Interaction => (8.0, 1.0),
            // See this variant's own doc comment for how these were sized.
            Class::ModulePost => (5.0, 1.0 / 6.0),
            // See this variant's own doc comment for how these were sized.
            Class::SignInAlert => (3.0, 1.0 / 600.0),
            // See this variant's own doc comment for how these were sized.
            Class::Totp => (8.0, 1.0 / 10.0),
            // See this variant's own doc comment for how these were sized.
            Class::PresenceActivity => (6.0, 1.0 / 5.0),
            // See this variant's own doc comment for how these were sized.
            Class::WatchTick => (4.0, 1.0 / 2.0),
        }
    }
}

#[cfg(test)]
mod tests;
