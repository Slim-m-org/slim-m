// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Soundboard calls: add a clip, list it, rename it, fetch its audio, remove it.

use serde_json::json;

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
            "/soundboard?name=airhorn",
            Some(root),
            Payload::Bytes(wav()),
        )
        .await;
    let id = text(&created, "id");
    c.get("listSoundboardClips", "/soundboard", root).await;
    c.json(
        "renameSoundboardClip",
        "PATCH",
        &format!("/soundboard/{id}"),
        root,
        json!({ "name": "honk" }),
    )
    .await;
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
