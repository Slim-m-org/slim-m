// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Host-run connectors (decision 0134) against a fake supervisor: what install, enable,
//! disable and uninstall ask of it, what the admin must approve, and where the token goes.

use axum::http::StatusCode;
use serde_json::{Value, json};

use super::harness::ID;
use super::host_run_world::{HostWorld, IMAGE, host_world};
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
    assert_eq!(
        ask["limits"],
        json!({"memory_mib": 64, "pids": 32, "volume_mib": 64})
    );
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
    assert_eq!(
        body["limits"],
        json!({"memory_mib": 64, "pids": 32, "volume_mib": 64})
    );
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

/// L1: the docker host's own LAN address is private too, so the Private network waits for the deny list.
#[tokio::test]
async fn the_private_network_is_refused_while_the_operator_lists_no_host_address() {
    let w = host_world("slimm-hostrun-nodeny", true, true).await;
    w.fake.with(|f| {
        f.hello = Some(json!({"v": 1, "protocol": "supervisor/1", "version": "test", "runtime": "docker",
            "rootless": false, "ready": true, "problems": [], "registries": ["ghcr.io/slim-m-org/"],
            "ceilings": {"max_connectors": 8, "max_memory_mib": 512, "max_cpus": 1.0, "max_pids": 256},
            "private_network": false, "connectors": 0}));
    });
    w.tick().await;
    let (status, body) = w.install(all_egress()).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "{body}");
    assert!(
        body["error"]
            .as_str()
            .unwrap()
            .contains("SLIMM_SUPERVISOR_LAN_DENY"),
        "{body}"
    );
    let (status, body) = w
        .install(
            json!({"egress": [{"host": "api.example.com", "port": 443}], "egress_private": false}),
        )
        .await;
    assert_eq!(
        status,
        StatusCode::OK,
        "without the Private network it installs: {body}"
    );
}

/// L5: every call names this deployment, so a supervisor bound to another one refuses it.
#[tokio::test]
async fn every_supervisor_call_names_the_deployment() {
    let w = host_world("slimm-hostrun-deployment", true, true).await;
    w.running().await;
    let id = w.store.connector_deployment_id().await.unwrap();
    assert_eq!(id.len(), 32);
    assert_eq!(
        id,
        w.store.connector_deployment_id().await.unwrap(),
        "stable"
    );
    let named = w.fake.with(|f| f.deployments.clone());
    assert!(!named.is_empty());
    assert!(named.iter().all(|d| *d == id), "{named:?}");
}

#[tokio::test]
async fn deleting_the_data_waits_for_a_supervisor_that_cannot_remove_it() {
    let w = host_world("slimm-hostrun-uninstall-busy", true, true).await;
    let run_id = w.running().await;
    let uri = format!("/space/dock/modules/{ID}/install?delete_data=true");
    w.fake.with(|f| f.fail_remove = true);

    let (status, body) = w.as_owner("DELETE", &uri, None).await;

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "{body}");
    assert!(
        w.store.host_run(ID).await.unwrap().is_some(),
        "still installed"
    );
    let creates = w.fake.calls("create").len();
    slimm_server::http::connector_host::tick(&w.state).await;
    assert_eq!(
        w.fake.calls("create").len(),
        creates,
        "the monitor does not bring a connector back that is being deleted"
    );
    w.fake.with(|f| f.fail_remove = false);
    let (status, body) = w.as_owner("DELETE", &uri, None).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
    let removes = w.fake.calls("remove");
    let (id, last) = removes.last().unwrap();
    assert_eq!(
        (id.as_str(), last["keep_volume"].clone()),
        (run_id.as_str(), json!(false))
    );
}

#[tokio::test]
async fn keeping_the_data_uninstalls_even_when_the_container_will_not_go_yet() {
    let w = host_world("slimm-hostrun-uninstall-keep", true, true).await;
    w.running().await;
    w.fake.with(|f| f.fail_remove = true);
    let uri = format!("/space/dock/modules/{ID}/install?delete_data=false");

    let (status, body) = w.as_owner("DELETE", &uri, None).await;

    assert_eq!(status, StatusCode::NO_CONTENT, "{body}");
    assert!(w.store.host_run(ID).await.unwrap().is_none());
}

/// The Dock's next offer of the connector: `edit` changes the manifest it serves.
fn republish(w: &HostWorld, edit: impl FnOnce(&mut Value)) {
    let mut served = w.served.lock().unwrap();
    served["version"] = json!("0.2.0");
    edit(&mut served);
}

#[tokio::test]
async fn an_update_that_stops_asking_to_be_host_run_removes_the_container_and_the_volume() {
    let w = host_world("slimm-hostrun-update-forwarded", true, true).await;
    let run_id = w.running().await;
    let old_token = w.last_token();
    republish(&w, |doc| {
        doc["connector"].as_object_mut().unwrap().remove("host_run");
    });

    let (status, body) = w.install(json!(null)).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    let removes = w.fake.calls("remove");
    let (removed, last) = removes.last().unwrap();
    assert_eq!(
        (removed.as_str(), last["keep_volume"].clone()),
        (run_id.as_str(), json!(false)),
        "the volume has no run id left to be found by, so it goes too"
    );
    assert_eq!(w.fake.state(&run_id), None, "the container is gone");
    assert!(w.store.host_run(ID).await.unwrap().is_none());
    let (status, _) = call(&w.router, "GET", "/connectors/me", Some(&old_token), None).await;
    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "the removed container's token no longer works"
    );
    assert!(
        body["connector_token"].is_string(),
        "an admin-started connector is handed its token once: {body}"
    );
}

#[tokio::test]
async fn an_update_with_a_new_image_and_egress_replaces_the_container_with_what_was_approved() {
    let w = host_world("slimm-hostrun-update-changed", true, true).await;
    let run_id = w.running().await;
    let image = IMAGE.replace("0123456789abcdef", "fedcba9876543210");
    republish(&w, |doc| {
        let ask = &mut doc["connector"]["host_run"];
        ask["image"] = json!(image);
        ask["egress"] = json!([{"host": "api.example.com", "port": 443}]);
        ask["egress_private"] = json!(false);
    });

    let approval =
        json!({"egress": [{"host": "api.example.com", "port": 443}], "egress_private": false});
    let (status, body) = w.install(approval).await;

    assert_eq!(status, StatusCode::OK, "{body}");
    let (_, create) = w.fake.calls("create").last().cloned().unwrap();
    assert_eq!(create["image"], json!(image));
    assert_eq!(
        create["egress"],
        json!([{"host": "api.example.com", "port": 443}])
    );
    assert_eq!(create["egress_private"], json!(false));
    let removes = w.fake.calls("remove");
    assert!(
        removes.iter().any(|(id, _)| *id == run_id),
        "the old one went first"
    );
    assert_eq!(w.store.host_run(ID).await.unwrap().unwrap().run_id, run_id);
}
