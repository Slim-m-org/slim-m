// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Steam poller against a local fake of Steam: it sets and clears a
//! member's game, asks only about members who share and could be seen, keeps
//! state through an outage, and the activity route cannot forge a Steam one.

use axum::http::StatusCode;
use serde_json::json;
use slimm_server::http::steam_api::SteamApi;
use slimm_server::http::steam_presence::Poller;
use slimm_server::http::{self, AppState};
use slimm_server::ids::UserId;
use slimm_server::presence::Visibility;
use slimm_server::presence_activity::{Activity, ActivityKind};
use slimm_server::store::LinkedAccount;
use tower::ServiceExt;

use crate::support;
use support::app::request_authed;
use support::steam::{self, Fake};

struct Rig {
    state: AppState,
    fake: Fake,
    api: SteamApi,
    poller: Poller,
    user: UserId,
    token: String,
    _guard: Box<dyn std::any::Any>,
}

async fn rig(name: &str, sharing: bool) -> Rig {
    let (store, guard) = support::new_store(name).await;
    let user = store.create_user("ada", "Ada").await.unwrap();
    let token = store
        .open_session(user.id, "laptop")
        .await
        .unwrap()
        .access_token;
    let account = LinkedAccount {
        provider: "steam".to_owned(),
        external_id: steam::STEAM_ID.to_owned(),
        username: "Ada on Steam".to_owned(),
        display_name: None,
        linked_at: 1,
        avatar_updated_at: None,
        share_activity: false,
    };
    store.save_linked_account(user.id, &account).await.unwrap();
    store
        .set_link_sharing(user.id, "steam", sharing)
        .await
        .unwrap();
    let state = support::app::state(store);
    state.hub.presence().connect(user.id);
    let fake = steam::spawn().await;
    let api = SteamApi::with_bases("key", &fake.base, &fake.base).unwrap();
    Rig {
        state,
        fake,
        api,
        poller: Poller::default(),
        user: user.id,
        token,
        _guard: Box::new(guard),
    }
}

impl Rig {
    fn play(&self, app: u32, name: &str) {
        let mut world = self.fake.world.lock().unwrap();
        world
            .playing
            .insert(steam::STEAM_ID.to_owned(), (app, name.to_owned()));
    }

    fn stop(&self) {
        self.fake.world.lock().unwrap().playing.clear();
    }

    async fn tick(&mut self) {
        self.poller.tick(&self.state, &self.api).await.unwrap();
    }

    fn activity(&self) -> Option<Activity> {
        self.state.hub.presence().activity(self.user)
    }

    fn polled(&self) -> usize {
        self.fake.world.lock().unwrap().asked.len()
    }
}

fn spotify() -> Activity {
    Activity {
        kind: ActivityKind::Listening,
        title: "Song".to_owned(),
        subtitle: None,
        started_at: None,
        source: Some("Spotify".to_owned()),
        art_url: None,
        duration_ms: None,
        position_ms: None,
        position_at: None,
        steam_app_id: None,
    }
}

#[tokio::test]
async fn a_game_is_set_with_its_art_and_cleared_when_it_ends() {
    let mut rig = rig("slimm-steam-poll", true).await;
    rig.play(730, "Counter-Strike 2");
    rig.tick().await;
    let first = rig.activity().expect("a game shows");
    assert_eq!(first.kind, ActivityKind::Playing);
    assert_eq!(first.title, "Counter-Strike 2");
    assert_eq!(first.source.as_deref(), Some("steam"));
    assert_eq!(first.steam_app_id, Some(730));
    assert_eq!(
        first.art_url.as_deref(),
        Some("https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/730/header.jpg")
    );

    rig.tick().await;
    assert_eq!(rig.activity().unwrap().started_at, first.started_at);
    assert_eq!(
        rig.fake.world.lock().unwrap().store_hits,
        1,
        "art is cached"
    );

    rig.stop();
    rig.tick().await;
    assert!(rig.activity().is_none());
}

#[tokio::test]
async fn a_game_clears_when_sharing_ends_between_passes_without_a_clear() {
    let mut rig = rig("slimm-steam-departed", true).await;
    rig.play(730, "Counter-Strike 2");
    rig.tick().await;
    assert!(rig.activity().is_some());
    rig.state
        .store
        .set_link_sharing(rig.user, "steam", false)
        .await
        .unwrap();
    rig.tick().await;
    assert!(rig.activity().is_none(), "a departed sharer keeps no game");
}

#[tokio::test]
async fn relinking_to_another_steam_account_starts_with_sharing_off() {
    let rig = rig("slimm-steam-relink", true).await;
    let store = &rig.state.store;
    let mut account = store.linked_accounts(rig.user).await.unwrap().remove(0);
    assert!(account.share_activity);
    store.save_linked_account(rig.user, &account).await.unwrap();
    assert!(store.linked_accounts(rig.user).await.unwrap()[0].share_activity);
    account.external_id = "76561198000000002".to_owned();
    store.save_linked_account(rig.user, &account).await.unwrap();
    assert!(!store.linked_accounts(rig.user).await.unwrap()[0].share_activity);
}

#[tokio::test]
async fn a_clear_never_removes_spotify() {
    let mut rig = rig("slimm-steam-spotify", true).await;
    rig.state
        .hub
        .presence()
        .set_activity(rig.user, Some(spotify()));
    rig.tick().await;
    assert_eq!(rig.activity().unwrap().source.as_deref(), Some("Spotify"));
}

#[tokio::test]
async fn nobody_is_polled_who_hides_does_not_share_or_is_offline() {
    let mut hidden = rig("slimm-steam-hidden", true).await;
    hidden.play(730, "Counter-Strike 2");
    hidden
        .state
        .hub
        .presence()
        .set_visibility(hidden.user, Visibility::Hidden);
    hidden.tick().await;
    assert_eq!(hidden.polled(), 0);
    assert!(hidden.activity().is_none());

    let mut private = rig("slimm-steam-not-sharing", false).await;
    private.play(730, "Counter-Strike 2");
    private.tick().await;
    assert_eq!(private.polled(), 0);

    let mut offline = rig("slimm-steam-offline", true).await;
    offline.state.hub.presence().disconnect(offline.user);
    offline.tick().await;
    assert_eq!(offline.polled(), 0);
}

#[tokio::test]
async fn turning_hidden_on_removes_a_shown_game() {
    let mut rig = rig("slimm-steam-hide-later", true).await;
    rig.play(730, "Counter-Strike 2");
    rig.tick().await;
    assert!(rig.activity().is_some());
    rig.state
        .hub
        .presence()
        .set_visibility(rig.user, Visibility::Hidden);
    rig.tick().await;
    assert!(rig.activity().is_none());
}

#[tokio::test]
async fn an_outage_keeps_the_last_state_and_reports_an_error() {
    let mut rig = rig("slimm-steam-outage", true).await;
    rig.play(730, "Counter-Strike 2");
    rig.tick().await;
    for code in [429, 503] {
        rig.fake.world.lock().unwrap().fail_with = Some(code);
        rig.stop();
        assert!(rig.poller.tick(&rig.state, &rig.api).await.is_err());
        assert!(rig.activity().is_some(), "{code} must not read as stopped");
    }
}

#[tokio::test]
async fn a_client_cannot_forge_steam_or_replace_a_running_game() {
    let mut rig = rig("slimm-steam-forge", true).await;
    let (state, token) = (rig.state.clone(), rig.token.clone());
    let put = |body: serde_json::Value| {
        let router = http::router(state.clone());
        let req = request_authed("PUT", "/presence/activity", &token, Some(body));
        async move { router.oneshot(req).await.unwrap().status() }
    };
    let forged = json!({ "type": "playing", "title": "x", "source": "steam" });
    assert_eq!(put(forged).await, StatusCode::BAD_REQUEST);
    let with_id = json!({ "type": "playing", "title": "x", "steam_app_id": 730 });
    assert_eq!(put(with_id).await, StatusCode::BAD_REQUEST);
    let art = json!({
        "type": "playing", "title": "x",
        "art_url": "https://cdn.steamstatic.com/steam/apps/730/header.jpg"
    });
    assert_eq!(put(art).await, StatusCode::BAD_REQUEST);

    rig.play(730, "Counter-Strike 2");
    rig.tick().await;
    let track = json!({ "type": "listening", "title": "Song" });
    assert_eq!(put(track).await, StatusCode::NO_CONTENT);
    assert_eq!(rig.activity().unwrap().steam_app_id, Some(730));
}

#[tokio::test]
async fn a_steam_outage_never_writes_the_api_key_into_its_error() {
    let dead = "http://127.0.0.1:9";
    let api = SteamApi::with_bases("the-secret-steam-key", dead, dead).unwrap();
    let Err(error) = api.players(&[steam::STEAM_ID.to_owned()]).await else {
        panic!("nothing listens on the discard port");
    };
    assert!(!error.0.contains("the-secret-steam-key"), "{}", error.0);
    assert!(!error.0.is_empty());
}
