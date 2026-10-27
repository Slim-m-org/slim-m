// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Searching the text inside attachments: text and code files and the text
//! layer of PDFs are extracted in the background and matched by message
//! search, an unreadable PDF is skipped without being retried, and the index
//! follows the attachment when it is deleted.

use axum::Router;
use lopdf::content::{Content, Operation};
use lopdf::{Document, Object, Stream, dictionary};
use serde_json::{Value, json};
use slimm_server::media::Media;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use tower::ServiceExt;
use uuid::Uuid;

use crate::fixtures::*;

pub(super) struct World {
    pub(super) app: Router,
    pub(super) media: Media,
    pub(super) store: Store,
    pub(super) pool: sqlx::SqlitePool,
    pub(super) extractor: slimm_server::TextExtractor,
    pub(super) token: String,
    pub(super) channel: String,
    _guard: crate::support::TestDbGuard,
}

pub(super) async fn world() -> World {
    world_with_upload_cap(crate::fixtures::TEST_MAX_ATTACHMENT_BYTES).await
}

pub(super) async fn world_with_upload_cap(cap: u64) -> World {
    let (store, pool, guard) = new_store_and_pool().await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::SEND_MESSAGES)
                .union(Permissions::ATTACH_FILES),
            true,
        )
        .await
        .unwrap();
    let (token, _) = register(&store, "alice").await;
    let channel = store
        .create_channel("files", "text")
        .await
        .unwrap()
        .id
        .to_string();
    let media = media_for_test().with_attachment_max(cap);
    World {
        app: app_with_media(store.clone(), media.clone()),
        media,
        store,
        pool,
        extractor: extractor(std::time::Duration::from_millis(1)),
        token,
        channel,
        _guard: guard,
    }
}

impl World {
    pub(super) async fn send(&self, content: &str, name: &str, bytes: Vec<u8>) -> (String, String) {
        let uploaded = upload(&self.app, &self.token, name, bytes).await;
        let id = Uuid::now_v7().to_string();
        let sent = self
            .app
            .clone()
            .oneshot(request_json(
                "POST",
                &format!("/channels/{}/messages", self.channel),
                &self.token,
                json!({ "id": id, "content": content, "attachment_ids": [uploaded["id"]] }),
            ))
            .await
            .unwrap();
        assert_eq!(sent.status(), 200);
        (id, uploaded["id"].as_str().unwrap().to_owned())
    }

    pub(super) async fn search(&self, q: &str) -> Vec<Value> {
        let response = self
            .app
            .clone()
            .oneshot(request_plain(
                "GET",
                &format!("/channels/{}/messages/search?q={q}", self.channel),
                &self.token,
            ))
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        json_body(response).await.as_array().unwrap().clone()
    }

    pub(super) async fn extract(&self) -> usize {
        self.extractor.run_pass(&self.store, &self.media).await
    }
}

pub(super) fn pdf_saying(text: &str) -> Vec<u8> {
    let mut doc = Document::with_version("1.5");
    let pages_id = doc.new_object_id();
    let font_id = doc.add_object(dictionary! {
        "Type" => "Font", "Subtype" => "Type1", "BaseFont" => "Courier",
    });
    let resources_id = doc.add_object(dictionary! { "Font" => dictionary! { "F1" => font_id } });
    let content = Content {
        operations: vec![
            Operation::new("BT", vec![]),
            Operation::new("Tf", vec!["F1".into(), 24.into()]),
            Operation::new("Td", vec![50.into(), 700.into()]),
            Operation::new("Tj", vec![Object::string_literal(text)]),
            Operation::new("ET", vec![]),
        ],
    };
    let content_id = doc.add_object(Stream::new(dictionary! {}, content.encode().unwrap()));
    let page_id = doc.add_object(dictionary! {
        "Type" => "Page", "Parent" => pages_id, "Contents" => content_id,
    });
    doc.objects.insert(
        pages_id,
        Object::Dictionary(dictionary! {
            "Type" => "Pages", "Kids" => vec![page_id.into()], "Count" => 1,
            "Resources" => resources_id,
            "MediaBox" => vec![0.into(), 0.into(), 595.into(), 842.into()],
        }),
    );
    let catalog_id = doc.add_object(dictionary! { "Type" => "Catalog", "Pages" => pages_id });
    doc.trailer.set("Root", catalog_id);
    let mut bytes = Vec::new();
    doc.save_to(&mut bytes).unwrap();
    bytes
}

#[tokio::test]
async fn a_word_only_inside_a_text_file_finds_the_message_and_names_the_attachment() {
    let w = world().await;
    let (message, attachment) = w
        .send(
            "see attached",
            "notes.txt",
            b"the zebrafish migration plan".to_vec(),
        )
        .await;

    assert!(
        w.search("zebrafish").await.is_empty(),
        "nothing is searchable before the background pass has run"
    );
    assert_eq!(w.extract().await, 1);

    let found = w.search("zebrafish").await;
    assert_eq!(found.len(), 1);
    assert_eq!(found[0]["id"], message);
    assert_eq!(found[0]["matched_attachment_id"], attachment);

    let by_own_text = w.search("attached").await;
    assert_eq!(by_own_text.len(), 1);
    assert!(
        by_own_text[0].get("matched_attachment_id").is_none(),
        "the message's own text matched, so the attachment is not why it was found"
    );
}

#[tokio::test]
async fn code_files_are_read_by_extension() {
    let w = world().await;
    w.send("code", "main.rs", b"fn quarantine_widget() {}".to_vec())
        .await;
    w.extract().await;
    assert_eq!(w.search("quarantine_widget").await.len(), 1);
}

#[tokio::test]
async fn a_pdf_text_layer_is_searchable() {
    let w = world().await;
    let (message, _) = w
        .send("report", "report.pdf", pdf_saying("Hello quokka sanctuary"))
        .await;
    w.extract().await;
    let found = w.search("quokka").await;
    assert_eq!(found.len(), 1);
    assert_eq!(found[0]["id"], message);
}

#[tokio::test]
async fn an_unreadable_pdf_and_a_binary_file_are_skipped_once_and_not_retried() {
    let w = world().await;
    w.send("bad", "broken.pdf", b"%PDF-1.4 this is not a pdf".to_vec())
        .await;
    w.send("bin", "blob.txt", vec![0u8, 1, 2, 3, 0, 0, 7]).await;
    assert_eq!(w.extract().await, 2);
    assert_eq!(
        w.extract().await,
        0,
        "a processed attachment is not looked at again"
    );
    assert!(w.search("pdf").await.is_empty());
}

#[tokio::test]
async fn deleting_the_attachment_removes_its_text_from_the_index() {
    let (path, guard) = crate::support::TestDbGuard::new("slimm-attachment-text-cascade");
    let config = slimm_server::config::Config {
        port: 0,
        database_path: path,
        hash_concurrency: 2,
        ..slimm_server::config::Config::default()
    };
    let pool = slimm_server::db::connect(&config).await.unwrap();
    let store = Store::new(pool.clone());
    let sha = [7u8; 32];
    store
        .store_attachment(&sha, 4, "text/plain", "a.txt", None)
        .await
        .unwrap();
    store
        .record_attachment_text(&sha, Some("ephemeral gazelle"))
        .await
        .unwrap();
    let indexed = |pool: sqlx::SqlitePool| async move {
        sqlx::query_scalar::<_, i64>(
            "SELECT COUNT(*) FROM attachment_text_fts WHERE attachment_text_fts MATCH 'gazelle'",
        )
        .fetch_one(&pool)
        .await
        .unwrap()
    };
    assert_eq!(indexed(pool.clone()).await, 1);

    sqlx::query("DELETE FROM attachments")
        .execute(&pool)
        .await
        .unwrap();
    assert_eq!(indexed(pool).await, 0);
    drop(guard);
}

#[tokio::test]
async fn a_message_that_became_encrypted_is_not_found_through_its_attachment() {
    let w = world().await;
    let (message, _) = w
        .send(
            "secret",
            "notes.txt",
            b"the zebrafish migration plan".to_vec(),
        )
        .await;
    w.extract().await;
    assert_eq!(w.search("zebrafish").await.len(), 1);

    sqlx::query("UPDATE messages SET is_encrypted = 1 WHERE id = ?")
        .bind(Uuid::parse_str(&message).unwrap())
        .execute(&w.pool)
        .await
        .unwrap();
    assert!(w.search("zebrafish").await.is_empty(), "search arm");
    let id = slimm_server::ids::MessageId(Uuid::parse_str(&message).unwrap());
    let labelled = w
        .store
        .attachments_matching_text(&[id], "zebrafish")
        .await
        .unwrap();
    assert!(labelled.is_empty(), "found-in label");
}
