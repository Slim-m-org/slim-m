// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The caller's own talk statistics, worked out on request from their own transcript lines (decision 0113).
//! There is no user parameter: nobody can ask for anyone else's numbers, an administrator and a bot included.

use axum::Router;
use axum::extract::State;
use axum::http::request::Parts;
use axum::routing::get;
use jiff::tz::TimeZone;
use serde::{Deserialize, Serialize};

use super::AppState;
use super::error::ApiError;
use super::extract::{Authed, Json, Query, enforce, require_human};
use super::messages::parse_uuid;
use super::voice::voice_transcripts::readable;
use crate::call_stats::{DAY_BUCKET_LIMIT_DAYS, Stats, Tally, window_start};
use crate::ids::CallTranscriptId;
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::TranscriptionMode;

const MAX_DAYS: i64 = 3650;
const DAY_MS: i64 = 86_400_000;

/// Members whose stats are being worked out; a second request from one waits its turn as a 429.
static READING: std::sync::LazyLock<
    std::sync::Mutex<std::collections::HashSet<crate::ids::UserId>>,
> = std::sync::LazyLock::new(Default::default);

/// Holds one member's place in [`READING`] until dropped, so one member never holds two scans of their history.
struct Reading(crate::ids::UserId);

impl Reading {
    fn start(user: crate::ids::UserId) -> Option<Self> {
        let mut busy = READING
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        busy.insert(user).then(|| Self(user))
    }
}

impl Drop for Reading {
    fn drop(&mut self) {
        READING
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&self.0);
    }
}

/// The call-stats route, mounted by [`super::router`].
pub fn routes() -> Router<AppState> {
    Router::new().route("/me/call-stats", get(read))
}

#[derive(Deserialize)]
struct Params {
    days: Option<i64>,
    tz: Option<String>,
    transcript_id: Option<String>,
}

#[derive(Serialize)]
struct PhraseDto {
    phrase: &'static str,
    count: i64,
}

#[derive(Serialize)]
struct FillersDto {
    total: i64,
    per_100_words: f64,
    phrases: Vec<PhraseDto>,
}

#[derive(Serialize)]
struct LanguageDto {
    code: String,
    talk_ms: i64,
    share: f64,
    pace: Option<f64>,
    unit: &'static str,
}

#[derive(Serialize)]
struct BucketDto {
    date: String,
    talk_ms: i64,
    words: i64,
}

#[derive(Serialize)]
struct BucketsDto {
    size: &'static str,
    items: Vec<BucketDto>,
}

#[derive(Serialize)]
struct CallStatsDto {
    since: Option<i64>,
    calls: i64,
    talk_ms: i64,
    words: i64,
    characters: i64,
    words_per_minute: Option<f64>,
    fillers: Option<FillersDto>,
    languages: Vec<LanguageDto>,
    buckets: BucketsDto,
    retention_days: Option<i64>,
}

fn dto(stats: Stats, retention_days: Option<i64>) -> CallStatsDto {
    CallStatsDto {
        since: stats.since,
        calls: stats.calls,
        talk_ms: stats.talk_ms,
        words: stats.words,
        characters: stats.characters,
        words_per_minute: stats.words_per_minute,
        fillers: stats.fillers.map(|f| FillersDto {
            total: f.total,
            per_100_words: f.per_100_words,
            phrases: f
                .phrases
                .into_iter()
                .map(|(phrase, count)| PhraseDto { phrase, count })
                .collect(),
        }),
        languages: stats
            .languages
            .into_iter()
            .map(|l| LanguageDto {
                code: l.code,
                talk_ms: l.talk_ms,
                share: l.share,
                pace: l.pace,
                unit: l.unit,
            })
            .collect(),
        buckets: BucketsDto {
            size: if stats.weekly { "week" } else { "day" },
            items: stats
                .buckets
                .into_iter()
                .map(|b| BucketDto {
                    date: b.date,
                    talk_ms: b.talk_ms,
                    words: b.words,
                })
                .collect(),
        },
        retention_days,
    }
}

async fn read(
    State(state): State<AppState>,
    parts: Parts,
    Authed(ctx): Authed,
    Query(params): Query<Params>,
) -> Result<Json<CallStatsDto>, ApiError> {
    let class = if params.transcript_id.is_some() {
        Class::AuthedRead
    } else {
        Class::Write
    };
    enforce(&state, &parts, Some(&ctx), class)?;
    require_human(&state, ctx.user_id).await?;
    if params.days.is_some_and(|d| !(1..=MAX_DAYS).contains(&d)) {
        return Err(ApiError::BadRequest("days must be between 1 and 3650"));
    }
    let zone = match params.tz.as_deref() {
        None => TimeZone::UTC,
        Some(name) => TimeZone::get(name)
            .map_err(|_| ApiError::BadRequest("tz must be an IANA time zone name"))?,
    };
    let only = match params.transcript_id.as_deref() {
        None => None,
        Some(raw) => {
            let needs = Permissions::VIEW_CHANNEL.union(Permissions::VIEW_TRANSCRIPTS);
            readable(&state, ctx.user_id, raw, needs).await?;
            Some(CallTranscriptId(parse_uuid(raw)?))
        }
    };
    let _reading = Reading::start(ctx.user_id).ok_or(ApiError::TooManyRequests)?;
    let retention = state.store.call_transcript_retention_days().await?;
    let now = crate::store::now_ms();
    let mut tally = Tally::new(zone);
    if state.store.call_transcription().await? != TranscriptionMode::Off {
        let from = window_start(now, params.days).unwrap_or(0);
        state
            .store
            .for_each_own_call_line(ctx.user_id, from, only, |line| tally.add(&line))
            .await?;
    }
    let weekly = match params.days {
        Some(days) => days > DAY_BUCKET_LIMIT_DAYS,
        None => spans_weeks(&tally, now),
    };
    Ok(Json(dto(tally.finish(weekly), retention)))
}

fn spans_weeks(tally: &Tally, now: i64) -> bool {
    tally
        .first_line_at()
        .is_some_and(|at| (now - at) / DAY_MS > DAY_BUCKET_LIMIT_DAYS)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_member_holds_one_scan_of_their_history_at_a_time() {
        let user = crate::ids::UserId::generate();
        let first = Reading::start(user).expect("the first scan starts");
        assert!(Reading::start(user).is_none());
        assert!(Reading::start(crate::ids::UserId::generate()).is_some());
        drop(first);
        assert!(Reading::start(user).is_some());
    }
}
