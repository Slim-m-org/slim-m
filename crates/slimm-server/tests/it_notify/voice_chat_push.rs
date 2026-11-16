// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A voice channel's chat wakes a member with no choice of their own only for
//! a mention (decision 0049), and a lobby's chat wakes nobody (decision 0065).
//! The owner: "maybe it would be better if those chats were mention only".

use slimm_server::ids::{ChannelId, MessageId, UserId};
use slimm_server::notifications::NotificationPreference as Level;
use slimm_server::store::{ChannelPatch, NewMessage, PushRegistration, Store};

use crate::support;
use support::app::register_account;
use support::wake_recipients;

struct World {
    store: Store,
    author: UserId,
    member: UserId,
    text: ChannelId,
    voice: ChannelId,
    _guard: support::TestDbGuard,
}

async fn world(name: &str) -> World {
    let (store, guard) = support::new_store(name).await;
    let author = register_account(&store, "alice").await.id;
    let member = register_account(&store, "bob").await.id;
    let device = store.open_session(member, "phone").await.unwrap().device_id;
    let registration = PushRegistration {
        platform: "ios",
        push_token: "bob-token",
        voip_push_token: None,
        push_public_key: &[7u8; 32],
        include_content: Some(false),
        include_content_chosen: true,
    };
    store
        .register_push(member, device, registration)
        .await
        .unwrap();
    let text = store.list_channels().await.unwrap()[0].id;
    let voice = store.create_channel("hangout", "voice").await.unwrap().id;
    World {
        store,
        author,
        member,
        text,
        voice,
        _guard: guard,
    }
}

impl World {
    async fn wakes(&self, channel: ChannelId, text: &str) -> bool {
        wake_recipients(&self.store, channel, self.author, text)
            .await
            .unwrap()
            .contains(&self.member)
    }

    async fn own_choice(&self, channel: ChannelId, level: Level) {
        self.store
            .set_channel_notification_preference(self.member, channel, level)
            .await
            .unwrap();
    }

    async fn patch(&self, channel: ChannelId, patch: ChannelPatch<'_>) {
        self.store
            .update_channel_settings(channel, patch)
            .await
            .unwrap()
            .unwrap();
    }
}

#[tokio::test]
async fn a_voice_chat_wakes_a_member_only_for_a_mention() {
    let w = world("slimm-voice-chat-push-default").await;
    assert!(
        w.wakes(w.text, "plain").await,
        "a text channel is unchanged"
    );

    assert!(!w.wakes(w.voice, "plain").await);
    assert!(w.wakes(w.voice, "hey @bob").await);
}

#[tokio::test]
async fn a_members_own_choice_and_a_stricter_default_still_win() {
    let w = world("slimm-voice-chat-push-choices").await;
    w.own_choice(w.voice, Level::Everything).await;
    assert!(
        w.wakes(w.voice, "plain").await,
        "bob asked for every message"
    );

    w.store
        .clear_channel_notification_preference(w.member, w.voice)
        .await
        .unwrap();
    let muted = ChannelPatch {
        default_notification: Some(Level::Nothing),
        ..ChannelPatch::default()
    };
    w.patch(w.voice, muted).await;
    assert!(
        !w.wakes(w.voice, "hey @bob").await,
        "a muted default stands"
    );
}

#[tokio::test]
async fn a_thread_off_a_voice_chat_follows_it() {
    let w = world("slimm-voice-chat-push-thread").await;
    let root = w
        .store
        .send_message(NewMessage::plain(
            w.voice,
            w.member,
            MessageId::generate(),
            "root",
        ))
        .await
        .unwrap();
    let thread = w
        .store
        .open_thread(w.voice, root.message.id)
        .await
        .unwrap()
        .channel;

    assert!(!w.wakes(thread.id, "a reply").await);
    assert!(w.wakes(thread.id, "a reply for @bob").await);
}

#[tokio::test]
async fn a_lobby_chat_wakes_nobody_even_for_a_mention() {
    let w = world("slimm-voice-chat-push-lobby").await;
    let lobby = ChannelPatch {
        creates_rooms: Some(true),
        ..ChannelPatch::default()
    };
    w.patch(w.voice, lobby).await;
    w.own_choice(w.voice, Level::Everything).await;

    assert!(!w.wakes(w.voice, "plain").await);
    assert!(!w.wakes(w.voice, "hey @bob").await);
}
