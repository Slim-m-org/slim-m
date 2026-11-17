// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Soundboard calls: add a clip with an emoji, refuse one over the byte limit,
//! list it, rename it and clear its emoji, fetch its audio, remove it.

use serde_json::json;
use slimm_server::soundboard::MAX_CLIP_BYTES;

use super::text;
use crate::response_contract::world::{Contract, Payload};

/// A one-second 8 kHz mono 16-bit wav, silent.
fn wav() -> Vec<u8> {
    let data = 16_000u32;
    let mut out = b"RIFF".to_vec();
    out.extend_from_slice(&(36 + data).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&[1, 0, 1, 0]);
    out.extend_from_slice(&8000u32.to_le_bytes());
    out.extend_from_slice(&16_000u32.to_le_bytes());
    out.extend_from_slice(&[2, 0, 16, 0]);
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data.to_le_bytes());
    out.extend(std::iter::repeat_n(0u8, data as usize));
    out
}

pub(super) async fn soundboard_calls(c: &mut Contract, root: &str) {
    let created = c
        .call(
            "uploadSoundboardClip",
            "POST",
            "/soundboard?name=airhorn&emoji=%F0%9F%93%AF",
            Some(root),
            Payload::Bytes(wav()),
        )
        .await;
    let id = text(&created, "id");
    assert_eq!(text(&created, "emoji"), "\u{1F4EF}");
    c.refuses(
        "uploadSoundboardClip",
        "POST",
        "/soundboard?name=too-big",
        Some(root),
        Payload::Bytes(vec![0; MAX_CLIP_BYTES as usize + 1]),
    )
    .await;
    c.get("listSoundboardClips", "/soundboard", root).await;
    let renamed = c
        .json(
            "renameSoundboardClip",
            "PATCH",
            &format!("/soundboard/{id}"),
            root,
            json!({ "name": "honk", "emoji": null }),
        )
        .await;
    assert!(renamed["emoji"].is_null(), "{renamed}");
    c.call(
        "fetchSoundboardClipAudio",
        "GET",
        &format!("/soundboard/{id}/audio"),
        Some(root),
        Payload::None,
    )
    .await;
    c.call(
        "deleteSoundboardClip",
        "DELETE",
        &format!("/soundboard/{id}"),
        Some(root),
        Payload::None,
    )
    .await;
}
