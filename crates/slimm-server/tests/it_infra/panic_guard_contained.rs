// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A panic in a blocking job a handler awaits is caught, so its fallback runs.

use slimm_server::http::panic_guard;

#[tokio::test]
async fn a_contained_blocking_panic_is_caught_and_the_next_job_runs() {
    panic_guard::install_hook();

    let caught = panic_guard::spawn_blocking_contained(|| -> u8 { panic!("a decoder bug") }).await;
    let next = panic_guard::spawn_blocking_contained(|| 7).await;

    assert!(caught.is_err());
    assert_eq!(next.unwrap(), 7);
}

#[tokio::test]
async fn only_the_contained_job_is_exempt_from_the_abort() {
    let inside = panic_guard::spawn_blocking_contained(panic_guard::panic_ends_process)
        .await
        .unwrap();
    let outside = tokio::task::spawn_blocking(panic_guard::panic_ends_process)
        .await
        .unwrap();

    assert!(!inside, "a contained job's panic does not end the process");
    assert!(outside, "any other blocking job still does");
}

#[test]
fn a_jpeg_decoder_worker_thread_panic_does_not_end_the_process() {
    let worker = std::thread::Builder::new()
        .name("worker thread for component 0".into())
        .spawn(panic_guard::panic_ends_process)
        .unwrap()
        .join()
        .unwrap();
    let other = std::thread::spawn(panic_guard::panic_ends_process)
        .join()
        .unwrap();

    assert!(!worker, "the decoder's worker thread is exempt");
    assert!(other, "any other thread still ends the process");
}
