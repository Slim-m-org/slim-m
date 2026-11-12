// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Integration tests for the websocket, presence, typing and live fan-out: one module per former test file.

#[path = "../support/mod.rs"]
mod support;

mod account_sync_events;
mod blocking_live;
mod blocking_live_cache;
mod bulk_delete_events;
mod device_liveness;
mod dm_open_publishes_no_event;
mod live_channel_deleted_admin;
mod live_channel_events;
mod live_channel_restricted;
mod live_everyone_overwrite_events;
mod live_moderation_seq;
mod live_profile_events;
mod live_role_events;
mod live_thread_events;
mod live_voice_events;
mod live_voice_participant_events;
mod live_voice_screen_share_events;
mod me_presence_visibility;
mod member_joined_event;
mod member_restored_event;
mod pin_delete_events;
mod presence;
mod presence_active_frame;
mod presence_activity;
mod presence_departure_cost;
mod presence_device_kinds;
mod presence_reconnect;
mod read_state_devices;
mod read_state_sync;
mod reports_changed_ws;
mod space_settings_changed_event;
mod sync_message_ops;
mod typing;
mod typing_disconnect;
mod ws;
mod ws_call_frame_lookups;
mod ws_code_run_delivery;
mod ws_created_lookups;
mod ws_event_frame_pin;
mod ws_frame_contract;
mod ws_handshake;
mod ws_liveness;
mod ws_member_moderation_frames;
mod ws_message_created_enrichment;
mod ws_permission_cache;
mod ws_pin_visibility;
mod ws_session_lifecycle;
