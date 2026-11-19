// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The deployment the sweeps run against: everything private in it carries a canary word.

use serde_json::{Value, json};
use slimm_server::ids::{ChannelId, MessageId};
use slimm_server::permissions::Permissions;
use slimm_server::store::{InstallModuleRequest, ModuleRuntimeLimits, NewMessage};
use uuid::Uuid;

use crate::support::app::{Account, TestApp, register_account};
use crate::support::wasm_fixtures::{canned_ok_wasm, sha256_hex};

/// The installed module every `{moduleId}` route is asked about.
pub const MODULE: &str = "sweeper";

/// One word per private thing, each findable by somebody allowed to read it.
pub const CANARIES: &[&str] = &[
    "canarycat",
    "canarychan",
    "canarytopic",
    "canarymsg",
    "canaryreply",
    "canaryvoice",
    "canarydm",
    "canarygroup",
    "canaryhook",
];

pub struct Private {
    /// Ids nobody outside may be handed unless they named them first.
    pub ids: Vec<String>,
    pub channels: Vec<String>,
    /// One message per entry of `channels`, in the same order.
    pub messages: Vec<String>,
    pub category: String,
    pub users: Vec<String>,
    /// The webhook that posts in the private text channel.
    pub webhook: String,
    voice: ChannelId,
}

impl Private {
    /// Puts [`MODULE`] back as [`build`] left it: installed, approved to schedule and to hear
    /// calls, and armed for the private voice channel, whatever a swept route did to it since.
    pub async fn keep_the_module(&self, app: &TestApp) {
        let store = &app.store;
        let wasm = canned_ok_wasm("ok");
        let approved = ["schedule", "message.post", "call.audio"].map(str::to_owned);
        if store.installed_module(MODULE).await.unwrap().is_none() {
            let request = InstallModuleRequest {
                id: MODULE,
                name: "Sweeper",
                version: "0.1.0",
                artifact_sha256: &sha256_hex(&wasm),
                approved_capabilities: &approved,
                runtime_limits: &ModuleRuntimeLimits::default(),
                permissions: &[],
                extension_points: &[],
            };
            let installed = store.install_module_with_artifact(request, &wasm).await;
            installed.expect("install the module");
        }
        let host = store.set_module_host_capabilities(MODULE, &approved).await;
        host.expect("approve the module");
        let bot = store.ensure_module_bot(MODULE, "Sweeper").await.unwrap();
        let (view, none) = (Permissions::VIEW_CHANNEL, Permissions::NONE);
        let seen = store
            .set_member_overwrite(self.voice, bot, view, none)
            .await;
        seen.expect("let the module see the voice channel");
        let hears = [self.voice];
        let armed = store.set_module_call_audio_channels(MODULE, &hears);
        armed.await.expect("arm the module");
    }
}

/// A file in `channel`, so the storage report has a row for it.
async fn attach(app: &TestApp, channel: &str) {
    let channel = ChannelId(channel.parse().expect("a channel id"));
    let (store, by) = (&app.store, Some(app.admin.id));
    let stored = store.store_attachment(&[9; 32], 1_000, "image/png", "a.png", by);
    stored.await.expect("store the file");
    let message = NewMessage {
        attachment_ids: &[[9; 32].to_vec()],
        spoiler_ids: &[],
        ..NewMessage::plain(channel, app.admin.id, MessageId::generate(), "a file")
    };
    app.store
        .send_message(message)
        .await
        .expect("attach the file");
}

pub async fn ok(app: &TestApp, method: &str, uri: &str, token: &str, body: Value) -> Value {
    let (status, answer) = app.call(method, uri, token, Some(body)).await;
    assert!(status.is_success(), "{method} {uri}: {status} {answer}");
    answer
}

pub async fn say(app: &TestApp, token: &str, channel: &str, content: &str) -> String {
    let id = Uuid::now_v7().to_string();
    let uri = format!("/channels/{channel}/messages");
    ok(
        app,
        "POST",
        &uri,
        token,
        json!({"id": id, "content": content}),
    )
    .await;
    id
}

fn id_of(answer: &Value, field: &str) -> String {
    answer[field].as_str().expect("an id").to_owned()
}

async fn everyone_role(app: &TestApp) -> String {
    let (_, roles) = app.call("GET", "/roles", &app.admin.token, None).await;
    let roles = roles.as_array().expect("roles");
    let everyone = roles.iter().find(|role| role["is_everyone"] == true);
    id_of(everyone.expect("@everyone"), "id")
}

/// What somebody does in a channel while they can still see it, before they are shut out again.
async fn leave_traces(app: &TestApp, who: &Account, channel: &str, thread: &str, message: &str) {
    let token = &who.token;
    let grant = format!("/channels/{channel}/overwrites/member/{}", who.id);
    let view = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
    let allow = json!({"allow": view.bits()});
    ok(app, "PUT", &grant, &app.admin.token, allow).await;
    ok(
        app,
        "PUT",
        &format!("/messages/{message}/save"),
        token,
        json!({}),
    )
    .await;
    let react = format!("/messages/{message}/reactions/%F0%9F%91%8D");
    ok(app, "PUT", &react, token, json!({})).await;
    say(app, token, channel, "canarymsg from the one who left").await;
    say(app, token, thread, "canaryreply from the one who left").await;
    let read = format!("/channels/{channel}/read");
    ok(app, "PUT", &read, token, json!({"seq": 1})).await;
    let (status, _) = app.call("DELETE", &grant, &app.admin.token, None).await;
    assert!(status.is_success(), "take the grant back: {status}");
}

/// A private category with a text channel synced to it, a private voice channel, a thread, a
/// webhook, a file, a direct message and a group, none of them `member`'s, and a module armed
/// to hear the voice channel. `former` is let into the text channel and its thread for a while first.
pub async fn build(app: &TestApp, former: Option<&Account>) -> Private {
    let admin = &app.admin.token;
    let carol = register_account(&app.store, "carol").await;
    let dave = register_account(&app.store, "dave").await;

    let named = json!({"name": "canarycat"});
    let category = id_of(&ok(app, "POST", "/categories", admin, named).await, "id");
    let deny = Permissions::VIEW_CHANNEL.bits();
    let rows =
        json!({"overwrites": [{"kind": "role", "id": everyone_role(app).await, "deny": deny}]});
    let uri = format!("/categories/{category}/overwrites");
    ok(app, "PUT", &uri, admin, rows).await;

    let synced = json!({"name": "canarychan", "category_id": category});
    let text = id_of(&ok(app, "POST", "/channels", admin, synced).await, "id");
    let topic = json!({"topic": "canarytopic"});
    ok(app, "PATCH", &format!("/channels/{text}"), admin, topic).await;
    let own = json!({"name": "canaryvoice", "kind": "voice", "restricted": true});
    let voice = id_of(&ok(app, "POST", "/channels", admin, own).await, "id");

    let mention = format!("canarymsg <@{}> @member", app.member.id);
    let message = say(app, admin, &text, &mention).await;
    let pin = format!("/channels/{text}/messages/{message}/pin");
    ok(app, "PUT", &pin, admin, json!({})).await;
    let react = format!("/messages/{message}/reactions/%F0%9F%91%8D");
    ok(app, "PUT", &react, admin, json!({})).await;
    ok(
        app,
        "PUT",
        &format!("/messages/{message}/save"),
        admin,
        json!({}),
    )
    .await;
    let open = format!("/channels/{text}/messages/{message}/thread");
    let thread = id_of(&ok(app, "POST", &open, admin, json!({})).await, "id");
    let reply = say(app, admin, &thread, "canaryreply").await;
    let hook = json!({"label": "canaryhook", "channel_id": text});
    let hook = ok(app, "POST", "/webhooks", admin, hook).await;
    let webhook = id_of(&hook["webhook"], "id");
    attach(app, &text).await;
    let spoken = say(app, admin, &voice, "canaryvoice said").await;
    if let Some(former) = former {
        leave_traces(app, former, &text, &thread, &message).await;
    }

    let pair = format!("/dms/{}", carol.id);
    let dm = id_of(
        &ok(app, "POST", &pair, admin, json!({})).await,
        "channel_id",
    );
    let dm_message = say(app, admin, &dm, "canarydm").await;
    let people =
        json!({"user_ids": [carol.id.to_string(), dave.id.to_string()], "name": "canarygroup"});
    let group = id_of(
        &ok(app, "POST", "/dms/groups", admin, people).await,
        "channel_id",
    );
    let group_message = say(app, admin, &group, "canarygroup said").await;

    let voice_id = ChannelId(voice.parse().expect("a channel id"));
    let channels = vec![text, voice, thread, dm, group];
    let messages = vec![message, spoken, reply, dm_message, group_message];
    let mut ids = channels.clone();
    ids.extend(messages.iter().cloned());
    ids.extend([category.clone(), webhook.clone()]);
    let private = Private {
        ids,
        channels,
        messages,
        category,
        users: vec![app.admin.id.to_string(), carol.id.to_string()],
        webhook,
        voice: voice_id,
    };
    private.keep_the_module(app).await;
    private
}
