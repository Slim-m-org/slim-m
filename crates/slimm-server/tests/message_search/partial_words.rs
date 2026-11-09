// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A plain word in `q` finds whatever starts with it, in message text and in
//! attachment file names, on both search routes. A query written in FTS5
//! syntax keeps its exact meaning instead.

use axum::Router;
use axum::http::StatusCode;
use serde_json::Value;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;

use crate::fixtures::*;

const ISO: &str = "Win11_24H2_English_x64.iso";

struct Setup {
    app: Router,
    token: String,
    channel_id: String,
}

impl Setup {
    async fn new() -> (Self, crate::support::TestDbGuard) {
        let (store, guard) = new_store().await;
        store
            .create_role(
                "everyone",
                Permissions::VIEW_CHANNEL
                    .union(Permissions::SEND_MESSAGES)
                    .union(Permissions::ATTACH_FILES),
                true,
            )
            .await
            .unwrap();
        let channel = store.create_channel("chat", "text").await.unwrap();
        let app = app(store.clone());
        let token = register(&store, "alice").await;
        let setup = Self {
            app,
            token,
            channel_id: channel.id.to_string(),
        };
        (setup, guard)
    }

    async fn send(&self, content: &str) -> Value {
        send(&self.app, &self.channel_id, &self.token, content).await
    }

    /// The hits for `q` on the channel's own search and on the cross-channel
    /// search, which must agree.
    async fn hits(&self, q: &str) -> Vec<Value> {
        let q = q.replace(' ', "%20").replace('"', "%22");
        let channel = self
            .get(&format!(
                "/channels/{}/messages/search?q={q}",
                self.channel_id
            ))
            .await;
        let everywhere = self.get(&format!("/search/messages?q={q}")).await;
        assert_eq!(channel, everywhere, "q={q}");
        channel
    }

    async fn get(&self, uri: &str) -> Vec<Value> {
        let response = self
            .app
            .clone()
            .oneshot(request("GET", uri, Some(&self.token), None))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK, "{uri}");
        json_body(response).await.as_array().unwrap().clone()
    }

    async fn contents(&self, q: &str) -> Vec<String> {
        let mut found: Vec<String> = self
            .hits(q)
            .await
            .iter()
            .map(|m| m["content"].as_str().unwrap().to_owned())
            .collect();
        found.sort_unstable();
        found
    }
}

#[tokio::test]
async fn a_partial_word_finds_a_file_by_its_name() {
    let (setup, _guard) = Setup::new().await;
    let iso = upload_named(&setup.app, &setup.token, ISO).await;
    send_with_attachments(&setup.app, &setup.channel_id, &setup.token, "", &[&iso]).await;
    setup.send("unrelated words").await;

    for q in ["Win", "win11", "Eng", "english", "x6", "24h", "iso"] {
        let found = setup.hits(q).await;
        assert_eq!(found.len(), 1, "q={q}");
        assert_eq!(found[0]["matched_attachment_id"], iso.as_str(), "q={q}");
    }
    for q in ["Windows", "english64", "zzz"] {
        assert!(setup.hits(q).await.is_empty(), "q={q}");
    }
}

#[tokio::test]
async fn a_partial_word_finds_message_text() {
    let (setup, _guard) = Setup::new().await;
    setup.send("Windows is installed").await;
    setup.send("unrelated words").await;

    for q in ["Win", "Wind", "windows", "installed win"] {
        assert_eq!(setup.contents(q).await, ["Windows is installed"], "q={q}");
    }
    for q in ["Windowsx", "win unrelated"] {
        assert!(setup.hits(q).await.is_empty(), "q={q}");
    }
}

#[tokio::test]
async fn fts_syntax_keeps_its_exact_meaning() {
    let (setup, _guard) = Setup::new().await;
    setup.send("windows installer").await;
    setup.send("windows updates").await;
    setup.send("wind turbine").await;
    let all = ["wind turbine", "windows installer", "windows updates"];

    assert_eq!(setup.contents("wind*").await, all);
    assert!(setup.hits("\"win\"").await.is_empty());
    assert_eq!(setup.contents("\"wind\"").await, ["wind turbine"]);
    assert_eq!(
        setup.contents("windows NOT installer").await,
        ["windows updates"]
    );
    assert_eq!(setup.contents("windows OR turbine").await, all);
    assert!(setup.hits("turb OR upd").await.is_empty());
    assert_eq!(
        setup.contents("NEAR(windows installer)").await,
        ["windows installer"]
    );
}
