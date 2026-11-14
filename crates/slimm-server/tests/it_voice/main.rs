// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Integration tests for calls, voice tokens, call audio and transcripts: one module per former test file.

#[path = "../support/mod.rs"]
mod support;

mod block_evicts_shared_call;
mod call_audio;
mod call_audio_privacy;
mod call_records;
mod call_transcripts;
mod call_transcripts_export;
mod call_transcripts_migration;
mod call_transcripts_read;
mod delete_channel_ends_call;
mod hold_music_account;
mod incoming_rings;
mod member_moderation_evicts_dm_calls;
mod screen_share_cap;
mod soundboard;
mod soundboard_migration;
mod strong_noise_suppression;
mod uplink_test;
mod voice;
mod voice_call_history;
mod voice_deafened;
mod voice_dm;
mod voice_forget_heartbeat;
mod voice_heartbeat;
mod voice_kick_escalation;
mod voice_move;
mod voice_notify;
mod voice_notify_prefs;
mod voice_rooms;
mod voice_roster;
mod voice_sessions;
mod voice_sweep;
mod voice_visibility_cache;
mod watch_direct_play;
mod watch_session;
mod watch_session_call;
