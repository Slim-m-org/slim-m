// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Integration tests for invites: the permission gate, the use limit under
//! concurrency, expiry, the check endpoint's anti-mining guarantee and the
//! community metadata it discloses for a usable code, and its rate limit.

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use slimm_server::auth::Auth;
use slimm_server::config::Config;
use slimm_server::db;
use slimm_server::http::{self, AppState};
use slimm_server::hub::Hub;
use slimm_server::push::PushSender;
use slimm_server::ratelimit::RateLimiter;
use slimm_server::store::Store;
use tower::ServiceExt;

mod support;

async fn new_store() -> (Store, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-invite-test");
    let config = Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..Config::default()
    };
    let pool = db::connect(&config).await.expect("connect + migrate");
    (Store::new(pool), guard)
}

fn app(store: Store) -> Router {
    http::router(AppState {
        store,
        auth: Auth::new(2).unwrap(),
        hub: Hub::new(),
        limiter: RateLimiter::new(),
        push: PushSender::disabled(),
        voice: slimm_server::voice::VoiceService::disabled(),
        media: slimm_server::media::Media::for_tests(),
        gifs: slimm_server::http::gifs::GifSearch::disabled(),
        link_previews: slimm_server::http::link_preview::LinkPreviews::disabled(),
        dock: slimm_server::http::dock::Dock::disabled(),
        code_runner: slimm_server::code_runner::CodeRunner::disabled(),
    })
}

fn request(method: &str, uri: &str, token: Option<&str>, body: Option<Value>) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(token) = token {
        builder = builder.header("authorization", format!("Bearer {token}"));
    }
    match body {
        Some(value) => builder
            .header("content-type", "application/json")
            .body(Body::from(value.to_string()))
            .unwrap(),
        None => builder.body(Body::empty()).unwrap(),
    }
}

async fn json_body(response: axum::response::Response) -> Value {
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    serde_json::from_slice(&bytes).unwrap()
}

/// An admin (via the bootstrap claim) and an ordinary member.
async fn fixture() -> (Store, Router, String, String, support::TestDbGuard) {
    let (store, guard) = new_store().await;
    let auth = Auth::new(2).unwrap();
    let hash = auth
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();
    let admin = store.create_account("admin", "Admin", &hash).await.unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let member = store
        .create_account("member", "Member", &hash)
        .await
        .unwrap();

    let admin_session = store.open_session(admin.id, "d").await.unwrap();
    let member_session = store.open_session(member.id, "d").await.unwrap();
    let app = app(store.clone());
    (
        store,
        app,
        admin_session.access_token,
        member_session.access_token,
        guard,
    )
}

#[tokio::test]
async fn only_a_permitted_member_can_create_invites() {
    let (_store, app, admin, member, _guard) = fixture().await;

    let created = app
        .clone()
        .oneshot(request("POST", "/invites", Some(&admin), Some(json!({}))))
        .await
        .unwrap();
    assert_eq!(created.status(), StatusCode::OK);
    let invite = json_body(created).await;
    assert!(invite["code"].as_str().unwrap().len() >= 8);
    assert_eq!(invite["usable"], true);

    // @everyone does not get CREATE_INVITE from the bootstrap defaults.
    let refused = app
        .clone()
        .oneshot(request("POST", "/invites", Some(&member), Some(json!({}))))
        .await
        .unwrap();
    assert_eq!(refused.status(), StatusCode::FORBIDDEN);

    // Listing is gated the same way.
    let listing = app
        .clone()
        .oneshot(request("GET", "/invites", Some(&member), None))
        .await
        .unwrap();
    assert_eq!(listing.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn the_use_limit_holds_and_a_spent_invite_stops_working() {
    let (store, app, admin, member, _guard) = fixture().await;

    let invite = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/invites",
                Some(&admin),
                Some(json!({ "max_uses": 1 })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let code = invite["code"].as_str().unwrap().to_owned();

    // Usable before anyone spends it.
    let check = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/invites/{code}/check"),
                None,
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(check["usable"], true);

    let redeemed = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/invites/{code}/redeem"),
            Some(&member),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(redeemed.status(), StatusCode::NO_CONTENT);

    // The single use is gone, so a second redemption fails and the check says so.
    let again = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/invites/{code}/redeem"),
            Some(&admin),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(again.status(), StatusCode::BAD_REQUEST);
    assert!(!store.invite_is_usable(&code).await.unwrap());
}

#[tokio::test]
async fn concurrent_redemptions_cannot_exceed_the_limit() {
    let (store, _app, _admin, _member, _guard) = fixture().await;
    let auth = Auth::new(2).unwrap();
    let hash = auth
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();

    let creator = store.create_account("creator", "C", &hash).await.unwrap();
    let invite = store
        .create_invite(creator.id, None, Some(2), None)
        .await
        .unwrap();

    // Five people race for two slots.
    let mut joiners = Vec::new();
    for i in 0..5 {
        joiners.push(
            store
                .create_account(&format!("joiner{i}"), "J", &hash)
                .await
                .unwrap(),
        );
    }

    let mut handles = Vec::new();
    for joiner in joiners {
        let store = store.clone();
        let code = invite.code.clone();
        handles.push(tokio::spawn(async move {
            store.redeem_invite(&code, joiner.id).await.is_ok()
        }));
    }
    let mut succeeded = 0;
    for handle in handles {
        if handle.await.unwrap() {
            succeeded += 1;
        }
    }

    // The conditional UPDATE enforces this; else two racing redemptions could both read uses=1.
    assert_eq!(succeeded, 2, "exactly the two available slots were taken");
    assert!(!store.invite_is_usable(&invite.code).await.unwrap());
}

#[tokio::test]
async fn expiry_and_revocation_both_stop_an_invite() {
    let (store, app, admin, member, _guard) = fixture().await;
    let auth = Auth::new(2).unwrap();
    let hash = auth
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();
    let creator = store.create_account("creator", "C", &hash).await.unwrap();

    // Already expired.
    let expired = store
        .create_invite(creator.id, None, None, Some(1))
        .await
        .unwrap();
    assert!(!store.invite_is_usable(&expired.code).await.unwrap());

    // Revoked while still otherwise valid.
    let live = json_body(
        app.clone()
            .oneshot(request("POST", "/invites", Some(&admin), Some(json!({}))))
            .await
            .unwrap(),
    )
    .await;
    let code = live["code"].as_str().unwrap().to_owned();
    assert!(store.invite_is_usable(&code).await.unwrap());

    let revoked = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/invites/{code}"),
            Some(&admin),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(revoked.status(), StatusCode::NO_CONTENT);
    assert!(!store.invite_is_usable(&code).await.unwrap());

    let refused = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/invites/{code}/redeem"),
            Some(&member),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(refused.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn checking_an_unknown_code_looks_the_same_as_a_spent_one() {
    let (_store, app, _admin, _member, _guard) = fixture().await;

    // A code that was never issued reports exactly what a used-up or expired one
    // reports, so the endpoint cannot be used to mine for valid codes.
    let unknown = json_body(
        app.clone()
            .oneshot(request("GET", "/invites/neverissued/check", None, None))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(unknown, json!({ "usable": false }));
    assert_eq!(
        unknown.as_object().unwrap().len(),
        1,
        "the response says nothing beyond usable"
    );
}

async fn check_bytes(app: &Router, code: &str) -> Vec<u8> {
    let response = app
        .clone()
        .oneshot(request(
            "GET",
            &format!("/invites/{code}/check"),
            None,
            None,
        ))
        .await
        .unwrap();
    axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap()
        .to_vec()
}

/// The four answers are compared as raw bytes, not just as logically equal
/// JSON: a parsed comparison would not notice a stray field or a formatting
/// quirk, so a future edit that adds so much as one extra byte to only one of
/// these branches must fail here rather than only at a future security review.
#[tokio::test]
async fn expired_spent_and_never_issued_invites_are_byte_for_byte_identical() {
    let (store, app, admin, member, _guard) = fixture().await;
    let auth = Auth::new(2).unwrap();
    let hash = auth
        .hash_password("hunter2hunter2".to_owned())
        .await
        .unwrap();
    let creator = store.create_account("creator2", "C", &hash).await.unwrap();

    let expired = store
        .create_invite(creator.id, None, None, Some(1))
        .await
        .unwrap();

    let spent = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/invites",
                Some(&admin),
                Some(json!({ "max_uses": 1 })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let spent_code = spent["code"].as_str().unwrap().to_owned();
    let redeemed = app
        .clone()
        .oneshot(request(
            "POST",
            &format!("/invites/{spent_code}/redeem"),
            Some(&member),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(redeemed.status(), StatusCode::NO_CONTENT);

    let revoked = json_body(
        app.clone()
            .oneshot(request("POST", "/invites", Some(&admin), Some(json!({}))))
            .await
            .unwrap(),
    )
    .await;
    let revoked_code = revoked["code"].as_str().unwrap().to_owned();
    let revoke_response = app
        .clone()
        .oneshot(request(
            "DELETE",
            &format!("/invites/{revoked_code}"),
            Some(&admin),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(revoke_response.status(), StatusCode::NO_CONTENT);

    let never_issued = check_bytes(&app, "neverissued").await;
    let expired_bytes = check_bytes(&app, &expired.code).await;
    let spent_bytes = check_bytes(&app, &spent_code).await;
    let revoked_bytes = check_bytes(&app, &revoked_code).await;

    assert_eq!(
        expired_bytes, never_issued,
        "expired must answer exactly like never-issued"
    );
    assert_eq!(
        spent_bytes, never_issued,
        "spent must answer exactly like never-issued"
    );
    assert_eq!(
        revoked_bytes, never_issued,
        "revoked must answer exactly like never-issued"
    );
    assert_eq!(never_issued, br#"{"usable":false}"#.to_vec());
}

#[tokio::test]
async fn a_valid_code_discloses_community_metadata() {
    let (_store, app, admin, _member, _guard) = fixture().await;

    let invite = json_body(
        app.clone()
            .oneshot(request(
                "POST",
                "/invites",
                Some(&admin),
                Some(json!({ "max_uses": 5 })),
            ))
            .await
            .unwrap(),
    )
    .await;
    let code = invite["code"].as_str().unwrap().to_owned();

    let check = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/invites/{code}/check"),
                None,
                None,
            ))
            .await
            .unwrap(),
    )
    .await;

    assert_eq!(check["usable"], true);
    let community = &check["community"];
    // The fixture's two accounts (admin, member) are the whole deployment.
    assert_eq!(community["name"], "slim-m");
    assert_eq!(community["member_count"], 2);
    assert_eq!(community["invited_by"], "Admin");
    assert_eq!(community["uses_remaining"], 5);
    assert!(community["expires_at"].is_null());
}

#[tokio::test]
async fn the_check_endpoint_is_rate_limited() {
    let (_store, app, _admin, _member, _guard) = fixture().await;

    let mut statuses = Vec::new();
    for _ in 0..15 {
        let response = app
            .clone()
            .oneshot(request("GET", "/invites/neverissued/check", None, None))
            .await
            .unwrap();
        statuses.push(response.status());
    }

    assert!(
        statuses.contains(&StatusCode::OK),
        "the first checks inside the burst are answered: {statuses:?}"
    );
    assert!(
        statuses.contains(&StatusCode::TOO_MANY_REQUESTS),
        "a sustained flood of guesses must be refused: {statuses:?}"
    );
}

/// An invite that grants a role is role assignment with a delay, so it carries
/// the same escalation risk and must carry the same guard.
mod role_grant {
    use super::*;
    use slimm_server::permissions::Permissions;

    /// Grants `bits` to the ordinary member from [`fixture`], so a test can
    /// hold exactly the permissions it is about and nothing else.
    async fn grant_member(store: &Store, bits: Permissions) {
        let member = store.find_credentials("member").await.unwrap().unwrap().0;
        let role = store.create_role("granted", bits, false).await.unwrap();
        store.assign_role(member, role).await.unwrap();
    }

    #[tokio::test]
    async fn an_admin_can_attach_a_role_and_it_is_applied_on_redemption() {
        let (store, app, admin, _member, _guard) = fixture().await;
        let role = store
            .create_role("moderator", Permissions::MANAGE_MESSAGES, false)
            .await
            .unwrap();

        let created = app
            .clone()
            .oneshot(request(
                "POST",
                "/invites",
                Some(&admin),
                Some(json!({"role_grant": role.to_string()})),
            ))
            .await
            .unwrap();
        assert_eq!(created.status(), StatusCode::OK);
        let body = json_body(created).await;
        assert_eq!(body["role_grant"], role.to_string());
        let code = body["code"].as_str().unwrap().to_owned();

        let registered = app
            .oneshot(request(
                "POST",
                "/auth/register",
                None,
                Some(json!({
                    "username": "carol",
                    "display_name": "Carol",
                    "password": "hunter2hunter2",
                    "device_name": "cli",
                    "invite_code": code,
                })),
            ))
            .await
            .unwrap();
        assert_eq!(registered.status(), StatusCode::OK);

        let carol = store.find_credentials("carol").await.unwrap().unwrap().0;
        assert!(
            store
                .base_permissions(carol)
                .await
                .unwrap()
                .contains(Permissions::MANAGE_MESSAGES),
            "redeeming the code must apply the role it grants"
        );
    }

    #[tokio::test]
    async fn create_invite_alone_cannot_attach_a_role() {
        // May invite, may not decide what the invitee becomes.
        let (store, app, _admin, member, _guard) = fixture().await;
        grant_member(&store, Permissions::CREATE_INVITE).await;
        let role = store
            .create_role("target", Permissions::from_bits(0), false)
            .await
            .unwrap();

        let refused = app
            .clone()
            .oneshot(request(
                "POST",
                "/invites",
                Some(&member),
                Some(json!({"role_grant": role.to_string()})),
            ))
            .await
            .unwrap();
        assert_eq!(refused.status(), StatusCode::FORBIDDEN);

        // The plain invite still works, so the refusal is the grant and not
        // the route.
        let plain = app
            .oneshot(request("POST", "/invites", Some(&member), Some(json!({}))))
            .await
            .unwrap();
        assert_eq!(plain.status(), StatusCode::OK);
    }

    #[tokio::test]
    async fn a_role_carrying_more_than_the_caller_holds_is_refused() {
        // Both bits, but the role carries ADMINISTRATOR: without this check
        // the pair mints an admin account for somebody who is not one.
        let (store, app, _admin, member, _guard) = fixture().await;
        grant_member(
            &store,
            Permissions::CREATE_INVITE.union(Permissions::MANAGE_ROLES),
        )
        .await;
        let elevated = store
            .create_role("superuser", Permissions::ADMINISTRATOR, false)
            .await
            .unwrap();

        let refused = app
            .oneshot(request(
                "POST",
                "/invites",
                Some(&member),
                Some(json!({"role_grant": elevated.to_string()})),
            ))
            .await
            .unwrap();
        assert_eq!(refused.status(), StatusCode::FORBIDDEN);
    }

    #[tokio::test]
    async fn a_role_that_does_not_exist_is_not_found_rather_than_a_silent_none() {
        let (_store, app, admin, _member, _guard) = fixture().await;

        let response = app
            .oneshot(request(
                "POST",
                "/invites",
                Some(&admin),
                Some(json!({"role_grant": uuid::Uuid::now_v7().to_string()})),
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
    }

    /// `InviteDto` (the authenticated create/list shape) carries `role_grant`,
    /// but the unauthenticated check endpoint is built from its own
    /// `CheckResponse`/`InviteCommunity` types and must stay that way: an
    /// invite's role is who redeeming it becomes, which is not something
    /// proving you hold the code should disclose before you have used it.
    #[tokio::test]
    async fn the_check_endpoint_never_discloses_a_role_grant() {
        let (store, app, admin, _member, _guard) = fixture().await;
        let role = store
            .create_role("greeter", Permissions::MANAGE_MESSAGES, false)
            .await
            .unwrap();

        let created = json_body(
            app.clone()
                .oneshot(request(
                    "POST",
                    "/invites",
                    Some(&admin),
                    Some(json!({"role_grant": role.to_string()})),
                ))
                .await
                .unwrap(),
        )
        .await;
        let code = created["code"].as_str().unwrap().to_owned();

        let check = json_body(
            app.oneshot(request(
                "GET",
                &format!("/invites/{code}/check"),
                None,
                None,
            ))
            .await
            .unwrap(),
        )
        .await;

        assert_eq!(check["usable"], true);
        let mut top_level: Vec<_> = check.as_object().unwrap().keys().cloned().collect();
        top_level.sort();
        assert_eq!(top_level, ["community", "usable"]);

        // The exact public key set is pinned in invite_landing.rs; this only guards the grant.
        let community = check["community"].as_object().unwrap();
        assert!(
            !community.keys().any(|k| k.contains("role")),
            "a role_grant must never reach this response, even for a code that carries one"
        );
    }
}
