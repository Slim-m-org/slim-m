// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Every column that points at a user must have been thought about for a member's export: the file that carries it is named here, or the reason it stays out.
//! Schema-driven like `account_deletion_coverage.rs`, so a new table fails until someone decides; each file is also checked against a real archive.

use slimm_server::config::Config;
use slimm_server::db;
use sqlx::Row;

mod support;

use support::exports::{account, world};

#[derive(Debug, Clone, Copy)]
enum Fate {
    /// Written to the member's archive, in this file.
    Exported(&'static str),
    /// Left out, for a reason that has to be written down.
    Excluded(&'static str),
}

const BOT_CONFIG: &str =
    "configuration of a bot, webhook or module the member created, kept out of the first format";
const STAFF_RECORD: &str =
    "a moderation or administration record about what staff did, not the member's own data";
const CREDENTIAL: &str = "a credential, session or security record, never part of a data export";
const DERIVED: &str = "derived or transient state that is rebuilt, not content the member made";
const CANVAS: &str =
    "canvas contributions are not in the first format and are listed under not_included";
const SPACE_RECORD: &str = "a space-level record the member merely appears in";
const SOMEONE_ELSE: &str = "belongs to somebody else or to a conversation, so exporting it would hand over another person's data";

const DECISIONS: &[(&str, &str, Fate)] = &[
    ("access_tokens", "user_id", Fate::Excluded(CREDENTIAL)),
    ("admin_audit_log", "actor_id", Fate::Excluded(STAFF_RECORD)),
    ("app_surfaces", "created_by", Fate::Excluded(BOT_CONFIG)),
    (
        "attachment_uploaders",
        "uploaded_by",
        Fate::Exported("attachments.jsonl"),
    ),
    (
        "bot_command_registrations",
        "bot_user_id",
        Fate::Excluded(BOT_CONFIG),
    ),
    ("bot_commands", "bot_user_id", Fate::Excluded(BOT_CONFIG)),
    ("bot_tokens", "bot_user_id", Fate::Excluded(BOT_CONFIG)),
    ("bot_tokens", "created_by", Fate::Excluded(BOT_CONFIG)),
    ("bot_ui_entries", "bot_user_id", Fate::Excluded(BOT_CONFIG)),
    ("call_records", "caller_id", Fate::Excluded(DERIVED)),
    ("canvas_audit_log", "actor_id", Fate::Excluded(CANVAS)),
    ("canvas_media_slots", "user_id", Fate::Excluded(CANVAS)),
    ("canvas_object_locks", "locked_by", Fate::Excluded(CANVAS)),
    ("canvas_objects", "author_id", Fate::Excluded(CANVAS)),
    ("canvas_ops", "actor_id", Fate::Excluded(CANVAS)),
    (
        "channel_notification_prefs",
        "user_id",
        Fate::Exported("settings.json"),
    ),
    ("channels", "room_owner_id", Fate::Excluded(SPACE_RECORD)),
    ("code_runs", "ran_by", Fate::Excluded(BOT_CONFIG)),
    ("custom_emoji", "uploader_id", Fate::Excluded(SPACE_RECORD)),
    (
        "data_exports",
        "user_id",
        Fate::Excluded("the export jobs themselves, not content"),
    ),
    ("devices", "user_id", Fate::Excluded(CREDENTIAL)),
    ("dm_channels", "user_a", Fate::Excluded(SOMEONE_ELSE)),
    ("dm_channels", "user_b", Fate::Excluded(SOMEONE_ELSE)),
    ("dm_hides", "user_id", Fate::Excluded(SOMEONE_ELSE)),
    (
        "installed_modules",
        "bot_user_id",
        Fate::Excluded(BOT_CONFIG),
    ),
    ("invite_redemptions", "user_id", Fate::Excluded(DERIVED)),
    ("invites", "created_by", Fate::Excluded(STAFF_RECORD)),
    (
        "link_states",
        "user_id",
        Fate::Excluded("a short-lived sign-in handshake, a credential"),
    ),
    (
        "linked_accounts",
        "user_id",
        Fate::Exported("linked_accounts.jsonl"),
    ),
    ("login_throttle", "user_id", Fate::Excluded(CREDENTIAL)),
    ("member_nicknames", "set_by", Fate::Excluded(STAFF_RECORD)),
    (
        "member_nicknames",
        "user_id",
        Fate::Exported("profile.json"),
    ),
    ("member_roles", "user_id", Fate::Exported("profile.json")),
    ("member_timeouts", "issued_by", Fate::Excluded(STAFF_RECORD)),
    ("member_timeouts", "user_id", Fate::Excluded(STAFF_RECORD)),
    (
        "message_forwards",
        "origin_author_id",
        Fate::Excluded(SOMEONE_ELSE),
    ),
    ("message_mentions", "user_id", Fate::Excluded(DERIVED)),
    ("message_ops", "actor_id", Fate::Excluded(STAFF_RECORD)),
    ("messages", "author_id", Fate::Exported("messages.jsonl")),
    (
        "moderation_audit_log",
        "actor_id",
        Fate::Excluded(STAFF_RECORD),
    ),
    (
        "moderation_audit_log",
        "subject_id",
        Fate::Excluded(STAFF_RECORD),
    ),
    (
        "notification_schedule_allowed_channels",
        "user_id",
        Fate::Exported("settings.json"),
    ),
    (
        "notification_schedule_allowed_users",
        "allowed_user_id",
        Fate::Excluded("somebody else's allow list that names the member"),
    ),
    (
        "notification_schedule_allowed_users",
        "user_id",
        Fate::Exported("settings.json"),
    ),
    (
        "notification_schedules",
        "user_id",
        Fate::Exported("settings.json"),
    ),
    (
        "password_reset_codes",
        "issued_by",
        Fate::Excluded(CREDENTIAL),
    ),
    (
        "password_reset_codes",
        "user_id",
        Fate::Excluded(CREDENTIAL),
    ),
    ("pending_members", "user_id", Fate::Excluded(DERIVED)),
    ("pinned_messages", "pinned_by", Fate::Excluded(SPACE_RECORD)),
    ("poll_votes", "user_id", Fate::Exported("poll_votes.jsonl")),
    ("polls", "created_by", Fate::Excluded(BOT_CONFIG)),
    ("reactions", "user_id", Fate::Exported("reactions.jsonl")),
    ("read_states", "user_id", Fate::Excluded(DERIVED)),
    ("reports", "reporter_id", Fate::Excluded(STAFF_RECORD)),
    ("reports", "resolved_by", Fate::Excluded(STAFF_RECORD)),
    (
        "reports",
        "snapshot_author_id",
        Fate::Excluded(STAFF_RECORD),
    ),
    ("roles", "managed_bot_id", Fate::Excluded(BOT_CONFIG)),
    ("saved_messages", "user_id", Fate::Exported("saved.jsonl")),
    ("sessions", "user_id", Fate::Excluded(CREDENTIAL)),
    ("space_removals", "removed_by", Fate::Excluded(STAFF_RECORD)),
    ("space_removals", "user_id", Fate::Excluded(STAFF_RECORD)),
    (
        "space_settings",
        "welcome_author_id",
        Fate::Excluded(SPACE_RECORD),
    ),
    ("totp_challenges", "user_id", Fate::Excluded(CREDENTIAL)),
    ("totp_recovery_codes", "user_id", Fate::Excluded(CREDENTIAL)),
    (
        "user_blocks",
        "blocked_id",
        Fate::Excluded("who blocked the member is the blocker's data, not theirs"),
    ),
    ("user_blocks", "blocker_id", Fate::Exported("blocks.jsonl")),
    ("user_notes", "author_id", Fate::Exported("notes.jsonl")),
    (
        "user_notes",
        "subject_id",
        Fate::Excluded("a note somebody else wrote about the member, theirs to keep"),
    ),
    ("user_totp_factors", "user_id", Fate::Excluded(CREDENTIAL)),
    (
        "username_collision_renames",
        "user_id",
        Fate::Excluded(CREDENTIAL),
    ),
    ("users", "id", Fate::Exported("profile.json")),
    (
        "voice_call_events",
        "user_id",
        Fate::Exported("call_events.jsonl"),
    ),
    (
        "voice_sessions",
        "user_id",
        Fate::Excluded("the same joins and leaves as call_events.jsonl, kept for modules"),
    ),
    ("watch_sessions", "bot_user_id", Fate::Excluded(BOT_CONFIG)),
    (
        "watch_sessions",
        "controller_user_id",
        Fate::Excluded(BOT_CONFIG),
    ),
    ("webhooks", "created_by", Fate::Excluded(BOT_CONFIG)),
    ("webhooks", "user_id", Fate::Excluded(BOT_CONFIG)),
    ("ws_tickets", "user_id", Fate::Excluded(CREDENTIAL)),
];

async fn user_references() -> Vec<(String, String)> {
    let (path, _guard) = support::TestDbGuard::new("slimm-export-coverage");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    let tables: Vec<String> = sqlx::query(
        "SELECT name FROM sqlite_master WHERE type = 'table' \
         AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_sqlx%' ORDER BY name",
    )
    .fetch_all(&pool)
    .await
    .expect("list tables")
    .into_iter()
    .map(|row| row.get::<String, _>("name"))
    .collect();
    let mut found = Vec::new();
    for table in tables {
        let fks = sqlx::query(&format!("PRAGMA foreign_key_list({table})"))
            .fetch_all(&pool)
            .await
            .expect("foreign keys");
        for fk in fks {
            if fk.get::<String, _>("table") == "users" {
                found.push((table.clone(), fk.get::<String, _>("from")));
            }
        }
    }
    found.push(("users".to_owned(), "id".to_owned()));
    found.sort();
    found
}

#[tokio::test]
async fn every_user_reference_is_exported_or_excluded_on_purpose() {
    let found = user_references().await;
    let undecided: Vec<_> = found
        .iter()
        .filter(|(t, c)| !DECISIONS.iter().any(|(dt, dc, _)| dt == t && dc == c))
        .collect();
    assert!(
        undecided.is_empty(),
        "these columns point at a user and a member's export neither carries \
         nor excludes them on purpose: {undecided:?}\nAdd an entry to DECISIONS."
    );
    let stale: Vec<_> = DECISIONS
        .iter()
        .filter(|(t, c, _)| !found.iter().any(|(ft, fc)| ft == t && fc == c))
        .map(|(t, c, _)| format!("{t}.{c}"))
        .collect();
    assert!(
        stale.is_empty(),
        "decisions about columns that are gone: {stale:?}"
    );
}

#[tokio::test]
async fn every_exported_file_is_really_in_the_archive() {
    let (store, _guard) = support::new_store("slimm-export-coverage-files").await;
    let w = world(store.clone());
    let (alice, _) = account(&store, "alice").await;
    let archive = w.archive(&alice, "member").await;

    let missing: Vec<_> = DECISIONS
        .iter()
        .filter_map(|(t, c, fate)| match fate {
            Fate::Exported(file) if !archive.entries.contains_key(*file) => {
                Some(format!("{t}.{c} -> {file}"))
            }
            _ => None,
        })
        .collect();

    assert!(
        missing.is_empty(),
        "named files the archive does not hold: {missing:?}"
    );
}

#[test]
fn every_exclusion_gives_a_reason() {
    for (table, column, fate) in DECISIONS {
        if let Fate::Excluded(reason) = fate {
            assert!(reason.len() > 12, "{table}.{column} has no real reason");
        }
    }
}
