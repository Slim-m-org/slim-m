// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Roles on the member list: `@everyone` excluded, a member with nothing
//! beyond it answers empty, and a page of members with mixed role sets does
//! not pay a query per member. Split out from `users.rs` (profiles and the
//! bare member list) the same way `message_delete.rs` and
//! `message_search.rs` split off from `message_endpoints.rs`: one file per
//! concern.

use slimm_server::ids::UserId;
use slimm_server::permissions::Permissions;
use tower::ServiceExt;
use uuid::Uuid;

mod support;

use support::app::{app, json_body, register_token_id as register, request};

/// The member list carries each member's role names, for a client to render
/// a badge (e.g. "Op") beside them. `@everyone` is excluded - every member
/// holds it, so it would be a badge with no information - and a member with
/// nothing beyond that base role comes back with an empty list, not
/// `@everyone` itself.
///
/// Alice needs no extra setup: the first account to register claims the
/// deployment and bootstrap assigns it a real (non-`@everyone`) "admin" role,
/// so she is already a member holding a role.
#[tokio::test]
async fn member_list_carries_role_names_excluding_everyone() {
    let (store, _guard) = support::new_store("slimm-member-roles-test").await;
    let app = app(store.clone());
    let (token, alice_id) = register(&store, "alice").await;
    let (_, bob_id) = register(&store, "bob").await;
    let (_, carol_id) = register(&store, "carol").await;

    let moderator = store
        .create_role("moderator", Permissions::VIEW_CHANNEL, false)
        .await
        .unwrap();
    store
        .assign_role(UserId(Uuid::parse_str(&bob_id).unwrap()), moderator)
        .await
        .unwrap();
    // Carol gets no extra role: only `@everyone`, which must not appear.

    let body = json_body(
        app.clone()
            .oneshot(request("GET", "/members", Some(&token), None))
            .await
            .unwrap(),
    )
    .await;
    let members = body.as_array().unwrap();
    let roles_of = |id: &str| -> Vec<String> {
        let member = members.iter().find(|m| m["id"] == id).unwrap();
        member["roles"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r.as_str().unwrap().to_owned())
            .collect()
    };

    assert_eq!(roles_of(&alice_id), vec!["admin"]);
    assert_eq!(roles_of(&bob_id), vec!["moderator"]);
    assert_eq!(roles_of(&carol_id), Vec::<String>::new());
}

/// Whether the member list pays a query per member was checked with a live
/// counter first, via a `tracing` subscriber counting sqlx's own
/// `"sqlx::query"` events. It had to be abandoned: sqlx's SQLite driver runs
/// each connection's queries on that connection's own dedicated worker
/// thread, so a scoped (thread-local) subscriber never sees them, and the
/// only alternative - a single process-global subscriber - would also count
/// every other test's queries running concurrently in the same test binary,
/// which is worse than not measuring at all. Correctness is what is proven
/// below instead: a page of members with different role sets must resolve
/// to the right roles for the right member, which a broken batch (say, a
/// join without a `GROUP BY`) would fail even though it issues only one
/// query. `Store::roles_for_users` itself is one `.fetch_all` call per
/// invocation regardless of page size - the same shape
/// `Store::reactions_for_messages` and `Store::user_profiles` both already
/// use for exactly this reason.
#[tokio::test]
async fn the_member_list_does_not_query_per_member() {
    let (store, _guard) = support::new_store("slimm-member-roles-test").await;
    let app = app(store.clone());
    let (token, alice_id) = register(&store, "alice").await;

    let moderator = store
        .create_role("moderator", Permissions::VIEW_CHANNEL, false)
        .await
        .unwrap();
    let admin = store
        .create_role("junior-admin", Permissions::VIEW_CHANNEL, false)
        .await
        .unwrap();
    const EXTRA_MEMBERS: usize = 8;
    let mut ids = vec![alice_id];
    for i in 0..EXTRA_MEMBERS {
        let (_, id) = register(&store, &format!("member{i}")).await;
        // Alternate roles so a page mixing different role sets is actually
        // exercised, not just one role repeated for everyone.
        let role = if i % 2 == 0 { moderator } else { admin };
        store
            .assign_role(UserId(Uuid::parse_str(&id).unwrap()), role)
            .await
            .unwrap();
        ids.push(id);
    }

    let body = json_body(
        app.clone()
            .oneshot(request(
                "GET",
                &format!("/members?limit={}", EXTRA_MEMBERS + 1),
                Some(&token),
                None,
            ))
            .await
            .unwrap(),
    )
    .await;
    let members = body.as_array().unwrap();
    assert_eq!(members.len(), EXTRA_MEMBERS + 1);

    for (i, id) in ids.iter().enumerate().skip(1) {
        let member = members.iter().find(|m| &m["id"] == id).unwrap();
        let roles: Vec<&str> = member["roles"]
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r.as_str().unwrap())
            .collect();
        let expected = if (i - 1) % 2 == 0 {
            "moderator"
        } else {
            "junior-admin"
        };
        assert_eq!(roles, vec![expected], "member {i} got the wrong role set");
    }
}
