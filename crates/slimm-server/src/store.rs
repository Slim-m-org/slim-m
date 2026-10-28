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

use crate::ids::UserId;

mod account_deletion;
mod admin_audit;
mod analytics;
mod apps;
mod attachments;
mod bootstrap;
mod bot_command_options;
mod bot_commands;
mod bot_prefix;
mod bot_token;
mod bot_ui;
mod bots;
mod calls;
mod canvas;
use canvas::{
    canvas_media_slots, canvas_object_locks, canvas_op_clock, canvas_ops, canvas_ops_sweep,
    canvas_ops_write, canvas_purge,
};
mod categories;
mod category_overwrites;
mod channels;
pub(crate) use channels::channel_slow_mode;
use channels::{channel_create, channel_notification_prefs, channel_order, channel_settings};
mod code_runs;
mod credentials;
mod deployment_identity;
mod dms;
mod dock_sources;
mod emoji;
mod forward_cascade;
mod group_dms;
mod interactions;
mod invite_reuse;
mod invites;
mod linked_accounts;
mod member_gate;
mod members_bulk;
mod messages;
use messages::{
    message_embeds, message_forwards, message_history, message_module_origins, message_ops,
    message_retention, message_search, messages_bulk,
};
mod models;
mod moderation_audit;
mod moderation_history;
mod module_data_dir;
mod modules;
use modules::{module_health, module_kv, module_permissions, module_stats};
mod attachment_text;
mod data_exports;
mod export_capacity;
mod export_member;
mod export_rows;
mod export_scope;
mod export_space;
mod nicknames;
mod notification_schedule;
mod notifications;
mod overwrites_batch;
mod permissions;
mod pins;
mod poll_runoff;
mod polls;
mod presence;
mod push;
mod reactions;
mod read_markers;
mod read_state;
pub use read_state::UNREAD_COUNT_CAP;
mod recovery;
mod refresh_rotation;
mod removals;
mod reports;
mod roles;
use roles::{role_hierarchy, role_reorder, role_update};
mod attachment_originals;
mod login_throttle;
mod media_compression;
mod safety;
mod saved_messages;
mod sessions;
mod sign_in_alert;
mod space;
mod space_landing;
mod space_link_previews;
mod space_welcome;
mod storage;
mod thread_listing;
mod threads;
mod timeouts;
mod totp;
mod totp_verify;
mod user_notes;
mod users;
mod voice_call_events;
mod voice_rooms;
mod voice_sessions;
mod watch_sessions;
mod webhooks;

pub use account_deletion::DeleteAccountError;
pub use admin_audit::AdminAuditEntry;
pub use analytics::{
    ANALYTICS_WINDOW_DAYS, AnalyticsStats, DayCount, MemberAttachmentUsage, MetricSample,
};
pub use apps::{AppSurface, CreateAppSurfaceError};
pub use attachment_originals::KeptOriginal;
pub use attachment_text::TextCandidate;
pub use attachments::{AttachmentSummary, LinkError, MAX_ATTACHMENTS_PER_MESSAGE, OriginalInfo};
pub use bootstrap::Bootstrap;
pub use bot_command_options::BotCommandOption;
pub use bot_commands::{
    BotCommand, BotCommandRegistration, MAX_BOT_COMMAND_DESCRIPTION_LEN, MAX_BOT_COMMAND_NAME_LEN,
    MAX_BOT_COMMAND_USAGE_LEN, MAX_BOT_COMMANDS, MAX_BOT_PREFIX_LEN, RESERVED_BOT_PREFIXES,
    SetBotCommandsError, VisibleBotCommand, validate_bot_prefix,
};
pub use bot_token::{ReissueError, ReissuedToken};
pub use bot_ui::VisibleBotUi;
pub use bots::{BOT_TOKEN_PREFIX, Bot, CreateBotError, NewBot, UpdateBotPermissionsError};
pub use calls::CallRecord;
pub(crate) use canvas::valid_bounds;
pub use canvas::{
    CanvasObject, MAX_CANVAS_OBJECT_CAP, MAX_OBJECT_EXTENT, MAX_OBJECTS_PER_CHANNEL,
    MIN_CANVAS_OBJECT_CAP, PlaceError, PlaceRequest, Placement, Rect, ViewportQuery, WORLD_LIMIT,
};
pub use canvas_media_slots::{CanvasMediaSlot, MediaSlotError, MediaSlotKind};
pub use canvas_object_locks::LockError;
pub use canvas_ops::{
    CANVAS_OP_GAP, CANVAS_OP_PAGE_BYTES, CanvasOpBody, CanvasOpEntry, CanvasOpsPage,
};
pub use canvas_ops_sweep::{CANVAS_OP_RETENTION_MS, SweptCanvasOps};
pub use canvas_ops_write::{
    CanvasOpRequest, ClearScope, MAX_REMOVE_IDS_PER_OP, SubmitOpError, SubmittedOp,
};
pub use canvas_purge::PurgeError;
pub use categories::CreatedCategory;
pub use channel_create::{ChannelDefaults, CreateChannelError, CreatedChannel};
pub use channel_notification_prefs::NotificationChoice;
pub use channel_order::{ChannelOrderGroup, ReorderChannelsError, ReorderOutcome};
pub use channel_settings::ChannelPatch;
pub use channels::DeleteChannelError;
pub use code_runs::{CodeRunRecord, CodeRunSummary, MAX_SHARED_OUTPUT_BYTES, clamp_output};
pub use data_exports::{
    CreateExportError, DataExport, EXPORT_RETENTION_MS, ExportKind, ExportStatus,
};
pub use deployment_identity::MAX_SPACE_NAME_CHARS;
pub(crate) use dms::DM_CHANNEL_KIND;
pub use dms::{DmConversation, GroupDm, OpenDmError};
pub use dock_sources::DockSource;
pub use emoji::{CreateEmojiError, CustomEmoji, MAX_CUSTOM_EMOJI};
pub use export_capacity::DEFAULT_EXPORT_CEILING_BYTES;
pub use export_rows::RowStream;
pub use forward_cascade::{CascadedDeletion, DetachedForward, ForwardCascade};
pub use group_dms::{
    GROUP_DM_MAX_PARTICIPANTS, GROUP_DM_MIN_PARTICIPANTS, GroupDmError, LeftGroup,
};
pub use interactions::{Interaction, InteractionInput, InteractionKind, SubmissionClaim};
pub use invites::{Invite, InviteCheck, InviteMetadata, RedeemError};
pub use linked_accounts::{AccountLinkError, LinkedAccount};
pub use login_throttle::{
    ACCOUNT_FREE_FAILURES, ACCOUNT_MAX_DELAY_MS, FORGET_AFTER_MS, FREE_FAILURES, MAX_DELAY_MS,
};
pub use media_compression::{MediaCompression, MediaCompressionUpdate, default_extensions};
pub use member_gate::{JoinGate, MAX_RULES_CHARS, MemberGate};
pub use message_embeds::{Embed, EmbedField, NewEmbed, NewEmbedField};
pub use message_forwards::{ForwardOrigin, ForwardSource, ForwardSummary};
pub use message_history::MessageRevision;
pub use message_module_origins::{ModuleOrigin, ModuleStamp};
pub use message_ops::{MessageOpEntry, MessageOpKind, MessageOpsPage};
pub use message_retention::{MAX_MESSAGE_RETENTION_DAYS, PrunedMessage, SweptMessageRetention};
pub use message_search::{MessageSearchFilters, SearchError};
pub use messages::{Edited, MessageDeletion, NewMessage, SendError, Sent};
pub use messages_bulk::{BulkDeleteError, BulkDeletion, DeletedMessage};
pub use models::{Channel, ChannelCategory, ChannelRoom, Message, User};
pub use moderation_history::{AuditLogEntry, HistoryCursor, ModerationHistoryItem};
pub use module_health::{EventCandidate, ModuleHealth};
pub use module_kv::KvSetError;
pub use module_permissions::{
    GrantModulePermissionError, GrantedModulePermission, ModulePermission,
};
pub use module_stats::{ModuleRunStat, RunResult, StorageUsage};
pub use modules::{
    DockProvenance, InstallModuleRequest, InstalledModule, ModuleExtensionPoint,
    ModuleExtensionPointSpec, ModulePermissionSpec, ModulePlatform, ModuleRuntimeLimits,
    ModuleSchedule, ModuleSettingDef, ModuleSlot, SettingChoice, SettingKind,
};
pub use notification_schedule::{DaySetting, NotificationScheduleDetail};
pub use overwrites_batch::OverwriteBatchEntry;
pub use permissions::ChannelOverwrite;
pub use pins::{MAX_PINS_PER_CHANNEL, PinError, PinnedMessage};
pub use poll_runoff::Runoff;
pub use polls::{
    Ballot, CreatePollError, MAX_OPTION_CHARS, MAX_OPTIONS, MAX_QUESTION_CHARS, MIN_OPTIONS,
    NewPoll, Poll, PollOption, PollTally, VoteError, VoteOutcome,
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
pub use role_update::RoleChanges;
pub use roles::{CreateRoleError, CreatedRole, ROLE_COLOR_COUNT, Role, RoleGuardError};
pub use safety::Device;
pub use saved_messages::{MAX_SAVED_MESSAGES, SaveError, SavedMessage};
pub use sessions::{Account, IssuedTokens, OpenError, RegisterError, SessionContext, SweptTokens};
pub use space::{JoinPolicy, MAX_SCREEN_SHARE_MAX_HEIGHT, MIN_SCREEN_SHARE_MAX_HEIGHT};
pub use space_landing::{MAX_SPACE_DESCRIPTION_CHARS, SpaceLanding};
pub use space_welcome::{MAX_WELCOME_MESSAGE_CHARS, SpaceWelcome};
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
pub use voice_call_events::{
    CALL_HISTORY_RETENTION_DAYS, CanvasActivity, VoiceEvent, VoiceEventKind,
};
pub use voice_sessions::{SessionScope, VOICE_SESSION_RETENTION_DAYS, VoiceSession};
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
    /// Seals the secrets read back later (two-factor). A bare [`Store::new`] holds a throwaway
    /// key, so a process that should keep them must call [`Store::with_data_key`].
    data_key: Arc<crate::data_key::DataKey>,
    /// Where module data files live; see [`Store::modules_dir`].
    modules_dir: Option<Arc<std::path::PathBuf>>,
}

impl Store {
    pub fn new(pool: SqlitePool) -> Self {
        Self {
            pool,
            canvas_op_clock: Arc::default(),
            data_key: Arc::new(crate::data_key::DataKey::ephemeral()),
            modules_dir: None,
        }
    }

    /// The same store sealing secrets with `key`.
    pub fn with_data_key(mut self, key: crate::data_key::DataKey) -> Self {
        self.data_key = Arc::new(key);
        self
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
            banner_updated_at: None,
            status_text: None,
            pronouns: None,
            about: None,
            profile_color: None,
            profile_color_rgb: None,
            is_bot: false,
            is_webhook: false,
        })
    }
}
