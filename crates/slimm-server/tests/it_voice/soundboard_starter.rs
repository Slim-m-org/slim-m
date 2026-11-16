// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The starter soundboard clips (decision 0118): offered once per Space through
//! the ledger, so a deleted one stays deleted, a taken name or a full Space
//! skips one for good, and two passes at once still offer each clip once.

use axum::Router;
use axum::body::to_bytes;
use axum::http::StatusCode;
use serde_json::Value;
use slimm_server::http::{self, AppState};
use slimm_server::media::Media;
use slimm_server::soundboard::{self, starter};
use slimm_server::store::{MAX_SOUNDBOARD_CLIPS, StarterSeeded, Store};
use tower::ServiceExt;

use super::soundboard::tone;
use crate::support;
use support::app::{Account, call_as, register_account, request_bearer};

const STARTER_COUNT: usize = starter::STARTER_CLIPS.len();

struct Rig {
    store: Store,
    state: AppState,
    router: Router,
    admin: Account,
    _db: support::TestDbGuard,
}

async fn rig() -> Rig {
    rig_with(Media::for_tests()).await
}

async fn rig_with(media: Media) -> Rig {
    let (store, db) = support::new_store("slimm-soundboard-starter").await;
    let admin = register_account(&store, "admin").await;
    let state = support::app::builder(store.clone()).media(media).build();
    Rig {
        store,
        router: http::router(state.clone()),
        state,
        admin,
        _db: db,
    }
}

impl Rig {
    async fn seed(&self) -> StarterSeeded {
        starter::seed(&self.store, &self.state.media).await.unwrap()
    }

    async fn clips(&self, token: &str) -> Vec<Value> {
        let (status, body) = call_as(&self.router, "GET", "/soundboard", token, None).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body.as_array().unwrap().clone()
    }

    async fn names(&self) -> Vec<String> {
        let clips = self.clips(&self.admin.token).await;
        clips
            .iter()
            .map(|c| c["name"].as_str().unwrap().to_owned())
            .collect()
    }

    async fn delete_named(&self, name: &str) {
        let clips = self.clips(&self.admin.token).await;
        let clip = clips.iter().find(|c| c["name"] == name).unwrap();
        let uri = format!("/soundboard/{}", clip["id"].as_str().unwrap());
        let (status, _) = call_as(&self.router, "DELETE", &uri, &self.admin.token, None).await;
        assert_eq!(status, StatusCode::NO_CONTENT);
    }

    async fn add(&self, name: &str, n: usize) {
        soundboard::add_clip(
            &self.store,
            &self.state.media,
            name,
            None,
            tone(n),
            self.admin.id,
        )
        .await
        .unwrap_or_else(|err| panic!("{name}: {err:?}"));
    }
}

fn starter_names() -> Vec<String> {
    starter::STARTER_CLIPS
        .iter()
        .map(|c| c.name.to_owned())
        .collect()
}

fn starter_keys() -> Vec<String> {
    starter::STARTER_CLIPS
        .iter()
        .map(|c| c.key.to_owned())
        .collect()
}

#[tokio::test]
async fn a_fresh_space_gets_every_starter_clip_with_no_uploader_and_its_audio() {
    let rig = rig().await;
    let member = register_account(&rig.store, "member").await;

    let seeded = rig.seed().await;
    assert_eq!(seeded.added, starter_keys());
    assert!(seeded.skipped.is_empty());

    let clips = rig.clips(&member.token).await;
    assert_eq!(clips.len(), STARTER_COUNT);
    for (clip, bundled) in clips.iter().zip(starter::STARTER_CLIPS) {
        assert_eq!(clip["name"], bundled.name);
        assert_eq!(clip["emoji"], bundled.emoji, "{}", bundled.key);
        assert!(clip["uploader_id"].is_null(), "{clip}");
        let uri = format!("/soundboard/{}/audio", clip["id"].as_str().unwrap());
        let response = rig
            .router
            .clone()
            .oneshot(request_bearer("GET", &uri, &member.token))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(response.headers()["content-type"], "audio/mpeg");
        let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        assert_eq!(&body[..], bundled.bytes, "{}", bundled.key);
    }
}

#[tokio::test]
async fn seeding_again_changes_nothing() {
    let rig = rig().await;
    rig.seed().await;
    let before = rig.clips(&rig.admin.token).await;

    assert_eq!(rig.seed().await, StarterSeeded::default());
    assert_eq!(rig.clips(&rig.admin.token).await, before);
}

#[tokio::test]
async fn a_deleted_starter_clip_stays_deleted() {
    let rig = rig().await;
    rig.seed().await;
    rig.delete_named("airhorn").await;

    assert_eq!(rig.seed().await, StarterSeeded::default());
    let names = rig.names().await;
    assert_eq!(names.len(), STARTER_COUNT - 1);
    assert!(!names.iter().any(|n| n == "airhorn"));
}

#[tokio::test]
async fn a_taken_name_keeps_the_existing_clip_and_skips_the_starter_for_good() {
    let rig = rig().await;
    rig.add("AirHorn", 1).await;

    let seeded = rig.seed().await;
    assert_eq!(seeded.skipped, ["airhorn"]);
    assert_eq!(seeded.added.len(), STARTER_COUNT - 1);
    let clips = rig.clips(&rig.admin.token).await;
    assert_eq!(clips.len(), STARTER_COUNT);
    assert_eq!(clips[0]["name"], "AirHorn");
    assert_eq!(clips[0]["uploader_id"], rig.admin.id.to_string());

    rig.delete_named("AirHorn").await;
    rig.seed().await;
    assert!(
        !rig.names()
            .await
            .iter()
            .any(|n| n.eq_ignore_ascii_case("airhorn"))
    );
}

#[tokio::test]
async fn a_nearly_full_space_takes_what_fits_and_records_every_key() {
    let rig = rig().await;
    let existing = MAX_SOUNDBOARD_CLIPS as usize - 8;
    for n in 0..existing {
        rig.add(&format!("clip{n}"), n).await;
    }

    let seeded = rig.seed().await;
    assert_eq!(seeded.added, starter_keys()[..8]);
    assert_eq!(seeded.skipped, starter_keys()[8..]);
    assert_eq!(rig.names().await.len(), MAX_SOUNDBOARD_CLIPS as usize);

    rig.delete_named("clip0").await;
    assert_eq!(rig.seed().await, StarterSeeded::default());
    assert_eq!(rig.names().await.len(), MAX_SOUNDBOARD_CLIPS as usize - 1);
    let offered = rig.store.offered_starter_clips().await.unwrap();
    assert_eq!(offered.len(), STARTER_COUNT);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn two_seeds_at_once_offer_each_clip_once() {
    let rig = rig().await;
    let (one, two) = tokio::join!(
        tokio::spawn({
            let (store, media) = (rig.store.clone(), rig.state.media.clone());
            async move { starter::seed(&store, &media).await.unwrap() }
        }),
        tokio::spawn({
            let (store, media) = (rig.store.clone(), rig.state.media.clone());
            async move { starter::seed(&store, &media).await.unwrap() }
        }),
    );
    let (one, two) = (one.unwrap(), two.unwrap());

    assert_eq!(one.added.len() + two.added.len(), STARTER_COUNT);
    assert!(one.skipped.is_empty() && two.skipped.is_empty());
    assert_eq!(rig.names().await, starter_names());
}

#[tokio::test]
async fn no_room_under_the_storage_ceiling_offers_nothing_until_there_is() {
    let rig = rig_with(Media::for_tests().with_total_ceiling(Some(64 * 1024))).await;

    assert_eq!(rig.seed().await, StarterSeeded::default());
    assert!(rig.names().await.is_empty());
    assert!(rig.store.offered_starter_clips().await.unwrap().is_empty());

    let roomy = rig.state.media.clone().with_total_ceiling(None);
    let seeded = starter::seed(&rig.store, &roomy).await.unwrap();
    assert_eq!(seeded.added, starter_keys());
}
