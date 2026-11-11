// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The two Steam endpoints the server reads: the Web API's player summaries
//! (who is in which game) and the store's app details (the header image).
//! Base URLs are injectable so tests point both at one local fake.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::Value;

const API_BASE: &str = "https://api.steampowered.com";
const STORE_BASE: &str = "https://store.steampowered.com";
const TIMEOUT: Duration = Duration::from_secs(10);
const MISS_TTL: Duration = Duration::from_secs(60 * 60);
const MAX_CACHED_APPS: usize = 4096;
const MAX_NAME_CHARS: usize = 64;

/// One member's row from `GetPlayerSummaries`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Player {
    pub steam_id: String,
    pub persona: Option<String>,
    /// The app being played; absent when idle or when the profile hides it.
    pub game_id: Option<u32>,
    pub game_name: Option<String>,
}

/// Why a call failed; every kind makes the poller back off.
#[derive(Debug)]
pub struct SteamError(pub String);

#[derive(Clone)]
pub struct SteamApi {
    inner: Arc<Inner>,
}

struct Inner {
    key: String,
    api_base: String,
    store_base: String,
    http: reqwest::Client,
    art: Mutex<HashMap<u32, ArtEntry>>,
}

struct ArtEntry {
    url: Option<String>,
    fetched: Instant,
}

#[derive(Deserialize)]
struct Summaries {
    response: SummariesBody,
}

#[derive(Deserialize)]
struct SummariesBody {
    #[serde(default)]
    players: Vec<RawPlayer>,
}

#[derive(Deserialize)]
struct RawPlayer {
    steamid: String,
    personaname: Option<String>,
    gameid: Option<String>,
    gameextrainfo: Option<String>,
}

impl SteamApi {
    pub fn new(key: &str) -> anyhow::Result<Self> {
        Self::with_bases(key, API_BASE, STORE_BASE)
    }

    pub fn with_bases(key: &str, api_base: &str, store_base: &str) -> anyhow::Result<Self> {
        let http = reqwest::Client::builder()
            .timeout(TIMEOUT)
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        Ok(Self {
            inner: Arc::new(Inner {
                key: key.to_owned(),
                api_base: api_base.trim_end_matches('/').to_owned(),
                store_base: store_base.trim_end_matches('/').to_owned(),
                http,
                art: Mutex::new(HashMap::new()),
            }),
        })
    }

    /// Summaries for up to 100 SteamIDs. A failure is an error, never an empty
    /// list, so a Steam outage is not read as everyone having stopped playing.
    pub async fn players(&self, ids: &[String]) -> Result<Vec<Player>, SteamError> {
        let url = format!("{}/ISteamUser/GetPlayerSummaries/v2/", self.inner.api_base);
        let response = self
            .inner
            .http
            .get(url)
            .query(&[
                ("key", self.inner.key.as_str()),
                ("steamids", &ids.join(",")),
            ])
            .send()
            .await
            .map_err(|e| SteamError(e.to_string()))?;
        let status = response.status();
        if !status.is_success() {
            return Err(SteamError(format!("steam answered {status}")));
        }
        let body: Summaries = response
            .json()
            .await
            .map_err(|e| SteamError(e.to_string()))?;
        Ok(body
            .response
            .players
            .into_iter()
            .map(Player::from)
            .collect())
    }

    /// The persona name for one SteamID, for the link row; `None` on any failure.
    pub async fn persona(&self, steam_id: &str) -> Option<String> {
        let players = self.players(&[steam_id.to_owned()]).await.ok()?;
        players.into_iter().find_map(|p| p.persona)
    }

    /// The store header image for `app_id`, without its cache-busting query,
    /// or `None` when the store has none. Each app is asked about once; a miss
    /// is remembered for an hour.
    pub async fn header_image(&self, app_id: u32) -> Option<String> {
        if let Some(cached) = self.cached_art(app_id) {
            return cached;
        }
        let found = self.fetch_header(app_id).await;
        let mut art = self
            .inner
            .art
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if art.len() >= MAX_CACHED_APPS {
            art.clear();
        }
        art.insert(
            app_id,
            ArtEntry {
                url: found.clone(),
                fetched: Instant::now(),
            },
        );
        found
    }

    fn cached_art(&self, app_id: u32) -> Option<Option<String>> {
        let art = self
            .inner
            .art
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let entry = art.get(&app_id)?;
        (entry.url.is_some() || entry.fetched.elapsed() < MISS_TTL).then(|| entry.url.clone())
    }

    async fn fetch_header(&self, app_id: u32) -> Option<String> {
        let url = format!("{}/api/appdetails", self.inner.store_base);
        let response = self
            .inner
            .http
            .get(url)
            .query(&[
                ("appids", app_id.to_string().as_str()),
                ("filters", "basic"),
            ])
            .send()
            .await
            .ok()?;
        if !response.status().is_success() {
            return None;
        }
        let body: Value = response.json().await.ok()?;
        let entry = body.get(app_id.to_string())?;
        let image = entry.get("data")?.get("header_image")?.as_str()?;
        let bare = image.split(['?', '#']).next()?;
        crate::presence_activity::is_steam_art_url(bare).then(|| bare.to_owned())
    }
}

impl From<RawPlayer> for Player {
    fn from(raw: RawPlayer) -> Self {
        let clip = |s: String| s.chars().take(MAX_NAME_CHARS).collect::<String>();
        Player {
            steam_id: raw.steamid,
            persona: raw.personaname.filter(|n| !n.trim().is_empty()).map(clip),
            game_id: raw.gameid.and_then(|id| id.parse().ok()),
            game_name: raw.gameextrainfo.filter(|n| !n.trim().is_empty()),
        }
    }
}
