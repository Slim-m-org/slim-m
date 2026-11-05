// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Waking a backgrounded device because a call started, grew or went live in a voice channel
//! its owner asked to hear about (decision 0107).
//!
//! The audience, the time limit and every exclusion are settled before this runs; this only
//! seals and sends. The relay is told the coarse `message` kind it already knows, since an
//! unknown kind is refused, and the sealed envelope says what actually happened.

use std::sync::Arc;

use serde::Serialize;

use crate::ids::{ChannelId, UserId};
use crate::store::{Store, now_ms};
use crate::voice_notify::Activity;

use super::deliver::is_foreground_and_recent;
use super::envelope::{DOMAIN, ENVELOPE_VERSION, MAX_PREVIEW_NAME_CHARS, PushKind, truncate};
use super::sealing::{TokenSlot, seal_to};
use super::{Enabled, dispatch};

/// What happened and to whom to tell it.
pub struct VoiceNotice {
    pub channel_id: ChannelId,
    pub actor_id: UserId,
    pub activity: Activity,
    pub recipients: Vec<UserId>,
}

/// The sealed plaintext. Names ride only to devices that asked for message content.
#[derive(Serialize)]
struct VoiceNoticeEnvelope<'a> {
    domain: &'static str,
    version: u8,
    kind: PushKind,
    channel_id: String,
    actor_id: String,
    activity: &'static str,
    sent_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    actor_name: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    channel_name: Option<&'a str>,
}

pub(super) async fn deliver(enabled: Arc<Enabled>, store: Store, notice: VoiceNotice) {
    let targets = match store.push_targets(&notice.recipients).await {
        Ok(targets) => targets,
        Err(err) => {
            tracing::warn!(error = %err, "push: failed to load a voice notice's push targets");
            return;
        }
    };
    let now = now_ms();
    // A foreground app already has the live frame.
    let targets: Vec<_> = targets
        .into_iter()
        .filter(|target| !is_foreground_and_recent(target, now))
        .collect();
    if targets.is_empty() {
        return;
    }
    let (actor_name, channel_name) = names(&store, &notice).await;
    let encode = |named: bool| {
        serde_json::to_vec(&VoiceNoticeEnvelope {
            domain: DOMAIN,
            version: ENVELOPE_VERSION,
            kind: PushKind::Voice,
            channel_id: notice.channel_id.to_string(),
            actor_id: notice.actor_id.to_string(),
            activity: notice.activity.as_str(),
            sent_at: now_ms(),
            actor_name: actor_name.as_deref().filter(|_| named),
            channel_name: channel_name.as_deref().filter(|_| named),
        })
    };
    let (Ok(bare), Ok(named)) = (encode(false), encode(true)) else {
        tracing::error!("push: voice notice envelope failed to serialize");
        return;
    };
    let messages: Vec<_> = targets
        .iter()
        .filter_map(|target| {
            let plaintext = if target.include_content {
                &named
            } else {
                &bare
            };
            seal_to(target, TokenSlot::Push, PushKind::Voice, plaintext)
        })
        .collect();
    dispatch::send_and_prune(&enabled, &store, &messages, "voice notice").await;
}

async fn names(store: &Store, notice: &VoiceNotice) -> (Option<String>, Option<String>) {
    let actor = match store.user_profile(notice.actor_id).await {
        Ok(profile) => profile.map(|p| truncate(&p.display_name, MAX_PREVIEW_NAME_CHARS, false)),
        Err(err) => {
            tracing::warn!(error = %err, "push: failed to resolve a voice notice's actor");
            None
        }
    };
    let channel = match store.channel(notice.channel_id).await {
        Ok(channel) => channel.map(|c| truncate(&c.name, MAX_PREVIEW_NAME_CHARS, false)),
        Err(err) => {
            tracing::warn!(error = %err, "push: failed to resolve a voice notice's channel");
            None
        }
    };
    (actor, channel)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_bare_envelope_carries_ids_and_the_activity_but_no_names() {
        let envelope = VoiceNoticeEnvelope {
            domain: DOMAIN,
            version: ENVELOPE_VERSION,
            kind: PushKind::Voice,
            channel_id: ChannelId::generate().to_string(),
            actor_id: UserId::generate().to_string(),
            activity: Activity::CallStarted.as_str(),
            sent_at: i64::MAX,
            actor_name: None,
            channel_name: None,
        };
        let value = serde_json::to_value(&envelope).expect("serializes");
        assert_eq!(value["kind"], "voice");
        assert_eq!(value["activity"], "call_started");
        assert!(value.get("actor_name").is_none() && value.get("channel_name").is_none());
        assert!(
            serde_json::to_vec(&envelope).expect("serializes").len()
                <= super::super::envelope::MAX_ENVELOPE_PLAINTEXT_BYTES
        );
    }
}
