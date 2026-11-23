// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Call history, transcripts and voice notification calls over seeded voice state.

use serde_json::json;

use crate::response_contract::world::Contract;

use super::voice_session_calls::voice_session_calls;

pub(super) async fn voice_history_calls(
    c: &mut Contract,
    root: &str,
    channel: &str,
    admin_id: &str,
) {
    // A call in the history, so the shape checked is a populated one.
    let voice_channel = slimm_server::ids::ChannelId(channel.parse().unwrap());
    let caller = slimm_server::ids::UserId(admin_id.parse().unwrap());
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_millis() as i64;
    for (at, kind) in [
        (now - 2000, slimm_server::store::VoiceEventKind::Joined),
        (now - 1000, slimm_server::store::VoiceEventKind::Left),
    ] {
        c.state
            .store
            .record_voice_event(voice_channel, caller, kind, at)
            .await
            .unwrap();
    }
    c.get(
        "listVoiceCalls",
        &format!("/channels/{channel}/voice/calls"),
        root,
    )
    .await;
    let call_audio_channel = c
        .state
        .store
        .create_channel("call-audio", "voice")
        .await
        .unwrap();
    c.get(
        "getVoiceCallAudio",
        &format!("/channels/{}/voice/call-audio", call_audio_channel.id),
        root,
    )
    .await;
    let transcript = slimm_server::ids::CallTranscriptId::generate();
    c.state
        .store
        .begin_call_transcript(&slimm_server::store::NewTranscript {
            id: transcript,
            channel_id: call_audio_channel.id,
            started_at: now - 5000,
            mode: slimm_server::store::TranscriptionMode::Always,
            started_by: None,
        })
        .await
        .unwrap();
    c.state
        .store
        .append_call_transcript_line(
            transcript,
            &slimm_server::store::NewTranscriptLine {
                speaker: caller,
                at: now - 4000,
                end_at: Some(now - 3000),
                language: Some("en"),
                text: "hello transcript",
            },
        )
        .await
        .unwrap();
    c.get(
        "getVoiceTranscript",
        &format!("/voice/transcripts/{transcript}"),
        root,
    )
    .await;
    // Only a Space that transcribes has numbers to show, so the shape is checked populated.
    let off = slimm_server::store::TranscriptionMode::Off;
    c.state
        .store
        .set_call_transcription(slimm_server::store::TranscriptionMode::Always)
        .await
        .unwrap();
    c.get("getMyCallStats", "/me/call-stats?days=30&tz=UTC", root)
        .await;
    c.state.store.set_call_transcription(off).await.unwrap();
    c.get(
        "searchVoiceTranscripts",
        "/search/transcripts?q=hello",
        root,
    )
    .await;
    c.get(
        "getVoiceTranscriptionNotice",
        "/voice/transcription-notice",
        root,
    )
    .await;
    c.bare(
        "acknowledgeVoiceTranscriptionNotice",
        "POST",
        "/voice/transcription-notice/ack",
        root,
    )
    .await;
    // A transcript still being written cannot be deleted, so the call ends first.
    c.state
        .store
        .end_call_transcript(transcript, now - 2000)
        .await
        .unwrap();
    c.bare(
        "deleteVoiceTranscript",
        "DELETE",
        &format!("/voice/transcripts/{transcript}"),
        root,
    )
    .await;
    c.json(
        "setVoiceNotification",
        "PUT",
        &format!("/voice-notifications/channels/{}", call_audio_channel.id),
        root,
        json!({ "joins": "first", "streams": true }),
    )
    .await;
    c.get(
        "listVoiceNotifications",
        "/voice-notifications/channels",
        root,
    )
    .await;
    voice_session_calls(c, root, call_audio_channel.id).await;
}
