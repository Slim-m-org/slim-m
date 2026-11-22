// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `canvas-tile` extension point: a module tile people place on a voice canvas.
//! It is add-on API 6, so a manifest naming one must say so.

use super::{ManifestError, ManifestExtensionPoint, malformed};

pub(super) const KIND: &str = crate::store::CANVAS_TILE_POINT;

/// The level that added canvas tiles.
const LEVEL: u32 = 6;

/// Refuses a `canvas-tile` from a manifest that does not declare `"addon_api": 6` or higher.
pub(super) fn require_level(
    points: &[ManifestExtensionPoint],
    addon_api: u32,
) -> Result<(), ManifestError> {
    if addon_api < LEVEL && points.iter().any(|p| p.kind == KIND) {
        return Err(malformed(
            "a canvas-tile extension point needs \"addon_api\": 6 or higher",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::super::parse_manifest;
    use super::super::tests::GOOD_MANIFEST;

    fn manifest(addon_api: Option<i64>, tile: Value) -> String {
        let mut m: Value = serde_json::from_str(GOOD_MANIFEST).unwrap();
        let points = m["extension_points"].as_array_mut().unwrap();
        points.push(tile);
        if let Some(level) = addon_api {
            m["addon_api"] = json!(level);
        }
        m.to_string()
    }

    fn tile() -> Value {
        json!({"kind": "canvas-tile", "name": "Scoreboard", "permission": "run", "command": "run"})
    }

    fn refusal(text: &str) -> String {
        match parse_manifest(text.as_bytes()) {
            Ok(_) => panic!("expected a refusal"),
            Err(err) => format!("{err:?}"),
        }
    }

    #[test]
    fn a_tile_on_level_six_is_accepted_with_its_command_and_permission() {
        let parsed = parse_manifest(manifest(Some(6), tile()).as_bytes()).unwrap();
        let point = parsed
            .extension_points
            .iter()
            .find(|p| p.kind == "canvas-tile")
            .unwrap();
        assert_eq!(point.command.as_deref(), Some("run"));
        assert_eq!(point.permission.as_deref(), Some("run"));
    }

    #[test]
    fn a_tile_below_level_six_is_refused() {
        assert!(refusal(&manifest(Some(5), tile())).contains("6 or higher"));
        assert!(refusal(&manifest(None, tile())).contains("canvas-tile"));
    }

    #[test]
    fn a_tile_needs_a_declared_command_and_permission() {
        let no_command = json!({"kind": "canvas-tile", "name": "Scoreboard", "permission": "run"});
        assert!(refusal(&manifest(Some(6), no_command)).contains("command"));
        let stranger = json!({"kind": "canvas-tile", "name": "Scoreboard", "permission": "nope", "command": "run"});
        assert!(refusal(&manifest(Some(6), stranger)).contains("permission"));
    }

    #[test]
    fn two_tiles_may_not_share_a_name() {
        let mut m: Value = serde_json::from_str(&manifest(Some(6), tile())).unwrap();
        m["extension_points"].as_array_mut().unwrap().push(tile());
        assert!(refusal(&m.to_string()).contains("declared twice"));
    }
}
