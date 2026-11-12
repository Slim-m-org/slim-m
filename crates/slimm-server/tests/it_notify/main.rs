// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Integration tests for push, the relay contract, mentions and notification preferences: one module per former test file.

mod push_envelope_harness;
#[path = "../support/mod.rs"]
mod support;

mod bot_push_mentions;
mod channel_default_notification;
mod channel_notification_prefs;
mod channel_notification_prefs_http;
mod mention_audience;
mod mention_audience_cost;
mod mention_everyone;
mod notification_preference;
mod notification_schedule;
mod notification_schedule_migration;
mod push_active_elsewhere;
mod push_content_envelope;
mod push_endpoints;
mod push_envelope_fixture;
mod push_preview_account;
mod push_preview_migration;
mod push_preview_without_text;
mod push_relay_contract_fixture;
mod push_relay_forbidden;
mod push_store;
mod read_only_channel_push;
mod role_mentions;
mod thread_notification_override;
mod thread_push_mention_case;
mod thread_push_narrowing;
