// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The profile section and member badge slot routes (decision 0091): which
//! modules are asked, what is let through, caching, and the refusals.

use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use slimm_server::store::{
    DockProvenance, InstallModuleRequest, ModulePlatform, ModuleRuntimeLimits, ModuleSlot, User,
};
use tower::ServiceExt;

mod support;
use support::module_world::{World, world};
use support::wasm_fixtures::{
    canned_ok_wasm, canned_raw_wasm, canned_slot_wasm, fuel_burner_wasm, sha256_hex,
};

fn slot(kind: &str, name: &str, title: Option<&str>) -> ModuleSlot {
    ModuleSlot {
        kind: kind.into(),
        name: name.into(),
        title: title.map(Into::into),
    }
}

fn both_slots() -> Vec<ModuleSlot> {
    vec![
        slot("profile.section", "xp", Some("Level")),
        slot("member.badge", "level", None),
    ]
}

/// Installs and enables `wasm` as module `id` with `slots` under `addon_api`.
async fn install(w: &World, id: &str, wasm: &[u8], addon_api: u32, slots: Vec<ModuleSlot>) {
    let sha256 = sha256_hex(wasm);
    let platform = ModulePlatform {
        addon_api,
        slots,
        ..ModulePlatform::default()
    };
    w.store
        .install_module_from_dock(
            InstallModuleRequest {
                id,
                name: "Levels",
                version: "0.1.0",
                artifact_sha256: &sha256,
                approved_capabilities: &[],
                runtime_limits: &ModuleRuntimeLimits::default(),
                permissions: &[],
                extension_points: &[],
            },
            wasm,
            &DockProvenance {
                host_capabilities: &[],
                source_repo: None,
                network_hosts: &[],
                local_network_approved: false,
                schedules: &[],
                platform: &platform,
            },
        )
        .await
        .unwrap();
    w.store.set_module_enabled(id, true).await.unwrap();
}

async fn get(w: &World, uri: &str, token: Option<&str>) -> (StatusCode, Value) {
    let mut request = Request::builder().uri(uri);
    if let Some(token) = token {
        request = request.header("authorization", format!("Bearer {token}"));
    }
    let response = w
        .router
        .clone()
        .oneshot(request.body(Body::empty()).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (
        status,
        serde_json::from_slice(&bytes).unwrap_or(Value::Null),
    )
}

async fn profile(w: &World, member: UserId) -> Value {
    let uri = format!("/space/dock/slots/profile/{member}");
    let (status, body) = get(w, &uri, Some(&w.token)).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body
}

async fn badges(w: &World, members: &[UserId]) -> Value {
    let ids: Vec<String> = members.iter().map(ToString::to_string).collect();
    let uri = format!("/space/dock/slots/badges?ids={}", ids.join(","));
    let (status, body) = get(w, &uri, Some(&w.token)).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    body
}

async fn member(w: &World, name: &str) -> User {
    w.store.create_user(name, name).await.unwrap()
}

async fn slot_runs(w: &World, id: &str) -> (i64, i64) {
    let stats = w.store.module_run_stats().await.unwrap();
    stats
        .get(id)
        .and_then(|rows| rows.iter().find(|r| r.command == "@slot"))
        .map_or((0, 0), |r| (r.run_count, r.failure_count))
}

fn text(s: &str) -> Value {
    json!({ "type": "text", "text": s })
}

fn answer(items: &[(UserId, Value)]) -> Value {
    let items: serde_json::Map<String, Value> = items
        .iter()
        .map(|(id, item)| (id.to_string(), item.clone()))
        .collect();
    json!({ "$slim": "slot/1", "items": items })
}

#[tokio::test]
async fn a_module_fills_a_profile_section_and_a_badge() {
    let w = world("slimm-slots-fill").await;
    let bea = member(&w, "bea").await;
    let wasm = canned_slot_wasm(&answer(&[(
        bea.id,
        json!({ "nodes": [text("Level 4"), { "type": "badge", "text": "VIP" }], "fallback": "Lv 4" }),
    )]));
    install(&w, "levels", &wasm, 1, both_slots()).await;

    let body = profile(&w, bea.id).await;
    let section = &body["sections"][0];
    assert_eq!(section["module_id"], "levels");
    assert_eq!(section["name"], "xp");
    assert_eq!(section["title"], "Level");
    assert_eq!(section["nodes"][0], text("Level 4"));
    assert_eq!(section["fallback"], "Lv 4");

    let body = badges(&w, &[bea.id, w.user.id]).await;
    let mine = body["badges"][bea.id.to_string()].as_array().unwrap();
    assert_eq!(mine.len(), 1);
    assert_eq!(mine[0]["name"], "level");
    assert_eq!(mine[0]["nodes"][1]["type"], "badge");
    assert!(body["badges"].get(w.user.id.to_string()).is_none());
}

#[tokio::test]
async fn a_module_without_a_matching_slot_a_disabled_one_or_no_addon_api_is_not_asked() {
    let w = world("slimm-slots-excluded").await;
    let bea = member(&w, "bea").await;
    let item = json!({ "nodes": [text("hi")] });
    let wasm = canned_slot_wasm(&answer(&[(bea.id, item)]));
    install(&w, "no-slots", &wasm, 1, vec![]).await;
    install(
        &w,
        "badge-only",
        &wasm,
        1,
        vec![slot("member.badge", "b", None)],
    )
    .await;
    install(&w, "off", &wasm, 1, both_slots()).await;
    w.store.set_module_enabled("off", false).await.unwrap();
    install(&w, "no-api", &wasm, 0, both_slots()).await;

    assert_eq!(profile(&w, bea.id).await["sections"], json!([]));
    for id in ["no-slots", "badge-only", "off", "no-api"] {
        assert_eq!(slot_runs(&w, id).await, (0, 0), "{id} must not run");
    }
    let body = badges(&w, &[bea.id]).await;
    assert_eq!(
        body["badges"][bea.id.to_string()].as_array().unwrap().len(),
        1
    );
    assert_eq!(slot_runs(&w, "badge-only").await, (1, 0));
    assert_eq!(slot_runs(&w, "no-api").await, (0, 0));
}

#[tokio::test]
async fn invalid_trees_are_dropped_and_clean_ones_are_sanitized() {
    let w = world("slimm-slots-invalid").await;
    let (ok, big, unknown, bare, dirty) = (
        member(&w, "ok").await.id,
        member(&w, "big").await.id,
        member(&w, "unknown").await.id,
        member(&w, "bare").await.id,
        member(&w, "dirty").await.id,
    );
    let forty_one: Vec<Value> = (0..41).map(|_| text("x")).collect();
    let wasm = canned_slot_wasm(&answer(&[
        (
            ok,
            json!({ "nodes": [{ "type": "progress", "value": 900, "max": 100 }] }),
        ),
        (big, json!({ "nodes": forty_one })),
        (
            unknown,
            json!({ "nodes": [{ "type": "chart" }], "fallback": "Level 9" }),
        ),
        (bare, json!({ "nodes": [{ "type": "chart" }] })),
        (dirty, json!({ "nodes": [text("Le\u{202E}vel\u{200B} 1")] })),
    ]));
    install(&w, "levels", &wasm, 1, both_slots()).await;

    let body = badges(&w, &[ok, big, unknown, bare, dirty]).await["badges"].clone();
    assert_eq!(body[ok.to_string()][0]["nodes"][0]["value"], 100);
    assert!(body.get(big.to_string()).is_none(), "41 nodes");
    assert_eq!(body[unknown.to_string()][0]["nodes"], json!([]));
    assert_eq!(body[unknown.to_string()][0]["fallback"], "Level 9");
    assert!(
        body.get(bare.to_string()).is_none(),
        "nothing valid, no fallback"
    );
    let dirty_nodes = body[dirty.to_string()][0]["nodes"]
        .as_array()
        .unwrap()
        .clone();
    assert_eq!(
        dirty_nodes,
        vec![text("Level 1")],
        "hidden characters are stripped"
    );
}

#[tokio::test]
async fn a_second_request_within_thirty_seconds_does_not_run_the_module() {
    let w = world("slimm-slots-cache").await;
    let bea = member(&w, "bea").await;
    let wasm = canned_slot_wasm(&answer(&[(bea.id, json!({ "nodes": [text("a")] }))]));
    install(&w, "levels", &wasm, 1, both_slots()).await;

    let first = badges(&w, &[bea.id]).await;
    let second = badges(&w, &[bea.id]).await;
    assert_eq!(first, second);
    assert_eq!(slot_runs(&w, "levels").await, (1, 0));

    badges(&w, &[bea.id, w.user.id]).await;
    assert_eq!(
        slot_runs(&w, "levels").await,
        (2, 0),
        "only the new member is asked"
    );
}

#[tokio::test]
async fn disabling_a_module_drops_what_was_cached() {
    let w = world("slimm-slots-invalidate").await;
    let bea = member(&w, "bea").await;
    let wasm = canned_slot_wasm(&answer(&[(bea.id, json!({ "nodes": [text("a")] }))]));
    install(&w, "levels", &wasm, 1, both_slots()).await;
    let role = w
        .store
        .create_role("admin", Permissions::ADMINISTRATOR, false)
        .await
        .unwrap();
    w.store.assign_role(w.user.id, role).await.unwrap();

    badges(&w, &[bea.id]).await;
    for action in ["disable", "enable"] {
        let request = Request::builder()
            .method("POST")
            .uri(format!("/space/dock/modules/levels/{action}"))
            .header("authorization", format!("Bearer {}", w.token))
            .body(Body::empty())
            .unwrap();
        let status = w.router.clone().oneshot(request).await.unwrap().status();
        assert!(status.is_success(), "{action}: {status}");
    }
    badges(&w, &[bea.id]).await;
    assert_eq!(slot_runs(&w, "levels").await, (2, 0));
}

#[tokio::test]
async fn a_module_that_traps_returns_junk_or_errors_shows_nothing_and_counts_as_failed() {
    let w = world("slimm-slots-failing").await;
    let bea = member(&w, "bea").await;
    install(&w, "traps", &fuel_burner_wasm(), 1, both_slots()).await;
    install(
        &w,
        "junk",
        &canned_ok_wasm("not a slot response"),
        1,
        both_slots(),
    )
    .await;
    let refused = canned_raw_wasm(br#"{"ok":false,"error":"no"}"#);
    install(&w, "refuses", &refused, 1, both_slots()).await;
    let wrong = canned_slot_wasm(&json!({ "$slim": "slot/9", "items": {} }));
    install(&w, "wrong", &wrong, 1, both_slots()).await;

    assert_eq!(badges(&w, &[bea.id]).await["badges"], json!({}));
    assert_eq!(profile(&w, bea.id).await["sections"], json!([]));
    for id in ["traps", "junk", "refuses", "wrong"] {
        let (runs, failures) = slot_runs(&w, id).await;
        assert!(
            runs >= 1 && failures >= 1,
            "{id}: {runs} runs, {failures} failed"
        );
    }
}

#[tokio::test]
async fn unknown_deleted_and_malformed_ids_reveal_nothing_or_are_refused() {
    let w = world("slimm-slots-unknown").await;
    let wasm = canned_slot_wasm(&answer(&[]));
    install(&w, "levels", &wasm, 1, both_slots()).await;
    let nobody = UserId::generate();

    assert_eq!(profile(&w, nobody).await["sections"], json!([]));
    assert_eq!(badges(&w, &[nobody]).await["badges"], json!({}));
    assert_eq!(
        slot_runs(&w, "levels").await,
        (0, 0),
        "no one live to ask about"
    );
    let (status, _) = get(&w, "/space/dock/slots/profile/not-a-uuid", Some(&w.token)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = get(&w, "/space/dock/slots/badges?ids=nope", Some(&w.token)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn at_most_a_hundred_ids_and_a_signed_in_caller() {
    let w = world("slimm-slots-limits").await;
    let ids = |n: usize| {
        (0..n)
            .map(|_| UserId::generate().to_string())
            .collect::<Vec<_>>()
            .join(",")
    };
    let (status, _) = get(
        &w,
        &format!("/space/dock/slots/badges?ids={}", ids(100)),
        Some(&w.token),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = get(
        &w,
        &format!("/space/dock/slots/badges?ids={}", ids(101)),
        Some(&w.token),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (status, _) = get(
        &w,
        &format!("/space/dock/slots/badges?ids={}", ids(1)),
        None,
    )
    .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let uri = format!("/space/dock/slots/profile/{}", w.user.id);
    assert_eq!(get(&w, &uri, None).await.0, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn the_routes_are_rate_limited_per_member() {
    let w = world("slimm-slots-rate").await;
    let uri = format!("/space/dock/slots/profile/{}", w.user.id);
    let mut statuses = Vec::new();
    for _ in 0..80 {
        statuses.push(get(&w, &uri, Some(&w.token)).await.0);
    }
    assert_eq!(statuses[0], StatusCode::OK);
    assert!(statuses.contains(&StatusCode::TOO_MANY_REQUESTS));
}
