// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Profile picture files: stored at the size clients draw, changed together with their row, and
//! reclaimed by the sweep once nothing points at them.

use std::io::Cursor;
use std::time::{Duration, SystemTime};

use axum::body::Body;
use axum::http::{Request, StatusCode};
use image::{DynamicImage, ImageBuffer, ImageFormat, Rgb};
use slimm_server::blobs::collect_garbage;
use slimm_server::media::Media;
use slimm_server::store::Store;
use tower::ServiceExt;

use crate::support;
use support::app::{builder, register_id_token};

fn big_png(side: u32) -> Vec<u8> {
    let img = ImageBuffer::from_pixel(side, side, Rgb([20u8, 90, 160]));
    let mut out = Cursor::new(Vec::new());
    DynamicImage::ImageRgb8(img)
        .write_to(&mut out, ImageFormat::Png)
        .unwrap();
    out.into_inner()
}

fn request(method: &str, uri: &str, token: &str, body: Vec<u8>) -> Request<Body> {
    Request::builder()
        .method(method)
        .uri(uri)
        .header("authorization", format!("Bearer {token}"))
        .body(Body::from(body))
        .unwrap()
}

async fn world(
    prefix: &str,
) -> (
    Store,
    Media,
    axum::Router,
    support::TestDbGuard,
    support::TestDirGuard,
) {
    let (store, db_guard) = support::new_store(prefix).await;
    let (root, dir_guard) = support::TestDirGuard::new(prefix);
    let media = Media::new(&root, 10 * 1024 * 1024).unwrap();
    let router = builder(store.clone()).media(media.clone()).router();
    (store, media, router, db_guard, dir_guard)
}

fn later() -> SystemTime {
    SystemTime::now() + Duration::from_secs(2 * 24 * 60 * 60)
}

#[tokio::test]
async fn a_large_avatar_is_stored_at_the_size_clients_draw() {
    let (store, media, router, _db, _dir) = world("slimm-profile-fit").await;
    let (id, token) = register_id_token(&store, "alice").await;

    let sent = big_png(4096);
    let response = router
        .oneshot(request("POST", "/me/avatar", &token, sent.clone()))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let stored = media.read_avatar(&id.to_string()).await.unwrap();
    let decoded = image::load_from_memory(&stored).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (512, 512));
    assert!(stored.len() < sent.len());
}

#[tokio::test]
async fn a_delete_waits_for_an_upload_in_flight_and_leaves_row_and_file_agreeing() {
    let (store, media, router, _db, _dir) = world("slimm-profile-race").await;
    let (id, token) = register_id_token(&store, "alice").await;

    for (route, kind) in [("/me/avatar", "avatar"), ("/me/banner", "banner")] {
        let guard = media.profile_guard().await;
        let delete = tokio::spawn(router.clone().oneshot(request(
            "DELETE",
            route,
            &token,
            Vec::new(),
        )));
        tokio::time::sleep(Duration::from_millis(150)).await;
        assert!(!delete.is_finished(), "{kind} delete ran under the guard");
        drop(guard);
        assert_eq!(
            delete.await.unwrap().unwrap().status(),
            StatusCode::NO_CONTENT
        );
    }
    let profile = store.user_profile(id).await.unwrap().unwrap();
    assert!(profile.avatar_updated_at.is_none() && profile.banner_updated_at.is_none());
}

#[tokio::test]
async fn the_sweep_removes_picture_files_nothing_points_at() {
    let (store, media, router, _db, _dir) = world("slimm-profile-sweep").await;
    let (kept, token) = register_id_token(&store, "alice").await;
    let (gone, _) = register_id_token(&store, "bob").await;
    let kept_id = kept.to_string();
    let gone_id = gone.to_string();

    let upload = router
        .oneshot(request("POST", "/me/avatar", &token, big_png(64)))
        .await
        .unwrap();
    assert_eq!(upload.status(), StatusCode::OK);

    media.write_avatar(&gone_id, vec![1]).await.unwrap();
    media.write_user_banner(&gone_id, vec![1]).await.unwrap();
    media
        .write_linked_avatar("discord", &gone_id, vec![1])
        .await
        .unwrap();
    media.write_user_banner(&kept_id, vec![1]).await.unwrap();

    let removed = collect_garbage(&store, &media, later()).await.unwrap();
    assert_eq!(
        removed, 4,
        "bob's avatar, banner and link, and alice's unrecorded banner"
    );
    assert!(media.read_avatar(&kept_id).await.is_ok());
    assert!(media.read_avatar(&gone_id).await.is_err());

    media.write_avatar(&gone_id, vec![1]).await.unwrap();
    let fresh = collect_garbage(&store, &media, SystemTime::now())
        .await
        .unwrap();
    assert_eq!(fresh, 0, "a file inside the grace window stays");
}
