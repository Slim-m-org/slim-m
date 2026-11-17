// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `GET /roles/{id}/preview` answers what a real member holding that role is listed, never more
//! than the caller sees, and only for roles below the caller (decision 0124).

use axum::http::StatusCode;
use serde_json::{Value, json};
use slimm_server::permissions::Permissions;

use super::world::{Member, World, ids, world};

fn preview_uri(role: &str) -> String {
    format!("/roles/{role}/preview")
}

/// `(id, permissions)` for each channel, sorted, from a channel listing.
fn channel_bits(listed: &[Value]) -> Vec<(String, i64)> {
    let mut bits: Vec<(String, i64)> = listed
        .iter()
        .map(|c| {
            let id = c["id"].as_str().unwrap().to_owned();
            (id, c["permissions"].as_i64().unwrap())
        })
        .collect();
    bits.sort();
    bits
}

async fn assert_preview_matches(w: &World, role: &str, member: &Member) {
    let preview = w.ok("GET", &preview_uri(role), &w.admin, None).await;
    let real_channels = w.ok("GET", "/channels", &member.token, None).await;
    assert_eq!(
        channel_bits(preview["channels"].as_array().unwrap()),
        channel_bits(real_channels.as_array().unwrap()),
    );
    let real_categories = w.categories(&member.token).await;
    let previewed = preview["categories"].as_array().unwrap();
    assert_eq!(ids(previewed), ids(&real_categories));
    let parents: Vec<&Value> = previewed.iter().map(|c| &c["parent_id"]).collect();
    let real_parents: Vec<&Value> = real_categories.iter().map(|c| &c["parent_id"]).collect();
    assert_eq!(parents, real_parents);
}

/// The id of the role called `name` in the caller's `GET /roles`.
async fn role_named(w: &World, name: &str) -> String {
    let roles = w.ok("GET", "/roles", &w.admin, None).await;
    roles
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["name"] == name)
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_owned()
}

/// Gives the `neither` member a MANAGE_ROLES role ranked between `gamer` (above) and `cs` (below).
async fn moderator_between(w: &World) -> String {
    let body = json!({"name": "mod", "permissions": Permissions::MANAGE_ROLES.bits()});
    let created = w.ok("POST", "/roles", &w.admin, Some(body)).await;
    let moderator = created["id"].as_str().unwrap().to_owned();
    let admin = role_named(w, "admin").await;
    let order = json!({"role_ids": [admin, &w.gamer_role, &moderator, &w.cs_role]});
    w.ok("PATCH", "/roles/reorder", &w.admin, Some(order)).await;
    let grant = format!("/members/{}/roles/{moderator}", w.neither.id.0);
    w.ok("PUT", &grant, &w.admin, None).await;
    moderator
}

#[tokio::test]
async fn each_preview_matches_what_a_real_member_with_that_role_is_listed() {
    let w = world("slimm-role-preview-match").await;
    assert_preview_matches(&w, &w.gamer_role, &w.gamer).await;
    assert_preview_matches(&w, &w.cs_role, &w.cs).await;
    assert_preview_matches(&w, &w.everyone, &w.neither).await;
}

#[tokio::test]
async fn a_member_overwrite_on_the_holder_never_reaches_the_role_preview() {
    let w = world("slimm-role-preview-member-overwrite").await;
    let uri = format!("/channels/{}/overwrites/member/{}", w.cs_chat, w.gamer.id.0);
    let allow = json!({"allow": Permissions::VIEW_CHANNEL.bits(), "deny": 0});
    w.ok("PUT", &uri, &w.admin, Some(allow)).await;
    let real = w.channel_names(&w.gamer.token).await;
    assert!(real.iter().any(|n| n == "cs-chat"), "{real:?}");

    let preview = w
        .ok("GET", &preview_uri(&w.gamer_role), &w.admin, None)
        .await;
    let raw = preview.to_string();
    assert!(!raw.contains(&w.cs_chat), "{raw}");
}

#[tokio::test]
async fn a_manager_previews_roles_below_and_is_refused_the_ones_above() {
    let w = world("slimm-role-preview-ladder").await;
    moderator_between(&w).await;
    let (below, _) = w
        .call("GET", &preview_uri(&w.cs_role), &w.neither.token, None)
        .await;
    assert_eq!(below, StatusCode::OK);
    let (above, body) = w
        .call("GET", &preview_uri(&w.gamer_role), &w.neither.token, None)
        .await;
    assert_eq!(above, StatusCode::FORBIDDEN);
    assert_eq!(body["code"], "role_hierarchy", "{body}");
}

#[tokio::test]
async fn a_preview_never_names_a_channel_or_category_the_caller_cannot_see() {
    let w = world("slimm-role-preview-no-upward-leak").await;
    moderator_between(&w).await;
    let caller_sees = w.channel_names(&w.neither.token).await;
    assert!(
        !caller_sees.iter().any(|n| n == "cs-chat"),
        "{caller_sees:?}"
    );

    let preview = w
        .ok("GET", &preview_uri(&w.cs_role), &w.neither.token, None)
        .await;
    let raw = preview.to_string();
    for hidden in [
        "cs-chat",
        "cs2",
        "gamers",
        w.cs_chat.as_str(),
        w.cs2.as_str(),
    ] {
        assert!(!raw.contains(hidden), "the preview leaked {hidden}: {raw}");
    }
}

#[tokio::test]
async fn a_member_without_manage_roles_is_refused_and_an_unknown_role_is_not_found() {
    let w = world("slimm-role-preview-refusals").await;
    let (status, _) = w
        .call("GET", &preview_uri(&w.cs_role), &w.gamer.token, None)
        .await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    let unknown = preview_uri(&uuid::Uuid::now_v7().to_string());
    let (status, _) = w.call("GET", &unknown, &w.admin, None).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn opening_a_preview_is_audited_once_however_often_it_is_reloaded() {
    let w = world("slimm-role-preview-audit").await;
    for _ in 0..3 {
        w.ok("GET", &preview_uri(&w.cs_role), &w.admin, None).await;
    }
    let log = w.ok("GET", "/space/audit-log", &w.admin, None).await;
    let previews: Vec<&Value> = log
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["action"] == "role.preview")
        .collect();
    assert_eq!(previews.len(), 1, "{log}");
    assert_eq!(previews[0]["target_id"], json!(w.cs_role));
}
