// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The PDF child process and the extraction sweep around it: a decompression
//! bomb and a hung parse are contained, an attempt is recorded before the
//! parse starts, and a transient failure is retried a bounded number of times.

use std::io::Write;
use std::time::{Duration, Instant};

use flate2::Compression;
use flate2::write::ZlibEncoder;
use lopdf::{Document, Object, Stream, dictionary};
use slimm_server::{PdfParse, PdfWorker};

use super::text_search::{pdf_saying, world, world_with_upload_cap};
use crate::fixtures::extractor;

const BOMB_INFLATED_BYTES: usize = 1536 * 1024 * 1024;

fn real_worker(wall: Duration) -> PdfWorker {
    PdfWorker::command(
        env!("CARGO_BIN_EXE_slimm-server").into(),
        vec![slimm_server::PDF_WORKER_ARG.into()],
        wall,
    )
}

fn shell_worker(script: &str, wall: Duration) -> PdfWorker {
    PdfWorker::command("sh".into(), vec!["-c".into(), script.into()], wall)
}

/// A valid PDF whose one content stream is a few MiB on disk and 1.5 GiB inflated.
fn flate_bomb() -> Vec<u8> {
    let mut encoder = ZlibEncoder::new(Vec::new(), Compression::fast());
    let zeros = vec![0u8; 1024 * 1024];
    for _ in 0..(BOMB_INFLATED_BYTES / zeros.len()) {
        encoder.write_all(&zeros).unwrap();
    }
    let compressed = encoder.finish().unwrap();
    assert!(
        compressed.len() < 7 * 1024 * 1024,
        "the bomb must fit the upload cap"
    );

    let mut doc = Document::with_version("1.5");
    let pages_id = doc.new_object_id();
    let content_id = doc.add_object(Stream::new(
        dictionary! { "Filter" => "FlateDecode" },
        compressed,
    ));
    let page_id = doc.add_object(dictionary! {
        "Type" => "Page", "Parent" => pages_id, "Contents" => content_id,
    });
    doc.objects.insert(
        pages_id,
        Object::Dictionary(dictionary! {
            "Type" => "Pages", "Kids" => vec![page_id.into()], "Count" => 1,
            "MediaBox" => vec![0.into(), 0.into(), 595.into(), 842.into()],
        }),
    );
    let catalog_id = doc.add_object(dictionary! { "Type" => "Catalog", "Pages" => pages_id });
    doc.trailer.set("Root", catalog_id);
    let mut bytes = Vec::new();
    doc.save_to(&mut bytes).unwrap();
    bytes
}

fn peak_resident_mib() -> u64 {
    let status = std::fs::read_to_string("/proc/self/status").unwrap();
    let line = status.lines().find(|l| l.starts_with("VmHWM:")).unwrap();
    let kib: u64 = line.split_whitespace().nth(1).unwrap().parse().unwrap();
    kib / 1024
}

#[tokio::test]
async fn a_flate_bomb_is_stopped_in_the_child_and_the_parent_stays_small() {
    let bomb = flate_bomb();
    let started = Instant::now();
    let parsed = real_worker(Duration::from_secs(20))
        .parse(bomb, || async {})
        .await;
    assert_eq!(parsed, PdfParse::Limited);
    assert!(
        started.elapsed() < Duration::from_secs(19),
        "stopped by the limit, not the clock"
    );
    assert!(
        peak_resident_mib() < BOMB_INFLATED_BYTES as u64 / 1024 / 1024 / 2,
        "the parent never inflated it"
    );
}

#[tokio::test]
async fn the_worker_still_reads_a_normal_pdf() {
    let parsed = real_worker(Duration::from_secs(20))
        .parse(pdf_saying("Hello quokka sanctuary"), || async {})
        .await;
    assert!(matches!(parsed, PdfParse::Text(text) if text.contains("quokka")));
}

#[tokio::test]
async fn a_hung_parse_is_killed_at_the_wall_clock() {
    let started = Instant::now();
    let parsed = shell_worker("sleep 60", Duration::from_millis(300))
        .parse(vec![1, 2, 3], || async {})
        .await;
    assert_eq!(parsed, PdfParse::Limited);
    assert!(started.elapsed() < Duration::from_secs(10));
}

#[tokio::test]
async fn a_worker_that_cannot_start_is_unavailable_not_hostile() {
    let missing = PdfWorker::command("/nonexistent/slimm".into(), vec![], Duration::from_secs(1));
    assert_eq!(
        missing.parse(vec![], || async {}).await,
        PdfParse::Unavailable
    );
}

#[tokio::test]
async fn a_bomb_attachment_is_marked_nothing_to_extract_and_not_looked_at_again() {
    let mut w = world_with_upload_cap(8 * 1024 * 1024).await;
    w.extractor = slimm_server::TextExtractor::with_worker(
        Some(real_worker(Duration::from_secs(20))),
        Duration::from_millis(1),
    );
    w.send("bomb", "bomb.pdf", flate_bomb()).await;
    assert_eq!(w.extract().await, 1);
    assert_eq!(w.extract().await, 0);
    assert!(
        w.search("bomb").await.len() == 1,
        "the message itself stays searchable"
    );
}

#[tokio::test]
async fn the_attempt_is_recorded_before_the_parse_starts() {
    let mut w = world().await;
    w.extractor = slimm_server::TextExtractor::with_worker(
        Some(shell_worker("sleep 2", Duration::from_secs(10))),
        Duration::from_millis(1),
    );
    w.send("slow", "slow.pdf", pdf_saying("anything")).await;
    let store = w.store.clone();
    let media = w.media.clone();
    let extractor = std::sync::Arc::new(std::mem::replace(
        &mut w.extractor,
        extractor(Duration::from_millis(1)),
    ));
    let running = tokio::spawn({
        let extractor = extractor.clone();
        async move { extractor.run_pass(&store, &media).await }
    });
    let mut marked = false;
    for _ in 0..30 {
        tokio::time::sleep(Duration::from_millis(50)).await;
        if w.store
            .attachments_awaiting_text(5)
            .await
            .unwrap()
            .is_empty()
        {
            marked = true;
            break;
        }
    }
    assert!(
        marked && !running.is_finished(),
        "marked while the parse is still running"
    );
    running.abort();
}

#[tokio::test]
async fn a_transient_read_failure_is_retried_not_recorded() {
    let mut w = world().await;
    w.extractor = extractor(Duration::from_millis(150));
    let (_, attachment) = w
        .send("note", "note.txt", b"the okapi crossing".to_vec())
        .await;
    let original = w.media.read_attachment(&attachment).await.unwrap();
    w.media.delete_attachment(&attachment).await.unwrap();

    assert_eq!(w.extract().await, 0);
    assert_eq!(w.store.attachments_awaiting_text(5).await.unwrap().len(), 1);
    assert_eq!(w.extract().await, 0, "backing off, not hot-looping");

    std::fs::write(w.media.attachment_file(&attachment), original).unwrap();
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(w.extract().await, 1);
    assert_eq!(w.search("okapi").await.len(), 1);
}

#[tokio::test]
async fn a_file_that_keeps_failing_is_given_up_after_a_bounded_number_of_tries() {
    let mut w = world().await;
    w.extractor = extractor(Duration::from_millis(1));
    let (_, attachment) = w.send("note", "note.txt", b"gone".to_vec()).await;
    w.media.delete_attachment(&attachment).await.unwrap();

    let mut settled = 0;
    let mut passes = 0;
    while settled == 0 && passes < 10 {
        tokio::time::sleep(Duration::from_millis(20)).await;
        settled = w.extract().await;
        passes += 1;
    }
    assert_eq!((settled, passes), (1, 3));
    assert!(
        w.store
            .attachments_awaiting_text(5)
            .await
            .unwrap()
            .is_empty()
    );
}
