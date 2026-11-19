// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! MANAGE_ROLES and MANAGE_SERVER stop at a channel their holder cannot see:
//! its overwrites and its retention answer like those of no channel at all, so
//! a manager outside a private channel cannot read who is in it, shut a member
//! out of it, or count and prune its messages.

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;

use crate::support;
use support::app::{TestApp, register_account};

struct World {
    app: TestApp,
    hidden: String,
    /// Somebody the admin let into the private channel.
    insider: support::app::Account,
}

/// `member` holds `powers` and nothing else beyond `@everyone`, and cannot see `hidden`.
async fn world(prefix: &str, powers: Permissions) -> World {
    let app = TestApp::start(prefix).await;
    let role = app.create_role("managers", powers.bits()).await;
    let grant = format!("/members/{}/roles/{role}", app.member.id);
    let (status, body) = app.call("PUT", &grant, &app.admin.token, None).await;
    assert!(status.is_success(), "grant: {status} {body}");

    let private = json!({"name": "staff", "restricted": true});
    let (_, channel) = app
        .call("POST", "/channels", &app.admin.token, Some(private))
        .await;
    let hidden = channel["id"]
        .as_str()
        .expect("a private channel")
        .to_owned();
    let insider = register_account(&app.store, "insider").await;
    let let_in = json!({"allow": Permissions::VIEW_CHANNEL.bits()});
    let uri = format!("/channels/{hidden}/overwrites/member/{}", insider.id);
    let (status, body) = app.call("PUT", &uri, &app.admin.token, Some(let_in)).await;
    assert!(status.is_success(), "let the insider in: {status} {body}");
    World {
        app,
        hidden,
        insider,
    }
}

/// The same request against the hidden channel and against an id that names nothing.
async fn both(
    world: &World,
    method: &str,
    tail: &str,
    body: Option<Value>,
) -> [(StatusCode, Value); 2] {
    let token = &world.app.member.token;
    let nowhere = uuid::Uuid::now_v7();
    let hidden = format!("/channels/{}{tail}", world.hidden);
    let unknown = format!("/channels/{nowhere}{tail}");
    [
        world.app.call(method, &hidden, token, body.clone()).await,
        world.app.call(method, &unknown, token, body).await,
    ]
}

#[tokio::test]
async fn a_role_manager_cannot_read_or_write_the_overwrites_of_a_channel_they_cannot_see() {
    let world = world("slimm-overwrites-hidden", Permissions::MANAGE_ROLES).await;
    let shut_out = json!({"deny": Permissions::VIEW_CHANNEL.bits()});
    let one = format!("/overwrites/member/{}", world.insider.id);
    let batch = json!({"overwrites": [{"kind": "member", "id": world.insider.id.to_string(),
                                       "deny": Permissions::VIEW_CHANNEL.bits()}]});
    let attempts = [
        ("GET", "/overwrites".to_owned(), None),
        ("PUT", one.clone(), Some(shut_out)),
        ("DELETE", one, None),
        ("PUT", "/overwrites".to_owned(), Some(batch)),
        ("POST", "/overwrites/sync".to_owned(), None),
    ];
    for (method, tail, body) in attempts {
        let [hidden, unknown] = both(&world, method, &tail, body).await;
        assert_eq!(
            hidden.0,
            StatusCode::FORBIDDEN,
            "{method} {tail}: {}",
            hidden.1
        );
        assert_eq!(hidden, unknown, "{method} {tail}");
    }

    let uri = format!("/channels/{}/messages", world.hidden);
    let (status, _) = world
        .app
        .call("GET", &uri, &world.insider.token, None)
        .await;
    assert_eq!(status, StatusCode::OK, "the insider is still in");
}

#[tokio::test]
async fn a_server_manager_cannot_read_or_set_the_retention_of_a_channel_they_cannot_see() {
    let world = world("slimm-retention-hidden", Permissions::MANAGE_SERVER).await;
    let attempts = [
        ("GET", "/retention", None),
        ("GET", "/retention/preview?days=0", None),
        ("PUT", "/retention", Some(json!({"retention_days": 1}))),
    ];
    for (method, tail, body) in attempts {
        let [hidden, unknown] = both(&world, method, tail, body).await;
        assert_eq!(
            hidden.0,
            StatusCode::NOT_FOUND,
            "{method} {tail}: {}",
            hidden.1
        );
        assert_eq!(hidden, unknown, "{method} {tail}");
    }

    let uri = format!("/channels/{}/retention", world.hidden);
    let (_, kept) = world
        .app
        .call("GET", &uri, &world.app.admin.token, None)
        .await;
    assert_eq!(kept["retention_days"], Value::Null, "nothing was set");
}
