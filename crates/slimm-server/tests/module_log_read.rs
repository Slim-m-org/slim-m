// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `log.read` (decision 0091) through the real command route: only an approved
//! module reads, only closed voice sessions come back, and a cursor catches up
//! exactly once. Each wasm fixture drives `slim.host_call` for real.

use serde_json::{Value, json};
use slimm_server::permissions::Permissions;
use slimm_server::store::SessionScope;

mod support;
use support::module_world::{Install, World, world};
use support::wasm_fixtures::host_call_loop_wasm;

fn read_request(log: &str, after: i64, limit: i64) -> String {
    json!({ "capability": "log.read", "log": log, "after": after, "limit": limit }).to_string()
}

/// Installs a module that makes one `log.read` and returns the host's reply.
async fn read(w: &World, approved: &[&str], request: &str) -> Value {
    w.install(Install {
        id: "reader",
        wasm: host_call_loop_wasm(request, 1),
        declared: &["kv.store", "log.read"],
        approved_host: approved,
    })
    .await;
    w.store.ensure_module_bot("reader", "Reader").await.unwrap();
    let answer = w.answer("reader").await;
    serde_json::from_str(&answer.replace('\'', "\"")).unwrap_or_else(|_| json!(answer))
}

fn ids(reply: &Value) -> Vec<i64> {
    reply["rows"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r["id"].as_i64().unwrap())
        .collect()
}

struct Calls {
    w: World,
    channel: slimm_server::ids::ChannelId,
    other: slimm_server::ids::UserId,
    opened: std::cell::Cell<i64>,
}

async fn calls(prefix: &str) -> Calls {
    let w = world(prefix).await;
    let channel = w.store.create_channel("voice", "voice").await.unwrap().id;
    let other = w.store.create_user("kiki", "Kiki").await.unwrap().id;
    let opened = std::cell::Cell::new(0);
    Calls {
        w,
        channel,
        other,
        opened,
    }
}

impl Calls {
    /// Opens a session at 1s, closes it at `closed_at` if given; returns its id
    /// (ids are handed out in order, starting at 1).
    async fn session(&self, sid: &str, by_other: bool, closed_at: Option<i64>) -> i64 {
        self.session_in(self.channel, sid, by_other, closed_at)
            .await
    }

    async fn session_in(
        &self,
        channel: slimm_server::ids::ChannelId,
        sid: &str,
        by_other: bool,
        closed_at: Option<i64>,
    ) -> i64 {
        let user = if by_other { self.other } else { self.w.user.id };
        let s = &self.w.store;
        s.open_voice_session(channel, user, sid, 1_000)
            .await
            .unwrap();
        if let Some(at) = closed_at {
            s.close_voice_sessions(SessionScope::Sid(user, sid), at)
                .await
                .unwrap();
        }
        self.opened.set(self.opened.get() + 1);
        self.opened.get()
    }
}

#[tokio::test]
async fn it_returns_closed_sessions_in_id_order_and_never_an_open_one() {
    let c = calls("slimm-logread-order").await;
    let first = c.session("a", false, Some(2_000)).await;
    let second = c.session("b", true, Some(3_500)).await;
    c.session("c", false, None).await;

    let reply = read(&c.w, &["log.read"], &read_request("voice.sessions", 0, 100)).await;
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(ids(&reply), vec![first, second]);
    assert_eq!(reply["next"], second);
    let row = &reply["rows"][0];
    assert_eq!(row["joined_at_ms"], 1_000);
    assert_eq!(row["left_at_ms"], 2_000);
    assert_eq!(row["alone_ms"], 1_000);
    assert_eq!(row["user_id"], c.w.user.id.to_string());
    assert_eq!(row["channel_id"], c.channel.to_string());
}

#[tokio::test]
async fn the_cursor_catches_up_exactly_once() {
    let c = calls("slimm-logread-cursor").await;
    let first = c.session("a", false, Some(2_000)).await;

    let reply = read(&c.w, &["log.read"], &read_request("voice.sessions", 0, 100)).await;
    assert_eq!(ids(&reply), vec![first]);
    let next = reply["next"].as_i64().unwrap();

    let again = read(
        &c.w,
        &["log.read"],
        &read_request("voice.sessions", next, 100),
    )
    .await;
    assert!(ids(&again).is_empty());
    assert_eq!(again["next"], next, "an empty read leaves the cursor alone");

    let later = c.session("b", true, Some(5_000)).await;
    let reply = read(
        &c.w,
        &["log.read"],
        &read_request("voice.sessions", next, 100),
    )
    .await;
    assert_eq!(ids(&reply), vec![later], "only what is new, once");
}

#[tokio::test]
async fn a_session_closing_late_is_not_skipped_by_a_cursor_past_a_later_one() {
    let c = calls("slimm-logread-late").await;
    c.session("slow", false, None).await;
    let quick = c.session("quick", true, Some(2_000)).await;

    let held = read(&c.w, &["log.read"], &read_request("voice.sessions", 0, 100)).await;
    assert!(
        ids(&held).is_empty(),
        "nothing after an open session is handed out yet"
    );

    c.w.store
        .close_voice_sessions(SessionScope::Sid(c.w.user.id, "slow"), 3_000)
        .await
        .unwrap();
    let released = read(&c.w, &["log.read"], &read_request("voice.sessions", 0, 100)).await;
    assert_eq!(ids(&released).len(), 2);
    assert_eq!(ids(&released)[1], quick);
}

#[tokio::test]
async fn it_honours_the_limit() {
    let c = calls("slimm-logread-limit").await;
    c.session("a", false, Some(2_000)).await;
    c.session("b", true, Some(2_000)).await;
    c.session("c", false, Some(2_000)).await;
    let reply = read(&c.w, &["log.read"], &read_request("voice.sessions", 0, 2)).await;
    assert_eq!(ids(&reply).len(), 2);
}

#[tokio::test]
async fn a_module_without_approval_is_refused() {
    let c = calls("slimm-logread-unapproved").await;
    let reply = read(&c.w, &["kv.store"], &read_request("voice.sessions", 0, 10)).await;
    assert_eq!(
        reply,
        json!({ "ok": false, "error": "capability not approved: log.read" })
    );
}

#[tokio::test]
async fn an_unknown_log_is_refused_cleanly() {
    let c = calls("slimm-logread-unknown").await;
    let reply = read(&c.w, &["log.read"], &read_request("messages", 0, 10)).await;
    assert_eq!(
        reply,
        json!({ "ok": false, "error": "unknown log: messages" })
    );
}

async fn hide_from_everyone(c: &Calls, channel: slimm_server::ids::ChannelId) {
    c.w.store
        .set_role_overwrite(
            channel,
            c.w.everyone,
            Permissions::NONE,
            Permissions::VIEW_CHANNEL,
        )
        .await
        .unwrap();
}

#[tokio::test]
async fn a_private_channels_sessions_are_never_returned_and_never_block_the_cursor() {
    let c = calls("slimm-logread-private").await;
    let secret =
        c.w.store
            .create_channel("secret", "voice")
            .await
            .unwrap()
            .id;
    hide_from_everyone(&c, secret).await;
    let hidden = c.session_in(secret, "h", false, Some(2_000)).await;
    let shown = c.session("s", true, Some(2_500)).await;
    let hidden_last = c.session_in(secret, "h2", true, Some(3_000)).await;

    let reply = read(&c.w, &["log.read"], &read_request("voice.sessions", 0, 100)).await;
    assert_eq!(ids(&reply), vec![shown]);
    assert_eq!(
        reply["next"], hidden_last,
        "the cursor passes the hidden tail"
    );

    let only_hidden = read(&c.w, &["log.read"], &read_request("voice.sessions", 0, 1)).await;
    assert!(ids(&only_hidden).is_empty(), "{only_hidden}");
    assert_eq!(
        only_hidden["next"], hidden,
        "a hidden row does not stall the reader"
    );
}

#[tokio::test]
async fn a_channel_that_turns_private_is_excluded_on_the_next_read() {
    let c = calls("slimm-logread-turns-private").await;
    let id = c.session("a", false, Some(2_000)).await;
    let before = read(&c.w, &["log.read"], &read_request("voice.sessions", 0, 100)).await;
    assert_eq!(ids(&before), vec![id]);

    hide_from_everyone(&c, c.channel).await;
    let after = read(&c.w, &["log.read"], &read_request("voice.sessions", 0, 100)).await;
    assert!(ids(&after).is_empty(), "{after}");
    assert_eq!(after["next"], id);
}
