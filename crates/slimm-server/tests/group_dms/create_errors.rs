// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a failed group create reports: only a taken id is a conflict.

use axum::http::StatusCode;
use serde_json::json;
use uuid::Uuid;

use crate::rig::*;

async fn create_with_id(h: &Harness, id: &str, by: &Person, others: &[&Person]) -> StatusCode {
    let ids: Vec<&str> = others.iter().map(|p| p.id.as_str()).collect();
    let body = json!({ "id": id, "user_ids": ids });
    call(h, "POST", "/dms/groups", by, Some(body)).await.0
}

#[tokio::test]
async fn a_database_failure_creating_the_group_is_not_reported_as_a_taken_id() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    sqlx::query(
        "CREATE TRIGGER refuse_dm_channels BEFORE INSERT ON channels
         WHEN NEW.kind = 'dm' BEGIN SELECT RAISE(ABORT, 'disk is on fire'); END",
    )
    .execute(&h.pool)
    .await
    .unwrap();

    let id = Uuid::now_v7().to_string();
    let status = create_with_id(&h, &id, &a, &[&b, &c]).await;
    assert_eq!(status, StatusCode::INTERNAL_SERVER_ERROR);
}

#[tokio::test]
async fn an_id_already_used_by_a_channel_is_a_conflict() {
    let h = harness().await;
    let _admin = person(&h, "admin").await;
    let (a, b, c) = (
        person(&h, "alice").await,
        person(&h, "bob").await,
        person(&h, "carol").await,
    );
    let channel = group_of(&h, &a, &[&b, &c]).await;
    sqlx::query("UPDATE channels SET deleted_at = 1 WHERE id = ?")
        .bind(Uuid::parse_str(&channel).unwrap())
        .execute(&h.pool)
        .await
        .unwrap();

    let status = create_with_id(&h, &channel, &a, &[&b, &c]).await;
    assert_eq!(status, StatusCode::CONFLICT);
}
