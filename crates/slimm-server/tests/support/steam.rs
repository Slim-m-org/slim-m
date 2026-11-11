// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A local fake of Steam's OpenID endpoint, Web API and store, so the Steam
//! suites never reach the real one.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use axum::Router;
use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::routing::{get, post};
use serde_json::{Value, json};

pub const OP_ENDPOINT: &str = "https://steamcommunity.com/openid/login";
pub const STEAM_ID: &str = "76561198000000001";

/// What the fake serves, and what it was asked.
#[derive(Default)]
pub struct World {
    /// SteamID to (app id, game name).
    pub playing: HashMap<String, (u32, String)>,
    /// A status the Web API answers with instead of data.
    pub fail_with: Option<u16>,
    /// The SteamIDs each summaries call asked for.
    pub asked: Vec<Vec<String>>,
    pub store_hits: u32,
}

pub type Shared = Arc<Mutex<World>>;

pub struct Fake {
    pub base: String,
    pub world: Shared,
}

pub async fn spawn() -> Fake {
    let world: Shared = Arc::default();
    let app = Router::new()
        .route("/openid/login", post(check_authentication))
        .route("/ISteamUser/GetPlayerSummaries/v2/", get(summaries))
        .route("/api/appdetails", get(app_details))
        .with_state(world.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    Fake {
        base: format!("http://{addr}"),
        world,
    }
}

async fn check_authentication(body: String) -> String {
    assert!(body.contains("openid.mode=check_authentication"), "{body}");
    if body.contains("openid.sig=goodsig") {
        "ns:http://specs.openid.net/auth/2.0\nis_valid:true\n".to_owned()
    } else {
        "ns:http://specs.openid.net/auth/2.0\nis_valid:false\n".to_owned()
    }
}

async fn summaries(
    State(world): State<Shared>,
    Query(q): Query<HashMap<String, String>>,
) -> impl IntoResponse {
    let mut world = world.lock().unwrap();
    let ids: Vec<String> = q["steamids"].split(',').map(str::to_owned).collect();
    world.asked.push(ids.clone());
    if let Some(code) = world.fail_with {
        return (StatusCode::from_u16(code).unwrap(), String::new()).into_response();
    }
    let players: Vec<Value> = ids
        .iter()
        .map(|id| match world.playing.get(id) {
            Some((app, name)) => json!({
                "steamid": id, "personaname": "Ada on Steam",
                "gameid": app.to_string(), "gameextrainfo": name
            }),
            None => json!({ "steamid": id, "personaname": "Ada on Steam" }),
        })
        .collect();
    axum::Json(json!({ "response": { "players": players } })).into_response()
}

async fn app_details(
    State(world): State<Shared>,
    Query(q): Query<HashMap<String, String>>,
) -> axum::Json<Value> {
    world.lock().unwrap().store_hits += 1;
    let id = &q["appids"];
    let image = format!(
        "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/{id}/header.jpg?t=1"
    );
    axum::Json(json!({ id: { "success": true, "data": { "header_image": image } } }))
}

/// The query a browser brings back from Steam for `state`, with `sig` as the signature.
pub fn sign_in_params(return_to: &str, claimed: &str, sig: &str) -> Vec<(String, String)> {
    [
        ("openid.ns", "http://specs.openid.net/auth/2.0"),
        ("openid.mode", "id_res"),
        ("openid.op_endpoint", OP_ENDPOINT),
        ("openid.claimed_id", claimed),
        ("openid.identity", claimed),
        ("openid.return_to", return_to),
        (
            "openid.signed",
            "signed,op_endpoint,claimed_id,identity,return_to",
        ),
        ("openid.sig", sig),
    ]
    .into_iter()
    .map(|(k, v)| (k.to_owned(), v.to_owned()))
    .collect()
}
