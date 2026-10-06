// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The persistence layer over one embedded SQLite database: the [`Store`]
//! handle itself, the domain types shared across every feature submodule, and
//! the handful of methods (account creation, liveness, live user ids) that do
//! not belong to any single feature area.
//!
//! Everything else is split by feature, mirroring the HTTP surface: messages in
//! [`messages`], channel CRUD in [`channels`], user profiles and the member
//! list in [`users`], reactions in [`reactions`], and so on. Inherent on
//! [`Store`] for now; it lifts to a repository trait when Postgres needs one.

use std::sync::Arc;

use sqlx::SqlitePool;

use crate::ids::{ChannelCategoryId, ChannelId, MessageId, Seq, UserId};

mod account_deletion;
mod analytics;
mod apps;
mod attachment_refs;
mod attachments;
mod bootstrap;
mod bot_commands;
mod bot_ui;
mod bots;
mod calls;
mod canvas;
mod canvas_audit;
mod canvas_geometry;
mod canvas_media_slots;
mod canvas_move;
mod canvas_op_clock;
mod canvas_ops;
mod canvas_ops_apply;
mod canvas_ops_sweep;
mod canvas_ops_write;
mod categories;
mod channel_create;
mod channel_notification_prefs;
mod channel_order;
mod channel_restricted;
mod channel_settings;
mod channel_slow_mode;
mod channels;
mod code_runs;
mod credentials;
mod dms;
mod dock_sources;
mod emoji;
mod forward_cascade;
mod interactions;
mod invites;
mod members_bulk;
mod message_components;
mod message_embeds;
mod message_forwards;
mod message_history;
mod message_mentions;
mod message_ops;
mod message_reads;
mod message_retention;
mod message_search;
mod messages;
mod messages_bulk;
mod messages_bulk_window;
mod moderation_audit;
mod moderation_history;
mod module_artifacts;
mod module_kv;
mod module_permissions;
mod modules;
mod nicknames;
mod notification_schedule;
mod notifications;
mod overwrites_batch;
mod permissions;
mod permissions_batch;
mod permissions_resolve;
mod pins;
mod polls;
mod presence;
mod push;
mod quiet_hours;
mod reactions;
mod read_markers;
mod read_state;
mod recovery;
mod refresh_rotation;
mod removals;
mod reports;
mod role_bots;
mod role_hierarchy;
mod role_hoist;
mod role_mentions;
mod role_reorder;
mod role_update;
mod roles;
mod safety;
mod saved_messages;
mod sessions;
mod sign_in_alert;
mod space;
mod storage;
mod thread_listing;
mod threads;
mod timeouts;
mod totp;
mod totp_verify;
mod user_notes;
mod users;
mod watch_sessions;
mod webhooks;

pub use account_deletion::DeleteAccountError;
pub use analytics::{
    ANALYTICS_WINDOW_DAYS, AnalyticsStats, DayCount, MemberAttachmentUsage, MetricSample,
};
pub use apps::{AppSurface, CreateAppSurfaceError};
pub use attachments::{AttachmentSummary, LinkError, MAX_ATTACHMENTS_PER_MESSAGE};
pub use bootstrap::Bootstrap;
pub use bot_commands::{
    BotCommand, BotCommandRegistration, MAX_BOT_COMMAND_DESCRIPTION_LEN, MAX_BOT_COMMAND_NAME_LEN,
    MAX_BOT_COMMAND_USAGE_LEN, MAX_BOT_COMMANDS, MAX_BOT_PREFIX_LEN, RESERVED_BOT_PREFIXES,
    SetBotCommandsError, VisibleBotCommand,
};
pub use bot_ui::VisibleBotUi;
pub use bots::{BOT_TOKEN_PREFIX, Bot, CreateBotError, NewBot, UpdateBotPermissionsError};
pub use calls::CallRecord;
pub use canvas::{
    CanvasObject, MAX_CANVAS_OBJECT_CAP, MAX_OBJECT_EXTENT, MAX_OBJECTS_PER_CHANNEL,
    MIN_CANVAS_OBJECT_CAP, PlaceError, PlaceRequest, Placement, Rect, ViewportQuery, WORLD_LIMIT,
};
pub use canvas_media_slots::{CanvasMediaSlot, MediaSlotError, MediaSlotKind};
pub use canvas_ops::{
    CANVAS_OP_GAP, CANVAS_OP_PAGE_BYTES, CanvasOpBody, CanvasOpEntry, CanvasOpsPage,
};
pub use canvas_ops_sweep::{CANVAS_OP_RETENTION_MS, SweptCanvasOps};
pub use canvas_ops_write::{CanvasOpRequest, MAX_REMOVE_IDS_PER_OP, SubmitOpError, SubmittedOp};
pub use categories::CreatedCategory;
pub use channel_create::{CreateChannelError, CreatedChannel};
pub use channel_order::{ChannelOrderGroup, ReorderChannelsError, ReorderOutcome};
pub use channel_settings::ChannelPatch;
pub use channel_slow_mode::slow_mode_retry_after_seconds;
pub use channels::DeleteChannelError;
pub use code_runs::{CodeRunSummary, MAX_SHARED_OUTPUT_BYTES, clamp_output};
pub(crate) use dms::DM_CHANNEL_KIND;
pub use dms::{DmConversation, OpenDmError};
pub use dock_sources::DockSource;
pub use emoji::{CreateEmojiError, CustomEmoji, MAX_CUSTOM_EMOJI};
pub use forward_cascade::{CascadedDeletion, DetachedForward, ForwardCascade};
pub use interactions::{Interaction, InteractionKind};
pub use invites::{Invite, InviteCheck, InviteMetadata, RedeemError};
pub use message_embeds::{Embed, EmbedField, NewEmbed, NewEmbedField};
pub use message_forwards::{ForwardOrigin, ForwardSource, ForwardSummary};
pub use message_history::MessageRevision;
pub use message_ops::{MessageOpEntry, MessageOpKind, MessageOpsPage};
pub use message_retention::{MAX_MESSAGE_RETENTION_DAYS, PrunedMessage, SweptMessageRetention};
pub use message_search::{MessageSearchFilters, SearchError};
pub use messages::{Edited, MessageDeletion, NewMessage, SendError, Sent};
pub use messages_bulk::{BulkDeleteError, BulkDeletion, DeletedMessage};
pub use moderation_history::{AuditLogEntry, HistoryCursor, ModerationHistoryItem};
pub use module_kv::KvSetError;
pub use module_permissions::{
    GrantModulePermissionError, GrantedModulePermission, ModulePermission,
};
pub use modules::{
    DockProvenance, InstallModuleRequest, InstalledModule, ModuleExtensionPoint,
    ModuleExtensionPointSpec, ModulePermissionSpec, ModuleRuntimeLimits,
};
pub use notification_schedule::{DaySetting, NotificationScheduleDetail};
pub use overwrites_batch::OverwriteBatchEntry;
pub use permissions::ChannelOverwrite;
pub use pins::{MAX_PINS_PER_CHANNEL, PinError, PinnedMessage};
pub use polls::{
    CreatePollError, MAX_OPTION_CHARS, MAX_OPTIONS, MAX_QUESTION_CHARS, MIN_OPTIONS, Poll,
    PollOption, PollTally, VoteError,
};
pub use push::{PushError, PushRegistration, PushTarget};
pub use reactions::{MAX_EMOJI_BYTES, ReactError, ReactionSummary, ReactorCursor};
pub use read_markers::ChannelReadState;
pub use recovery::{ConsumeResetError, IssueResetError};
pub use refresh_rotation::RefreshOutcome;
pub use removals::{RemoveMemberError, SpaceRemoval};
pub use reports::{
    EPHEMERAL_KIND, EphemeralSubject, FiledReport, Report, ReportError, ReportSubject,
    ReporterOwnReport,
};
pub use role_hierarchy::RoleWithCount;
pub use role_reorder::{ReorderRolesError, RoleReorderOutcome};
pub use roles::{CreateRoleError, CreatedRole, Role, RoleGuardError};
pub use safety::Device;
pub use saved_messages::{MAX_SAVED_MESSAGES, SaveError, SavedMessage};
pub use sessions::{Account, IssuedTokens, OpenError, RegisterError, SessionContext, SweptTokens};
pub use space::{JoinPolicy, MAX_SCREEN_SHARE_MAX_HEIGHT, MIN_SCREEN_SHARE_MAX_HEIGHT};
pub use storage::{ChannelStorage, DatabaseBytes, MAX_STORAGE_CHANNEL_ROWS, SweepStatus};
pub use thread_listing::ThreadListItem;
pub use threads::{
    MAX_THREADS_PER_CHANNEL, OpenThreadError, OpenedThread, ThreadParent, ThreadSummary,
};
pub use timeouts::{MAX_TIMEOUT_MS, MemberTimeout, TimeoutError};
pub use totp::{RECOVERY_CODE_COUNT, TotpEnrolment, TotpError, TotpPolicy, TotpStatus};
pub use totp_verify::{ChallengeError, TotpChallenge, TotpProof, TotpSignIn};
pub use user_notes::UserNote;
pub use users::ProfileUpdate;
pub use watch_sessions::{
    WATCH_SESSION_TTL_MS, WatchSample, WatchSession, WatchSessionWrite, WatchWriteOutcome,
};
pub use webhooks::{NewWebhook, Webhook, WebhookContext};

/// Largest number of ids to bind into one `IN (...)` list, for the batched
/// reads that build a variable-length query. Well under SQLite's default
/// `SQLITE_MAX_VARIABLE_NUMBER` of 32766, with headroom for the odd extra
/// bind a query carries alongside the list (a `user_id`, say). A caller with
/// more ids than this chunks and merges rather than handing SQLite a
/// statement it refuses to prepare; see [`Store::user_profiles`] and
/// [`Store::unread_counts`].
pub(crate) const MAX_IDS_PER_QUERY: usize = 20_000;

/// Unix milliseconds, `pub(crate)` so the push trigger path (outside this
/// module) can compare a lifecycle report's age against the same clock
/// everything here is stamped with.
pub(crate) fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// A channel (a text or voice room).
#[derive(Debug, Clone)]
pub struct Channel {
    pub id: ChannelId,
    pub name: String,
    pub kind: String,
    /// A one-line description shown beside the name in the client's channel
    /// header. `None` for no topic; an edit to a blank value normalizes to
    /// `None`, since an empty topic and no topic render the same.
    pub topic: Option<String>,
    /// Sort key among the deployment's live, non-DM channels: lower sorts
    /// first. Deployment-wide, not per-device - see
    /// [`super::channel_order::reorder_channels`]. Meaningless for a DM,
    /// which is never listed or reordered by it.
    pub position: i64,
    /// The message this channel is a thread of, or `None` for an ordinary
    /// channel. A thread's own `kind` and overwrites are never consulted for
    /// permissions: see [`Store::permission_channel`], which resolves them
    /// live from this message's own `channel_id` instead, per
    /// docs/decisions/0005-threads.md. A thread never appears in
    /// [`Store::list_channels`].
    pub parent_message_id: Option<MessageId>,
    /// The rail section this channel is filed under, or `None` for
    /// uncategorised - rendered as an implicit section above every named
    /// one. Decides placement only, never behaviour: see
    /// docs/decisions/0006-channel-categories.md. A category carries no
    /// permissions of its own, so this column is never consulted by
    /// [`Store::permission_channel`] or anything it calls.
    pub category_id: Option<ChannelCategoryId>,
    pub created_at: i64,
    /// The minimum interval, in seconds, a non-`MANAGE_CHANNELS` member must
    /// wait between their own messages here. 0 means off. Never read for a DM
    /// or a thread, neither of which exposes a setter for it - see
    /// [`super::channel_slow_mode::Store::update_channel_slow_mode`].
    pub slow_mode_seconds: i64,
    /// Voice-channel default that every client opens its mic off on join. A
    /// default, not a lock: SPEAK overwrites are what restrict speaking. See
    /// [`super::channel_settings::Store::update_channel_settings`].
    pub join_muted: bool,
}

/// A rail section: a channel of any kind may be filed under one, per
/// docs/decisions/0006-channel-categories.md. Organisational only - it
/// grants and denies no permission, see docs/IMPLIED-GAPS.md.
#[derive(Debug, Clone)]
pub struct ChannelCategory {
    pub id: ChannelCategoryId,
    pub name: String,
    /// Sort key among the deployment's live categories: lower sorts first.
    /// Uncategorised channels render above every named category regardless
    /// of this value, since they carry no category row to hold one.
    pub position: i64,
    pub created_at: i64,
}

/// A user account's public profile. Deliberately narrow: id, username,
/// display name, and creation time only. Nothing from the auth tables
/// (password hash, sessions, tokens) has a type that could even be confused
/// with this one.
#[derive(Debug, Clone)]
pub struct User {
    pub id: UserId,
    pub username: String,
    pub display_name: String,
    pub created_at: i64,
    /// When the caller's current avatar was set, or `None` for no avatar.
    /// Not a foreign key to anything: the bytes live on disk keyed by user
    /// id, not content-addressed like a message attachment (see migration
    /// 0013). A client uses the value only as a cache-busting version
    /// appended to the fetch URL.
    pub avatar_updated_at: Option<i64>,
    /// A short free-text status line ("in a meeting", "afk"), or `None` for
    /// none set. Rides alongside `display_name` (migration 0044): set from
    /// personal settings, shown in the member pane under the name, and
    /// carries no independent live event - `Event::ProfileChanged` already
    /// covers it the same way it covers a rename.
    pub status_text: Option<String>,
    /// A short self-described pronoun set ("she/her"), or `None` if unset.
    /// Shown on the member card beside the `@handle`; see migration 0075.
    pub pronouns: Option<String>,
    /// A short free-text "about" line (190 characters), or `None` if unset.
    /// Shown on the member card under the status line; see migration 0075.
    pub about: Option<String>,
    /// An index into the design system's closed categorical colour set
    /// (`AppCanvasColors.cursors`, six hues), or `None` for the default. Never
    /// a raw colour: an index keeps meaning a fixed hue in both themes. See
    /// migration 0075.
    pub profile_color: Option<i64>,
    /// Whether this account is a bot rather than a person, so a reader can be
    /// told without inspecting anything. See
    /// `docs/decisions/0028-bot-accounts.md`; it changes how the account
    /// authenticates and how it is labelled, never what it may do.
    pub is_bot: bool,
    /// Whether this account is a webhook's principal rather than a person or
    /// a bot. See `docs/decisions/0030-incoming-webhooks.md`; like `is_bot`
    /// it changes how the account authenticates (a webhook has no session at
    /// all) and how it is labelled, never what it may do - except that a
    /// webhook holds no roles in the first place, so there is nothing for it
    /// to do beyond posting through its one delivery route.
    pub is_webhook: bool,
}

/// A message. `author_id` is null once the author's account is anonymized.
///
/// The author's display name rides along with the message rather than being
/// looked up per author by the client, which would be a request per distinct
/// sender in a channel. It is null for the same reason `author_id` is: the
/// account was anonymized, and there is no name left to show.
#[derive(Debug, Clone)]
pub struct Message {
    pub id: MessageId,
    pub channel_id: ChannelId,
    pub author_id: Option<UserId>,
    pub author_display_name: Option<String>,
    pub seq: Seq,
    pub content: String,
    pub created_at: i64,
    pub edited_at: Option<i64>,
    /// The message this one replies to, if any. Always in this same channel:
    /// [`Store::send_message`] refuses any other target at write time. The
    /// parent's own content, author and liveness are never copied here -
    /// resolve them by looking that id up like any other message, so a
    /// later edit or delete of the parent is never something a reply's own
    /// row could go stale about.
    pub reply_to_id: Option<MessageId>,
}

/// A snapshot of [`Store::pool_stats`]: how many of the pool's connections
/// are open at all, and how many of those are currently checked out.
#[derive(Debug, Clone, Copy)]
pub struct PoolStats {
    pub max: u32,
    pub size: u32,
    pub in_use: u32,
}

/// The persistence layer over one embedded SQLite database.
#[derive(Clone)]
pub struct Store {
    pool: SqlitePool,
    /// Backs [`canvas_op_clock::Store::now_ms_unique`]. `Arc`-shared so every
    /// clone of one `Store` sees the same clock, and fresh on every new
    /// `Store` - which is what makes it fresh on every process restart too,
    /// since a restart constructs a brand new one rather than reusing state
    /// that outlived the process. See that method's own doc for why a fresh,
    /// unseeded clock is the exact gap the seeding step closes.
    canvas_op_clock: Arc<canvas_op_clock::CanvasOpClock>,
}

impl Store {
    pub fn new(pool: SqlitePool) -> Self {
        Self {
            pool,
            canvas_op_clock: Arc::default(),
        }
    }

    /// Confirms the database answers a trivial query. Backs the liveness probe.
    pub async fn ping(&self) -> anyhow::Result<()> {
        sqlx::query("SELECT 1").execute(&self.pool).await?;
        Ok(())
    }

    /// Live occupancy of the shared SQLite pool, for `/metrics`'s pool
    /// gauges: every read and every write share the same eight connections,
    /// so how many are checked out is the most direct signal of contention
    /// this server has. `max` is read off the pool's own configuration
    /// rather than duplicated as a constant, so it can never drift from
    /// what `db::connect` actually set.
    pub fn pool_stats(&self) -> PoolStats {
        let size = self.pool.size();
        let idle = u32::try_from(self.pool.num_idle()).unwrap_or(size);
        PoolStats {
            max: self.pool.options().get_max_connections(),
            size,
            in_use: size.saturating_sub(idle),
        }
    }

    /// Opens a transaction that takes SQLite's write lock immediately.
    ///
    /// The pool hands out eight connections and any of them may write, so two
    /// requests really can be inside a transaction at once. A plain `BEGIN` is
    /// deferred: it takes a read snapshot on its first statement and only tries
    /// for the write lock later. If another connection took that lock in
    /// between, the upgrade cannot wait, because two readers both waiting to
    /// become writers would deadlock, so SQLite returns SQLITE_BUSY at once and
    /// `busy_timeout` never comes into it.
    ///
    /// Any transaction whose first statement is a write already avoids this by
    /// construction, which is what most of the store does deliberately (see
    /// [`Store::rotate_refresh`]). Use this for the ones that genuinely have to
    /// read before they decide what to write.
    pub(crate) async fn begin_write(
        &self,
    ) -> Result<sqlx::Transaction<'_, sqlx::Sqlite>, sqlx::Error> {
        self.pool.begin_with("BEGIN IMMEDIATE").await
    }

    /// Opens a transaction that only reads, for a consistent snapshot across
    /// several statements.
    ///
    /// The deferred `BEGIN` is right here and only here: nothing in it ever
    /// asks for the write lock, so there is no upgrade to be refused. A
    /// transaction that writes anything takes [`Store::begin_write`], even
    /// when its first statement is itself a write, so that adding a read in
    /// front of it later cannot turn a concurrent request into a 500.
    pub(crate) async fn begin_read(
        &self,
    ) -> Result<sqlx::Transaction<'_, sqlx::Sqlite>, sqlx::Error> {
        self.pool.begin().await
    }

    /// Creates a passwordless user. Used by tests and internal fixtures; the
    /// authenticated registration path is [`Store::create_account`].
    pub async fn create_user(&self, username: &str, display_name: &str) -> anyhow::Result<User> {
        let id = UserId::generate();
        let now = now_ms();
        sqlx::query!(
            "INSERT INTO users (id, username, display_name, created_at) VALUES (?, ?, ?, ?)",
            id,
            username,
            display_name,
            now
        )
        .execute(&self.pool)
        .await?;
        Ok(User {
            id,
            username: username.to_owned(),
            display_name: display_name.to_owned(),
            created_at: now,
            avatar_updated_at: None,
            status_text: None,
            pronouns: None,
            about: None,
            profile_color: None,
            is_bot: false,
            is_webhook: false,
        })
    }

    /// The server's long-lived identity keypair, generating and persisting
    /// one on the first call a fresh deployment ever makes. See
    /// [`crate::identity`] for what a client may and may not conclude from it.
    pub async fn server_identity(&self) -> anyhow::Result<crate::identity::ServerIdentity> {
        crate::identity::load_or_create(&self.pool).await
    }

    /// The secret a module's caller id is keyed with, so the id cannot be
    /// recomputed from a module id and a user id, both of which are public.
    pub async fn module_caller_key(&self) -> anyhow::Result<[u8; 32]> {
        crate::identity::derived_key(&self.pool, b"slim-module-caller-key-v2").await
    }

    /// This deployment's display name, shown to a prospective joiner (invite
    /// metadata) before they have an account.
    ///
    /// Backed by `server_meta` rather than a dedicated column: it is exactly
    /// the kind of singleton deployment-wide setting that table already
    /// exists for, seeded with a default by migration 0010. The fallback
    /// here is defensive only (every deployment gets the seeded row), not a
    /// substitute for it.
    pub async fn deployment_name(&self) -> anyhow::Result<String> {
        let value = sqlx::query_scalar!(
            r#"SELECT value AS "value!" FROM server_meta WHERE key = 'deployment_name'"#
        )
        .fetch_optional(&self.pool)
        .await?;
        Ok(value.unwrap_or_else(|| "slim-m".to_owned()))
    }
}
