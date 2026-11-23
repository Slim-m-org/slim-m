// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Host-run connectors (decision 0134) against a fake supervisor: what install, enable,
//! disable and uninstall ask of it, what the admin must approve, and where the token goes.

use axum::http::StatusCode;
use serde_json::{Value, json};

use super::harness::ID;
use super::host_run_world::{IMAGE, host_world};
use crate::support::app::call;

fn all_egress() -> Value {
    json!({"egress": [{"host": "api.example.com", "port": 443}, {"host": "jellyfin.lan", "port": 8096}], "egress_private": true})
}

#[tokio::test]
async fn without_a_supervisor_nothing_changes_and_a_host_run_install_says_why() {
    let w = host_world("slimm-hostrun-off", false, false).await;
    let (status, runtime) = w
        .as_owner("GET", "/space/dock/connector-runtime", None)
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(runtime, json!({"configured": false, "available": false}));
    let (status, body) = w.install(all_egress()).await;
    assert_eq!(status, StatusCode::NOT_IMPLEMENTED, "{body}");
    assert!(
        body["error"]
            .as_str()
            .unwrap()
            .contains("not set up to run connectors")
    );
    assert!(
        w.store.installed_module(ID).await.unwrap().is_none(),
        "nothing is installed"
    );
}

#[tokio::test]
async fn the_dock_shows_the_image_egress_and_limits_it_asks_for() {
    let w = host_world("slimm-hostrun-ask", true, true).await;
    let (_, shown) = w
        .as_owner("GET", &format!("/space/dock/modules/{ID}"), None)
        .await;
    let ask = &shown["connector"]["host_run"];
    assert_eq!(ask["image"], json!(IMAGE));
    assert_eq!(
        ask["egress"][1],
        json!({"host": "jellyfin.lan", "port": 8096})
    );
    assert_eq!(
        (ask["egress_private"].clone(), ask["volume"].clone()),
        (json!(true), json!(true))
    );
    assert_eq!(ask["limits"], json!({"memory_mib": 64, "pids": 32}));
    let (_, runtime) = w
        .as_owner("GET", "/space/dock/connector-runtime", None)
        .await;
    assert_eq!(
        (runtime["configured"].clone(), runtime["available"].clone()),
        (json!(true), json!(true)),
        "{runtime}"
    );
    assert_eq!(runtime["registries"], json!(["ghcr.io/slim-m-org/"]));
}

#[tokio::test]
async fn install_needs_an_approval_within_the_ask() {
    let w = host_world("slimm-hostrun-approve", true, true).await;
    let (status, body) = w.install(Value::Null).await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "an app that cannot show the ask cannot install: {body}"
    );
    let (status, _) = w
        .install(json!({"egress": [{"host": "evil.example.com", "port": 443}]}))
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = w
        .install(json!({"egress": [{"host": "api.example.com", "port": 80}]}))
        .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = w.install(json!({"egress": [], "privileged": true})).await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "unknown approval fields are refused"
    );
    assert!(w.fake.calls("create").is_empty());
}

#[tokio::test]
async fn install_creates_with_only_what_was_approved_and_never_shows_the_token() {
    let w = host_world("slimm-hostrun-create", true, true).await;
    let (status, installed) = w
        .install(json!({"egress": [{"host": "API.example.com", "port": 443}]}))
        .await;
    assert_eq!(status, StatusCode::OK, "{installed}");
    assert!(
        installed.get("connector_token").is_none(),
        "the host keeps the token: {installed}"
    );
    let creates = w.fake.calls("create");
    assert_eq!(creates.len(), 1);
    let (run_id, body) = &creates[0];
    assert_eq!(*run_id, w.run_id().await);
    assert_eq!(body["image"], json!(IMAGE));
    assert_eq!(
        body["egress"],
        json!([{"host": "api.example.com", "port": 443}])
    );
    assert_eq!(
        body["egress_private"],
        json!(false),
        "the Private network was not approved"
    );
    assert_eq!(body["volume"], json!(true));
    assert_eq!(body["limits"], json!({"memory_mib": 64, "pids": 32}));
    assert_eq!(body["env"]["SLIMM_API_URL"], json!("http://server:8080"));
    let keys: Vec<&String> = body["env"].as_object().unwrap().keys().collect();
    assert!(keys.iter().all(|k| k.starts_with("SLIMM_")), "{keys:?}");
    assert!(
        w.fake.calls("start").is_empty(),
        "a fresh install stays off until enabled"
    );
    let token = w.last_token();
    let (status, me) = call(&w.router, "GET", "/connectors/me", Some(&token), None).await;
    assert_eq!(
        status,
        StatusCode::CONFLICT,
        "the container's token is the connector's, disabled for now: {me}"
    );
}

#[tokio::test]
async fn enable_starts_and_disable_stops() {
    let w = host_world("slimm-hostrun-enable", true, true).await;
    let run_id = w.running().await;
    assert_eq!(w.fake.state(&run_id).as_deref(), Some("running"));
    assert_eq!(w.status().await["state"], json!("running"));
    let (status, me) = call(
        &w.router,
        "GET",
        "/connectors/me",
        Some(&w.last_token()),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{me}");
    let (status, _) = w
        .as_owner("POST", &format!("/space/dock/modules/{ID}/disable"), None)
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(w.fake.calls("stop").len(), 1);
    assert_eq!(w.status().await["state"], json!("stopped"));
}

#[tokio::test]
async fn uninstall_removes_the_container_and_the_volume_unless_kept() {
    for (delete_data, keep_volume) in [(false, true), (true, false)] {
        let w = host_world("slimm-hostrun-uninstall", true, true).await;
        let run_id = w.running().await;
        let token = w.last_token();
        let uri = format!("/space/dock/modules/{ID}/install?delete_data={delete_data}");
        let (status, body) = w.as_owner("DELETE", &uri, None).await;
        assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
        let removes = w.fake.calls("remove");
        let (id, body) = removes.last().unwrap();
        assert_eq!(
            (id.as_str(), body["keep_volume"].clone()),
            (run_id.as_str(), json!(keep_volume))
        );
        assert!(w.store.host_run(ID).await.unwrap().is_none());
        let (status, _) = call(&w.router, "GET", "/connectors/me", Some(&token), None).await;
        assert_eq!(
            status,
            StatusCode::UNAUTHORIZED,
            "uninstall revokes the token"
        );
    }
}

#[tokio::test]
async fn the_token_reissue_route_refuses_a_host_run_connector() {
    let w = host_world("slimm-hostrun-reissue", true, true).await;
    w.running().await;
    let (status, _) = w
        .as_owner(
            "POST",
            &format!("/space/dock/modules/{ID}/connector-token"),
            None,
        )
        .await;
    assert_eq!(status, StatusCode::CONFLICT);
}

#[tokio::test]
async fn the_token_is_stored_nowhere_in_plain_text() {
    let w = host_world("slimm-hostrun-nowhere", true, true).await;
    w.running().await;
    let token = w.last_token();
    let pool = &w.pool;
    let tables: Vec<String> =
        sqlx::query_scalar("SELECT name FROM sqlite_master WHERE type = 'table'")
            .fetch_all(pool)
            .await
            .unwrap();
    for table in tables {
        let rows: Vec<String> = sqlx::query_scalar(sqlx::AssertSqlSafe(format!(
            "SELECT CAST(json_array(*) AS TEXT) FROM (SELECT * FROM \"{table}\")"
        )))
        .fetch_all(pool)
        .await
        .unwrap_or_default();
        assert!(
            !rows.iter().any(|r| r.contains(&token)),
            "{table} holds the token"
        );
    }
}

#[tokio::test]
async fn admins_only_see_status_and_logs() {
    let w = host_world("slimm-hostrun-logs", true, true).await;
    w.running().await;
    let (status, logs) = w
        .as_owner(
            "GET",
            &format!("/space/dock/modules/{ID}/host-run/logs?tail=50"),
            None,
        )
        .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(logs["lines"][0]["text"], json!("connected"));
    let member = crate::support::app::register_account(&w.store, "member").await;
    for path in ["host-run", "host-run/logs"] {
        let (status, _) = call(
            &w.router,
            "GET",
            &format!("/space/dock/modules/{ID}/{path}"),
            Some(&member.token),
            None,
        )
        .await;
        assert_eq!(status, StatusCode::FORBIDDEN, "{path}");
    }
}

#[tokio::test]
async fn a_policy_refusal_shows_on_the_connector_and_is_not_retried() {
    let w = host_world("slimm-hostrun-policy", true, true).await;
    w.fake.with(|f| {
        f.refuse_create = Some((
            "policy".into(),
            "image is not under an allowed registry prefix".into(),
        ))
    });
    w.running().await;
    let status = w.status().await;
    assert_eq!(status["state"], json!("refused"), "{status}");
    assert!(
        status["last_error"]
            .as_str()
            .unwrap()
            .contains("allowed registry")
    );
    let creates = w.fake.calls("create").len();
    w.tick().await;
    w.tick().await;
    assert_eq!(
        w.fake.calls("create").len(),
        creates,
        "a policy answer is not retried"
    );
}
