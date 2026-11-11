// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Steam poller (decision 0115): every 30 seconds it asks Steam what the
//! members who linked Steam and chose to share are playing, and sets or clears
//! their activity. Only members who are connected and not hidden are asked
//! about, so nobody is looked up while nobody could see the answer.

use std::collections::HashMap;
use std::time::Duration;

use super::AppState;
use super::steam_api::{Player, SteamApi, SteamError};
use super::steam_link::SteamLinks;
use crate::hub::Event;
use crate::ids::UserId;
use crate::presence::Visibility;
use crate::presence_activity::{Activity, ActivityKind, SOURCE_STEAM, is_steam_art_url};
use crate::store::now_ms;

pub const POLL_EVERY: Duration = Duration::from_secs(30);
const MAX_BACKOFF: Duration = Duration::from_secs(300);
const BATCH: usize = 100;
const PROVIDER: &str = "steam";

/// What the poller remembers between passes: when each member's current game
/// was first seen, which is what the elapsed time on their card counts from.
#[derive(Default)]
pub struct Poller {
    seen: HashMap<UserId, (u32, i64)>,
}

/// Runs the poller for the life of the server, doubling the wait after a
/// failed pass (up to five minutes) and resetting it after a good one.
pub fn spawn(state: AppState, steam: SteamLinks) {
    tokio::spawn(async move {
        let mut poller = Poller::default();
        let mut wait = POLL_EVERY;
        loop {
            tokio::time::sleep(wait).await;
            wait = match poller.tick(&state, steam.api()).await {
                Ok(()) => POLL_EVERY,
                Err(error) => {
                    tracing::warn!(error = %error.0, "steam poll failed; backing off");
                    (wait * 2).min(MAX_BACKOFF)
                }
            };
        }
    });
}

/// Removes a Steam activity the poller set, for when sharing is switched off
/// or the link is removed. Anything else the member is showing is left alone.
pub fn clear_steam_activity(state: &AppState, user_id: UserId) {
    let tracker = state.hub.presence();
    if tracker.activity(user_id).is_some_and(|a| a.is_steam())
        && tracker.set_activity(user_id, None)
    {
        state.hub.publish(Event::presence_changed(user_id));
    }
}

impl Poller {
    /// One pass. On error nothing was changed, so members keep what they showed.
    pub async fn tick(&mut self, state: &AppState, api: &SteamApi) -> Result<(), SteamError> {
        let links = state
            .store
            .sharing_links(PROVIDER)
            .await
            .map_err(|e| SteamError(e.to_string()))?;
        let (eligible, ineligible) = self.split_eligible(state, links).await?;
        for user_id in ineligible {
            self.seen.remove(&user_id);
            clear_steam_activity(state, user_id);
        }
        let mut players: HashMap<String, Player> = HashMap::new();
        for chunk in eligible.chunks(BATCH) {
            let ids: Vec<String> = chunk.iter().map(|(_, id)| id.clone()).collect();
            for player in api.players(&ids).await? {
                players.insert(player.steam_id.clone(), player);
            }
        }
        for (user_id, steam_id) in eligible {
            let playing = players
                .get(&steam_id)
                .and_then(|p| Some((p.game_id?, p.game_name.clone()?)));
            match playing {
                Some((app_id, name)) => self.show(state, api, user_id, app_id, &name).await,
                None => {
                    self.seen.remove(&user_id);
                    clear_steam_activity(state, user_id);
                }
            }
        }
        Ok(())
    }

    /// Splits sharers into those worth asking Steam about (connected and not
    /// hidden) and those whose Steam activity, if any, should go.
    async fn split_eligible(
        &self,
        state: &AppState,
        links: Vec<(UserId, String)>,
    ) -> Result<(Vec<(UserId, String)>, Vec<UserId>), SteamError> {
        let tracker = state.hub.presence();
        let unknown: Vec<UserId> = links
            .iter()
            .map(|(id, _)| *id)
            .filter(|id| tracker.is_connected(*id) && tracker.visibility(*id).is_none())
            .collect();
        let stored = state
            .store
            .presence_visibility_many(&unknown)
            .await
            .map_err(|e| SteamError(e.to_string()))?;
        let (mut eligible, mut ineligible) = (Vec::new(), Vec::new());
        for (user_id, steam_id) in links {
            let visibility = tracker
                .visibility(user_id)
                .or_else(|| stored.get(&user_id).copied());
            if tracker.is_connected(user_id) && visibility != Some(Visibility::Hidden) {
                eligible.push((user_id, steam_id));
            } else {
                ineligible.push(user_id);
            }
        }
        Ok((eligible, ineligible))
    }

    async fn show(
        &mut self,
        state: &AppState,
        api: &SteamApi,
        user_id: UserId,
        app_id: u32,
        name: &str,
    ) {
        let started_at = match self.seen.get(&user_id) {
            Some((seen_app, at)) if *seen_app == app_id => *at,
            _ => now_ms(),
        };
        self.seen.insert(user_id, (app_id, started_at));
        let art_url = api.header_image(app_id).await;
        let activity = Activity {
            kind: ActivityKind::Playing,
            title: name
                .chars()
                .take(crate::presence_activity::MAX_TEXT_CHARS)
                .collect(),
            subtitle: None,
            started_at: Some(started_at),
            source: Some(SOURCE_STEAM.to_owned()),
            art_url: art_url.filter(|u| is_steam_art_url(u)),
            duration_ms: None,
            position_ms: None,
            position_at: None,
            steam_app_id: Some(app_id),
        };
        if activity.validate().is_err() {
            return;
        }
        if state.hub.presence().set_activity(user_id, Some(activity)) {
            state.hub.publish(Event::presence_changed(user_id));
        }
    }
}
