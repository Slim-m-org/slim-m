// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What the connector ceiling's subquery adds to a batched permission read over many members.
//! A measurement: run with `--run-ignored only --release`; it asserts nothing.

use std::time::Instant;

use slimm_server::ids::{ChannelId, UserId};
use slimm_server::permissions::Permissions;
use sqlx::Row;

use crate::support;

const MEMBERS: usize = 1_000;
const ROLES_EACH: usize = 3;
const RUNS: u32 = 30;

const WITH_CAP: &str = "(CASE WHEN u.connector_principal = 1 \
     THEN COALESCE((SELECT CASE WHEN m.enabled = 1 THEN COALESCE(m.connector_permissions, 0) ELSE 0 END \
     FROM installed_modules m WHERE m.bot_user_id = u.id AND m.provider = 'connector'), 0) \
     ELSE (SELECT CASE WHEN m.enabled = 1 THEN COALESCE(m.connector_permissions, 0) ELSE 0 END \
     FROM installed_modules m WHERE m.bot_user_id = u.id AND m.provider = 'connector') END)";
const WITHOUT_CAP: &str = "(CASE WHEN u.connector_principal = 1 \
     THEN COALESCE((SELECT CASE WHEN m.enabled = 1 THEN COALESCE(m.connector_permissions, 0) ELSE 0 END \
     FROM installed_modules m WHERE m.bot_user_id = u.id AND m.provider = 'connector'), 0) \
     ELSE NULL END)";

#[tokio::test]
#[ignore = "a measurement: 1,000 members, run with --run-ignored only"]
async fn the_connector_cap_subquery_over_a_thousand_members() {
    let (store, pool, _guard) = support::new_store_with_pool("cap-cost").await;
    let roles = [
        store
            .create_role("a", Permissions::VIEW_CHANNEL, false)
            .await
            .unwrap(),
        store
            .create_role("b", Permissions::SEND_MESSAGES, false)
            .await
            .unwrap(),
        store
            .create_role("c", Permissions::ATTACH_FILES, false)
            .await
            .unwrap(),
    ];
    let mut ids: Vec<UserId> = Vec::new();
    for n in 0..MEMBERS {
        let user = store.create_user(&format!("m{n}"), "M").await.unwrap();
        for role in roles.iter().take(ROLES_EACH) {
            store.assign_role(user.id, *role).await.unwrap();
        }
        ids.push(user.id);
    }
    let channel: ChannelId = store.create_channel("general", "text").await.unwrap().id;

    let mut sum = std::time::Duration::ZERO;
    for _ in 0..RUNS {
        let started = Instant::now();
        let viewers = store.viewers_among(channel, &ids).await.unwrap();
        sum += started.elapsed();
        assert_eq!(viewers.len(), MEMBERS);
    }
    eprintln!(
        "viewers_among over {MEMBERS} members: {:?} mean",
        sum / RUNS
    );

    for (label, cap) in [
        ("with the else branch", WITH_CAP),
        ("without it", WITHOUT_CAP),
    ] {
        let marks = vec!["?"; MEMBERS].join(", ");
        let sql = format!(
            "SELECT u.id AS user_id, {cap} AS cap, r.id AS role_id, r.permissions AS permissions \
             FROM users u LEFT JOIN member_roles mr ON mr.user_id = u.id \
             LEFT JOIN roles r ON r.id = mr.role_id AND r.is_everyone = 0 WHERE u.id IN ({marks})"
        );
        let mut sum = std::time::Duration::ZERO;
        for _ in 0..RUNS {
            let mut query = sqlx::query(sqlx::AssertSqlSafe(sql.clone()));
            for id in &ids {
                query = query.bind(*id);
            }
            let started = Instant::now();
            let rows = query.fetch_all(&pool).await.unwrap();
            sum += started.elapsed();
            assert_eq!(rows.len(), MEMBERS * ROLES_EACH);
            let _ = rows[0].try_get::<Option<i64>, _>("cap").unwrap();
        }
        eprintln!("role query, {label}: {:?} mean", sum / RUNS);
    }
}
