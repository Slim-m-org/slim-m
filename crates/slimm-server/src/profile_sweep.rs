// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Reclaiming profile picture files no row points at any more.
//!
//! A deleted account, or a delete whose unlink failed, leaves its avatar, banner or linked-account
//! picture behind. Writers hold [`Media::profile_guard`] across the file and its row, so a file
//! checked here under the same guard is either wanted or old enough to be a leak.

use std::time::{Duration, SystemTime};

use uuid::Uuid;

use crate::ids::UserId;
use crate::media::Media;
use crate::store::Store;

/// A temp file older than this belongs to no request still running.
const TEMP_FILE_GRACE: Duration = Duration::from_secs(60 * 60);
/// A file written before its row exists briefly by design.
const ORPHAN_FILE_GRACE: Duration = Duration::from_secs(24 * 60 * 60);

/// What follows `link-` in a Discord picture's file name.
const DISCORD_LINK: &str = "discord-";

enum Kind {
    Avatar,
    Banner,
    Linked(&'static str),
}

/// The owner and kind of a per-user picture file name; `None` for the Space's own files.
fn classify(name: &str) -> Option<(UserId, Kind)> {
    let user = |id: &str| Uuid::parse_str(id).ok().map(UserId);
    if let Some(id) = name.strip_prefix("banner-") {
        return user(id).map(|id| (id, Kind::Banner));
    }
    if let Some(rest) = name.strip_prefix("link-") {
        let id = rest.strip_prefix(DISCORD_LINK)?;
        return user(id).map(|id| (id, Kind::Linked("discord")));
    }
    user(name).map(|id| (id, Kind::Avatar))
}

async fn is_wanted(store: &Store, user: UserId, kind: &Kind) -> anyhow::Result<bool> {
    Ok(match kind {
        Kind::Avatar => store
            .user_profile(user)
            .await?
            .is_some_and(|profile| profile.avatar_updated_at.is_some()),
        Kind::Banner => store
            .user_profile(user)
            .await?
            .is_some_and(|profile| profile.banner_updated_at.is_some()),
        Kind::Linked(provider) => store.has_linked_avatar(user, provider).await?,
    })
}

/// Removes stale temp files and old profile pictures nothing points at; returns how many went.
pub async fn collect_profile_files(
    store: &Store,
    media: &Media,
    now: SystemTime,
) -> anyhow::Result<usize> {
    let mut removed = 0;
    for (name, modified) in media.profile_files().await? {
        let age = now.duration_since(modified).unwrap_or_default();
        if name.starts_with(".tmp-") {
            if age >= TEMP_FILE_GRACE && media.remove_profile_file(&name).await.is_ok() {
                removed += 1;
            }
            continue;
        }
        let Some((user, kind)) = classify(&name) else {
            continue;
        };
        if age < ORPHAN_FILE_GRACE {
            continue;
        }
        let _guard = media.profile_guard().await;
        if !is_wanted(store, user, &kind).await? {
            media.remove_profile_file(&name).await?;
            removed += 1;
        }
    }
    Ok(removed)
}
