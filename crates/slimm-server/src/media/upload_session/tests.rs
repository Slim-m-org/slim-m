// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use super::*;

use futures_util::stream;

struct Dirs {
    root: PathBuf,
    uploads: Uploads,
}

impl Drop for Dirs {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn dirs() -> Dirs {
    let root = std::env::temp_dir().join(format!("slimm-upload-session-test-{}", Uuid::now_v7()));
    let uploads_dir = root.join("uploads");
    let attachments_dir = root.join("attachments");
    std::fs::create_dir_all(&uploads_dir).unwrap();
    std::fs::create_dir_all(&attachments_dir).unwrap();
    Dirs {
        uploads: Uploads::new(uploads_dir, attachments_dir),
        root,
    }
}

fn meta(size: u64) -> UploadMeta {
    UploadMeta {
        user_id: Uuid::now_v7().to_string(),
        filename: "big.iso".into(),
        size,
        created_at: 1_000,
    }
}

fn body(parts: &[&[u8]]) -> impl Stream<Item = Result<Vec<u8>, io::Error>> {
    stream::iter(parts.iter().map(|p| Ok(p.to_vec())).collect::<Vec<_>>())
}

#[tokio::test]
async fn parts_in_order_assemble_the_file_and_hash_it_whole() {
    let d = dirs();
    let id = d.uploads.create(meta(10)).await.unwrap();
    assert_eq!(d.uploads.append(id, 0, body(&[b"hello"])).await.unwrap(), 5);
    assert_eq!(
        d.uploads
            .append(id, 5, body(&[b"wor", b"ld"]))
            .await
            .unwrap(),
        10
    );

    let done = d.uploads.finish(id).await.unwrap().expect("complete");
    assert_eq!(done.size, 10);
    assert_eq!(done.hex_id, to_hex(&Sha256::digest(b"helloworld")));
    assert_eq!(done.sniff_prefix, b"helloworld");

    d.uploads.place(id, &done.hex_id).await.unwrap();
    let stored = std::fs::read(d.root.join("attachments").join(&done.hex_id)).unwrap();
    assert_eq!(stored, b"helloworld");
    assert!(
        d.uploads.status(id).await.unwrap().is_none(),
        "the session is gone"
    );
}

#[tokio::test]
async fn a_retried_part_at_a_stale_offset_is_refused_with_the_real_one() {
    let d = dirs();
    let id = d.uploads.create(meta(10)).await.unwrap();
    d.uploads.append(id, 0, body(&[b"hello"])).await.unwrap();
    match d.uploads.append(id, 0, body(&[b"hello"])).await {
        Err(AppendError::OffsetMismatch(5)) => {}
        other => panic!("expected the real offset, got {other:?}"),
    }
    assert_eq!(d.uploads.status(id).await.unwrap().unwrap().1, 5);
}

#[tokio::test]
async fn a_part_past_the_declared_size_is_refused() {
    let d = dirs();
    let id = d.uploads.create(meta(4)).await.unwrap();
    assert!(matches!(
        d.uploads.append(id, 0, body(&[b"hello"])).await,
        Err(AppendError::TooLarge)
    ));
}

#[tokio::test]
async fn a_cut_stream_keeps_what_arrived_so_the_client_resumes_from_there() {
    let d = dirs();
    let id = d.uploads.create(meta(10)).await.unwrap();
    let cut = stream::iter(vec![
        Ok(b"hel".to_vec()),
        Err(io::Error::other("connection reset")),
    ]);
    assert!(matches!(
        d.uploads.append(id, 0, cut).await,
        Err(AppendError::Body)
    ));
    assert_eq!(d.uploads.status(id).await.unwrap().unwrap().1, 3);
    assert_eq!(
        d.uploads.append(id, 3, body(&[b"loworld"])).await.unwrap(),
        10
    );
}

#[tokio::test]
async fn an_incomplete_session_does_not_finish() {
    let d = dirs();
    let id = d.uploads.create(meta(10)).await.unwrap();
    d.uploads.append(id, 0, body(&[b"hello"])).await.unwrap();
    assert!(d.uploads.finish(id).await.unwrap().is_none());
}

#[tokio::test]
async fn a_session_being_written_refuses_a_second_writer() {
    let d = dirs();
    let id = d.uploads.create(meta(10)).await.unwrap();
    let held = d.uploads.claim(id).expect("first claim");
    assert!(matches!(
        d.uploads.append(id, 0, body(&[b"hello"])).await,
        Err(AppendError::Busy)
    ));
    drop(held);
    assert_eq!(d.uploads.append(id, 0, body(&[b"hello"])).await.unwrap(), 5);
}

#[tokio::test]
async fn the_sweep_drops_only_expired_sessions() {
    let d = dirs();
    let ttl = UPLOAD_SESSION_TTL.as_millis() as i64;
    let old = d.uploads.create(meta(10)).await.unwrap();
    let fresh = d
        .uploads
        .create(UploadMeta {
            created_at: 1_000 + ttl,
            ..meta(10)
        })
        .await
        .unwrap();

    assert_eq!(d.uploads.sweep_expired(1_001 + ttl).await.unwrap(), 1);
    assert!(d.uploads.status(old).await.unwrap().is_none());
    assert!(d.uploads.status(fresh).await.unwrap().is_some());
}

#[tokio::test]
async fn open_sessions_are_counted_per_member() {
    let d = dirs();
    let mine = meta(10);
    d.uploads.create(mine.clone()).await.unwrap();
    d.uploads.create(mine.clone()).await.unwrap();
    d.uploads.create(meta(10)).await.unwrap();
    assert_eq!(
        d.uploads
            .open_sessions_for(mine.user_id.clone())
            .await
            .unwrap(),
        2
    );
}

#[tokio::test]
async fn completion_uses_the_hash_carried_from_the_parts() {
    let d = dirs();
    let id = d.uploads.create(meta(10)).await.unwrap();
    d.uploads
        .append(id, 0, body(&[b"helloworld"]))
        .await
        .unwrap();
    let data = d.root.join("uploads").join(id.to_string()).join(DATA_FILE);
    std::fs::write(&data, b"XXXXXXXXXX").unwrap();

    let done = d.uploads.finish(id).await.unwrap().expect("complete");
    assert_eq!(
        done.hex_id,
        to_hex(&Sha256::digest(b"helloworld")),
        "the bytes as they arrived, not a re-read",
    );
}

#[tokio::test]
async fn a_session_that_outlived_a_restart_is_re_read_from_disk() {
    let d = dirs();
    let id = d.uploads.create(meta(10)).await.unwrap();
    d.uploads.append(id, 0, body(&[b"hello"])).await.unwrap();

    let restarted = Uploads::new(d.root.join("uploads"), d.root.join("attachments"));
    assert_eq!(
        restarted.append(id, 5, body(&[b"world"])).await.unwrap(),
        10
    );
    let done = restarted.finish(id).await.unwrap().expect("complete");
    assert_eq!(done.hex_id, to_hex(&Sha256::digest(b"helloworld")));
    assert_eq!(done.sniff_prefix, b"helloworld");
}
