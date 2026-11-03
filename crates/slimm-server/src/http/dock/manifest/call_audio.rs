// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The manifest's `call_audio` block (decision 0105): the module's own words
//! about what it does with a call and what it keeps, shown word for word to
//! everyone in a call before they agree.

use std::collections::HashSet;

use serde::Deserialize;

use super::{ManifestError, bounded, malformed};

const CALL_AUDIO: &str = "call.audio";
/// The add-on API level that introduced the capability.
const MIN_ADDON_API: i64 = 4;
const MIN_CHARS: usize = 20;
const MAX_CHARS: usize = 240;

#[derive(Deserialize)]
pub(super) struct RawCallAudio {
    purpose: String,
    keeps: String,
    #[serde(default)]
    permission: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::http) struct ManifestCallAudio {
    pub(in crate::http) purpose: String,
    pub(in crate::http) keeps: String,
    /// One of the module's own permission keys a member needs to start a session.
    pub(in crate::http) permission: Option<String>,
}

/// `call.audio` and its block come together, with `addon_api` 4 or higher.
pub(super) fn validate_call_audio(
    raw: Option<RawCallAudio>,
    capabilities: &[String],
    addon_api: i64,
    permission_keys: &HashSet<String>,
) -> Result<Option<ManifestCallAudio>, ManifestError> {
    let declares = capabilities.iter().any(|c| c == CALL_AUDIO);
    let Some(raw) = raw else {
        if declares {
            return Err(malformed(
                "the call.audio capability needs a call_audio block",
            ));
        }
        return Ok(None);
    };
    if !declares {
        return Err(malformed(
            "call_audio is only meaningful with the call.audio capability",
        ));
    }
    if addon_api < MIN_ADDON_API {
        return Err(malformed("call.audio needs \"addon_api\": 4 or higher"));
    }
    let purpose = words(&raw.purpose, "call_audio.purpose")?;
    let keeps = words(&raw.keeps, "call_audio.keeps")?;
    let permission = raw.permission.map(|p| p.trim().to_owned());
    if let Some(key) = &permission
        && !permission_keys.contains(key)
    {
        return Err(malformed(
            "call_audio.permission must name one of the module's own permissions",
        ));
    }
    Ok(Some(ManifestCallAudio {
        purpose,
        keeps,
        permission,
    }))
}

fn words(value: &str, field: &str) -> Result<String, ManifestError> {
    let text = bounded(value, MAX_CHARS, field)?;
    if text.chars().count() < MIN_CHARS {
        return Err(malformed(&format!(
            "{field} must be {MIN_CHARS} to {MAX_CHARS} characters"
        )));
    }
    Ok(text)
}

/// The block in an installed module's stored manifest, if it has one.
pub(in crate::http) fn declared_in(manifest_json: &str) -> Option<ManifestCallAudio> {
    super::parse_manifest(manifest_json.as_bytes())
        .ok()?
        .call_audio
}

#[cfg(test)]
mod tests {
    use super::*;

    fn caps(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_owned()).collect()
    }

    fn raw(purpose: &str, keeps: &str, permission: Option<&str>) -> RawCallAudio {
        RawCallAudio {
            purpose: purpose.into(),
            keeps: keeps.into(),
            permission: permission.map(Into::into),
        }
    }

    const PURPOSE: &str = "Writes down what is said in the call.";
    const KEEPS: &str = "The transcript text, for 30 days.";

    fn keys() -> HashSet<String> {
        ["start".to_owned()].into()
    }

    #[test]
    fn a_complete_block_with_a_known_permission_is_accepted() {
        let ok = validate_call_audio(
            Some(raw(PURPOSE, KEEPS, Some("start"))),
            &caps(&["call.audio"]),
            4,
            &keys(),
        )
        .unwrap()
        .unwrap();
        assert_eq!(ok.permission.as_deref(), Some("start"));
        assert_eq!(ok.purpose, PURPOSE);
    }

    #[test]
    fn the_capability_and_the_block_come_together() {
        assert!(validate_call_audio(None, &caps(&["call.audio"]), 4, &keys()).is_err());
        assert!(
            validate_call_audio(Some(raw(PURPOSE, KEEPS, None)), &caps(&[]), 4, &keys()).is_err()
        );
        assert_eq!(validate_call_audio(None, &caps(&[]), 0, &keys()), Ok(None));
    }

    #[test]
    fn it_needs_add_on_api_four() {
        let low = validate_call_audio(
            Some(raw(PURPOSE, KEEPS, None)),
            &caps(&["call.audio"]),
            3,
            &keys(),
        );
        assert!(low.is_err());
    }

    #[test]
    fn each_text_is_twenty_to_two_forty_characters() {
        for (purpose, keeps) in [
            ("too short", KEEPS),
            (PURPOSE, "short"),
            (&"x".repeat(241), KEEPS),
            (PURPOSE, &"x".repeat(241)),
        ] {
            let got = validate_call_audio(
                Some(raw(purpose, keeps, None)),
                &caps(&["call.audio"]),
                4,
                &keys(),
            );
            assert!(got.is_err(), "{purpose:?} / {keeps:?}");
        }
        let edge = "x".repeat(240);
        assert!(
            validate_call_audio(
                Some(raw(&edge, &"y".repeat(20), None)),
                &caps(&["call.audio"]),
                4,
                &keys()
            )
            .is_ok()
        );
    }

    #[test]
    fn the_permission_must_be_one_the_module_declares() {
        let got = validate_call_audio(
            Some(raw(PURPOSE, KEEPS, Some("admin"))),
            &caps(&["call.audio"]),
            4,
            &keys(),
        );
        assert!(got.is_err());
    }
}
