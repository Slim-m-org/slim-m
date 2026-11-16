// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The starter clips a Space is offered once (decision 0118, "Starter clips").
//!
//! The `soundboard_starter_offered` ledger remembers every key offered, so a
//! deleted starter clip stays deleted and one a later release adds still arrives.

use super::{ValidatedClip, store_bytes, validate};
use crate::ids::SoundClipId;
use crate::media::Media;
use crate::store::{StarterClipRow, StarterSeeded, Store, now_ms};

/// One bundled clip: the ledger key is also the file's stem under `starter/`.
pub struct StarterClip {
    pub key: &'static str,
    pub name: &'static str,
    pub bytes: &'static [u8],
}

macro_rules! starter {
    ($key:literal, $name:literal) => {
        StarterClip {
            key: $key,
            name: $name,
            bytes: include_bytes!(concat!("starter/", $key, ".mp3")),
        }
    };
}

/// The starter set, in the order a fresh Space lists it.
pub const STARTER_CLIPS: &[StarterClip] = &[
    starter!("airhorn", "airhorn"),
    starter!("ba_dum_tss", "ba dum tss"),
    starter!("applause", "applause"),
    starter!("crickets", "crickets"),
    starter!("sad_trombone", "sad trombone"),
    starter!("quack", "quack"),
    starter!("drumroll", "drumroll"),
    starter!("ding", "ding"),
    starter!("wrong_buzzer", "wrong buzzer"),
    starter!("whoosh", "whoosh"),
    starter!("laugh_track", "laugh track"),
    starter!("tada", "tada"),
];

/// Offers every starter clip this Space has not been offered yet, decided in one
/// write transaction so concurrent or interrupted passes offer each exactly once.
pub async fn seed(store: &Store, media: &Media) -> anyhow::Result<StarterSeeded> {
    let offered = store.offered_starter_clips().await?;
    let mut pending: Vec<(&'static str, ValidatedClip)> = Vec::new();
    for clip in STARTER_CLIPS.iter().filter(|c| !offered.contains(c.key)) {
        match validate(clip.name, clip.bytes.to_vec()) {
            Ok(valid) => pending.push((clip.key, valid)),
            Err(err) => {
                tracing::warn!(key = clip.key, error = ?err, "a starter clip failed validation")
            }
        }
    }
    if pending.is_empty() {
        return Ok(StarterSeeded::default());
    }
    let incoming: u64 = pending.iter().map(|(_, c)| c.bytes.len() as u64).sum();
    if !has_room(store, media, incoming).await? {
        tracing::info!("no room under the storage ceiling for the starter soundboard clips");
        return Ok(StarterSeeded::default());
    }
    for (_, clip) in &pending {
        store_bytes(store, media, clip, None).await?;
    }
    let rows: Vec<StarterClipRow<'_>> = pending
        .iter()
        .map(|(key, clip)| StarterClipRow {
            key,
            id: SoundClipId::generate(),
            name: &clip.name,
            sha256: &clip.sha256,
            duration_ms: clip.duration_ms,
        })
        .collect();
    store.seed_sound_clips(&rows).await
}

/// Runs [`seed`] once in the background. Failures are logged, never fatal,
/// and the next start tries again.
pub(crate) fn spawn_seed(store: Store, media: Media) {
    tokio::spawn(async move {
        match seed(&store, &media).await {
            Ok(seeded) if !seeded.added.is_empty() || !seeded.skipped.is_empty() => {
                tracing::info!(
                    added = seeded.added.len(),
                    skipped = seeded.skipped.len(),
                    "offered the starter soundboard clips"
                );
            }
            Ok(_) => {}
            Err(err) => tracing::warn!(error = %err, "starter soundboard clips were not seeded"),
        }
    });
}

/// Whether `incoming` bytes fit under `SLIMM_MAX_TOTAL_ATTACHMENT_BYTES`,
/// counted the way `http::storage_room` counts an upload.
async fn has_room(store: &Store, media: &Media, incoming: u64) -> anyhow::Result<bool> {
    let Some(ceiling) = media.max_total_attachment_bytes() else {
        return Ok(true);
    };
    let pending = media.pending_bytes(None, now_ms()).await?;
    let held = store.total_attachment_bytes().await?.max(0) as u64;
    Ok(held.saturating_add(pending).saturating_add(incoming) <= ceiling)
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::{STARTER_CLIPS, validate};
    use crate::soundboard::{MAX_CLIP_BYTES, MAX_CLIP_MS};

    const CREDITS: &str = include_str!("starter/CREDITS.md");

    #[test]
    fn every_starter_clip_passes_the_checks_an_upload_does() {
        for clip in STARTER_CLIPS {
            let valid = validate(clip.name, clip.bytes.to_vec())
                .unwrap_or_else(|err| panic!("{}: {err:?}", clip.key));
            assert_eq!(
                valid.name, clip.name,
                "{}: the name is not normalised",
                clip.key
            );
            assert_eq!(valid.content_type, "audio/mpeg", "{}", clip.key);
            assert!(
                valid.duration_ms > 0 && valid.duration_ms <= MAX_CLIP_MS,
                "{}",
                clip.key
            );
            assert!(clip.bytes.len() as u64 <= MAX_CLIP_BYTES, "{}", clip.key);
        }
    }

    #[test]
    fn starter_keys_and_names_are_unique_ignoring_case() {
        let keys: HashSet<_> = STARTER_CLIPS.iter().map(|c| c.key).collect();
        let names: HashSet<_> = STARTER_CLIPS
            .iter()
            .map(|c| c.name.to_lowercase())
            .collect();
        assert_eq!(keys.len(), STARTER_CLIPS.len());
        assert_eq!(names.len(), STARTER_CLIPS.len());
    }

    #[test]
    fn every_bundled_file_is_a_credited_starter_clip() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/soundboard/starter");
        let mut files: Vec<String> = std::fs::read_dir(dir)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .filter(|name| name != "CREDITS.md")
            .collect();
        files.sort();
        let mut expected: Vec<String> = STARTER_CLIPS
            .iter()
            .map(|c| format!("{}.mp3", c.key))
            .collect();
        expected.sort();
        assert_eq!(files, expected);
        for clip in STARTER_CLIPS {
            let row = format!("| {}.mp3 | {} | ", clip.key, clip.name);
            assert!(
                CREDITS.lines().any(|line| line.starts_with(&row)),
                "no CREDITS.md row for {}",
                clip.key
            );
        }
    }
}
