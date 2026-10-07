// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The seven `ON DELETE SET NULL` authorship columns `account_anonymization.rs`
//! and its siblings did not yet pin behaviourally. `account_deletion_coverage.rs`
//! records that each has an `Anonymize` decision; only a test that creates the
//! row, deletes the account and reads the column back proves the statement
//! behind that decision still runs and still targets the right column.

mod support;
use support::reports::StoreReportExt;

use slimm_server::ids::{CanvasObjectId, CanvasOpId, MessageId};
use slimm_server::store::{CanvasOpRequest, NewMessage, PlaceRequest, ReportSubject, Store};
use sqlx::SqlitePool;

async fn new_store() -> (Store, SqlitePool, support::TestDbGuard) {
    let (path, guard) = support::TestDbGuard::new("slimm-anon-authorship");
    let config = slimm_server::config::Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..slimm_server::config::Config::default()
    };
    let pool = slimm_server::db::connect(&config)
        .await
        .expect("connect + migrate");
    (Store::new(pool.clone()), pool, guard)
}

/// One authorship column, read back by the BLOB key of the row that carries it.
struct Probe {
    sql: &'static str,
    key: Vec<u8>,
}

async fn read(pool: &SqlitePool, probe: &Probe) -> Option<Vec<u8>> {
    sqlx::query_scalar(probe.sql)
        .bind(&probe.key)
        .fetch_one(pool)
        .await
        .unwrap_or_else(|err| panic!("{}: {err}", probe.sql))
}

async fn invite_creator(pool: &SqlitePool, code: &str) -> Option<Vec<u8>> {
    sqlx::query_scalar("SELECT created_by FROM invites WHERE code = ?")
        .bind(code)
        .fetch_one(pool)
        .await
        .unwrap()
}

/// Seeds one row per column with `bob` as its author/actor/issuer, checks each
/// names bob (or the fixture proves nothing), deletes bob, and checks each is
/// null while the row itself survives.
#[tokio::test]
async fn delete_account_anonymizes_every_remaining_authorship_column() {
    let (store, pool, _guard) = new_store().await;
    let admin = store
        .create_account("root", "Root", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(admin.id).await.unwrap();
    let channel = store.list_channels().await.unwrap()[0].id;
    let bob = store
        .create_account("bob", "Bob", "not-a-real-hash")
        .await
        .unwrap();
    let bob_bytes = bob.id.0.as_bytes().to_vec();

    let object = CanvasObjectId::generate();
    store
        .place_canvas_object(
            channel,
            bob.id,
            object,
            PlaceRequest {
                kind: "stroke",
                bounds: (0.0, 0.0, 1.0, 1.0),
                props: "{}",
                attachment: None,
            },
        )
        .await
        .expect("placed");
    let op = CanvasOpId::generate();
    store
        .submit_canvas_op(
            channel,
            bob.id,
            op,
            true,
            CanvasOpRequest::Remove(vec![object]),
        )
        .await
        .expect("removed");
    let invite = store.create_invite(bob.id, None, None, None).await.unwrap();
    store.issue_reset_code(bob.id, admin.id).await.unwrap();
    let reported = store
        .send_message(NewMessage::plain(
            channel,
            admin.id,
            MessageId::generate(),
            "hi",
        ))
        .await
        .unwrap()
        .message
        .id;
    let report = store
        .file_report(admin.id, ReportSubject::Message(reported), "not ok")
        .await
        .unwrap();
    assert!(
        store
            .resolve_report(report, bob.id, "dismissed")
            .await
            .unwrap()
    );
    store
        .record_code_run(reported, 0, "code-exec", "run", true, "2", bob.id)
        .await
        .unwrap();
    let app = MessageId::generate();
    store
        .send_app_message(channel, bob.id, app, "/tic-tac-toe", "tic-tac-toe", "play")
        .await
        .expect("app surface sent");

    let probes = [
        Probe {
            sql: "SELECT author_id FROM canvas_objects WHERE id = ?",
            key: object.0.as_bytes().to_vec(),
        },
        Probe {
            sql: "SELECT actor_id FROM canvas_ops WHERE id = ?",
            key: op.0.as_bytes().to_vec(),
        },
        Probe {
            sql: "SELECT issued_by FROM password_reset_codes WHERE user_id = ?",
            key: admin.id.0.as_bytes().to_vec(),
        },
        Probe {
            sql: "SELECT resolved_by FROM reports WHERE id = ?",
            key: report.as_bytes().to_vec(),
        },
        Probe {
            sql: "SELECT ran_by FROM code_runs WHERE message_id = ?",
            key: reported.0.as_bytes().to_vec(),
        },
        Probe {
            sql: "SELECT created_by FROM app_surfaces WHERE message_id = ?",
            key: app.0.as_bytes().to_vec(),
        },
    ];
    for probe in &probes {
        assert_eq!(
            read(&pool, probe).await.as_deref(),
            Some(bob_bytes.as_slice()),
            "fixture must name bob before deletion: {}",
            probe.sql
        );
    }
    assert_eq!(
        invite_creator(&pool, &invite.code).await,
        Some(bob_bytes.clone()),
        "fixture must name bob as the invite's creator"
    );

    store.delete_account(bob.id).await.unwrap();

    for probe in &probes {
        assert_eq!(
            read(&pool, probe).await,
            None,
            "the deleted account must be anonymized, and the row must survive: {}",
            probe.sql
        );
    }
    assert_eq!(
        invite_creator(&pool, &invite.code).await,
        None,
        "a deleted account must not stay named as an invite's creator"
    );
}
