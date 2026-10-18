// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `Role.mentionable`, over `POST /roles` and `PATCH /roles/{roleId}`: set at
//! creation, toggled by itself afterward, and treated as a real field by the
//! "nothing to update" refusal - split out of `tests/roles.rs` (whose own
//! concerns are the MANAGE_ROLES gate, escalation, and the last-administrator
//! invariant) once adding this pushed that file past the 500-line ceiling.
//! Resolution of `@[Role Name]` against this flag is `tests/role_mentions.rs`.

use axum::http::StatusCode;
use serde_json::json;
use tower::ServiceExt;

mod support;

use support::app::{app, json_body, register_token_id as register, request};

/// `mentionable` can be set at creation, toggled by itself afterward without
/// resending `name`/`permissions`, and a genuinely empty patch is refused
/// the same way it already is when neither of those two is present.
#[tokio::test]
async fn mentionable_can_be_set_at_creation_and_toggled_on_its_own() {
    let (store, _guard) = support::new_store("slimm-role-mentionable-flag").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;

    let created = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/roles",
                Some(&admin_token),
                Some(json!({
                    "name": "Core Team",
                    "permissions": 0,
                    "mentionable": true,
                })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let role_id = created["id"].as_str().unwrap().to_owned();
    assert_eq!(created["mentionable"], true);

    let toggled_off = json_body(
        app.clone()
            .oneshot(request(
                "PATCH",
                &format!("/roles/{role_id}"),
                Some(&admin_token),
                Some(json!({ "mentionable": false })),
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(toggled_off["mentionable"], false);
    // Untouched fields survive a mentionable-only update.
    assert_eq!(toggled_off["name"], "Core Team");

    let empty_patch = app
        .clone()
        .oneshot(request(
            "PATCH",
            &format!("/roles/{role_id}"),
            Some(&admin_token),
            Some(json!({})),
        ))
        .await
        .unwrap();
    assert_eq!(empty_patch.status(), StatusCode::BAD_REQUEST);
}

/// A retry of an idempotent create (the same client-supplied id twice) must
/// not re-apply `mentionable` a second time - see the note on
/// `create`/`CreatedRole::fresh` in `http/roles.rs`. Proven here rather than
/// in `role_create_idempotency.rs` since it is specifically about this
/// field's own opt-in-on-fresh-create-only behaviour.
#[tokio::test]
async fn mentionable_at_creation_is_not_reapplied_on_a_retried_create() {
    let (store, _guard) = support::new_store("slimm-role-mentionable-flag").await;
    let app = app(store.clone());
    let (admin_token, _admin_id) = register(&store, "alice").await;
    let id = uuid::Uuid::now_v7().to_string();

    let first = app
        .clone()
        .oneshot(request(
            "POST",
            "/roles",
            Some(&admin_token),
            Some(json!({ "id": id, "name": "Core Team", "permissions": 0, "mentionable": true })),
        ))
        .await
        .unwrap();
    assert_eq!(json_body(first).await["mentionable"], true);

    // A retry with mentionable omitted must not read as unsetting it.
    let retried = app
        .clone()
        .oneshot(request(
            "POST",
            "/roles",
            Some(&admin_token),
            Some(json!({ "id": id, "name": "Core Team", "permissions": 0 })),
        ))
        .await
        .unwrap();
    assert_eq!(
        json_body(retried).await["mentionable"],
        true,
        "a retry must not touch a field the first create already set"
    );
}
