// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `panel` extension point (decision 0131): which level it needs and how many a module may declare.

use super::{ManifestError, ManifestExtensionPoint, malformed};
use crate::http::module_panels::{PANEL_API, PANEL_KIND};

const MAX_PANELS: usize = 2;

/// A panel needs `"addon_api": 6`, so a level 5 host refuses the module rather than installing it without the panel.
pub(super) fn check_panels(
    points: &[ManifestExtensionPoint],
    addon_api: u32,
) -> Result<(), ManifestError> {
    let panels = points.iter().filter(|p| p.kind == PANEL_KIND).count();
    if panels == 0 {
        return Ok(());
    }
    if addon_api < PANEL_API {
        return Err(malformed(&format!(
            "a panel extension point needs \"addon_api\": {PANEL_API} or higher"
        )));
    }
    if panels > MAX_PANELS {
        return Err(malformed(&format!(
            "a module may declare at most {MAX_PANELS} panels"
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::super::tests::GOOD_MANIFEST;
    use super::super::{ManifestError, parse_manifest};

    const RUN: &str =
        r#"{"kind": "command", "name": "run", "description": "runs it", "permission": "run"}"#;

    fn with_panels(addon_api: u32, panels: &[&str]) -> Result<(), String> {
        let points = std::iter::once(RUN.to_owned())
            .chain(panels.iter().map(|p| (*p).to_owned()))
            .collect::<Vec<_>>()
            .join(", ");
        let text = GOOD_MANIFEST.replace(RUN, &points).replace(
            r#""schema": 1,"#,
            &format!(r#""schema": 1, "addon_api": {addon_api},"#),
        );
        match parse_manifest(text.as_bytes()) {
            Ok(_) => Ok(()),
            Err(ManifestError::Malformed(reason)) => Err(reason),
        }
    }

    const PANEL: &str =
        r#"{"kind": "panel", "name": "Notes", "permission": "run", "command": "run"}"#;

    #[test]
    fn a_panel_installs_at_level_6() {
        assert_eq!(with_panels(6, &[PANEL]), Ok(()));
    }

    #[test]
    fn a_panel_below_level_6_is_refused_with_the_level_it_needs() {
        let reason = with_panels(5, &[PANEL]).unwrap_err();
        assert!(reason.contains("\"addon_api\": 6"), "{reason}");
    }

    #[test]
    fn a_panel_must_name_a_declared_command_and_permission() {
        let no_command = r#"{"kind": "panel", "name": "Notes", "permission": "run"}"#;
        assert!(
            with_panels(6, &[no_command])
                .unwrap_err()
                .contains("command")
        );
        let stray = r#"{"kind": "panel", "name": "Notes", "permission": "run", "command": "nope"}"#;
        assert!(with_panels(6, &[stray]).is_err());
        let no_permission = r#"{"kind": "panel", "name": "Notes", "command": "run"}"#;
        assert!(
            with_panels(6, &[no_permission])
                .unwrap_err()
                .contains("permission")
        );
    }

    #[test]
    fn panels_are_bounded_and_named_once() {
        let second = r#"{"kind": "panel", "name": "Board", "permission": "run", "command": "run"}"#;
        let third = r#"{"kind": "panel", "name": "Clock", "permission": "run", "command": "run"}"#;
        assert_eq!(with_panels(6, &[PANEL, second]), Ok(()));
        assert!(
            with_panels(6, &[PANEL, second, third])
                .unwrap_err()
                .contains("at most")
        );
        let twin = r#"{"kind": "panel", "name": "notes", "permission": "run", "command": "run"}"#;
        assert!(
            with_panels(6, &[PANEL, twin])
                .unwrap_err()
                .contains("twice")
        );
    }
}
