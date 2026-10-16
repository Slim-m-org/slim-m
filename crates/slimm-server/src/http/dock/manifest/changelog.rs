// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The manifest's optional `changelog`: what each version changed, newest
//! first, so an admin can see what an install or an update brings.

use serde::Deserialize;

use super::{ManifestError, bounded};

/// Versions kept; older entries are dropped rather than refusing the module,
/// since release notes are informational.
const MAX_ENTRIES: usize = 20;
/// Lines per version.
const MAX_CHANGES: usize = 20;
/// Characters per line.
const MAX_LINE: usize = 300;

#[derive(Deserialize)]
pub(super) struct RawChangelogEntry {
    version: String,
    #[serde(default)]
    changes: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::http) struct ChangelogEntry {
    pub(in crate::http) version: String,
    pub(in crate::http) changes: Vec<String>,
}

pub(super) fn validate_changelog(
    raw: Vec<RawChangelogEntry>,
) -> Result<Vec<ChangelogEntry>, ManifestError> {
    raw.into_iter()
        .take(MAX_ENTRIES)
        .map(|entry| {
            Ok(ChangelogEntry {
                version: bounded(&entry.version, super::MAX_SLUG, "changelog version")?,
                changes: entry
                    .changes
                    .iter()
                    .take(MAX_CHANGES)
                    .map(|line| bounded(line, MAX_LINE, "changelog line"))
                    .collect::<Result<_, _>>()?,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::super::parse_manifest;
    use super::super::tests::GOOD_MANIFEST;

    fn with_changelog(changelog: &str) -> String {
        GOOD_MANIFEST.replacen(
            "\"schema\": 1,",
            &format!("\"schema\": 1, \"changelog\": {changelog},"),
            1,
        )
    }

    #[test]
    fn a_manifest_without_a_changelog_has_none() {
        assert!(
            parse_manifest(GOOD_MANIFEST.as_bytes())
                .unwrap()
                .changelog
                .is_empty()
        );
    }

    #[test]
    fn a_changelog_is_kept_newest_first() {
        let manifest = with_changelog(
            r#"[{"version": "0.1.1", "changes": ["Faster", "Fixed the board"]}, {"version": "0.1.0"}]"#,
        );
        let changelog = parse_manifest(manifest.as_bytes()).unwrap().changelog;
        assert_eq!(changelog.len(), 2);
        assert_eq!(changelog[0].version, "0.1.1");
        assert_eq!(changelog[0].changes, ["Faster", "Fixed the board"]);
        assert!(changelog[1].changes.is_empty());
    }

    #[test]
    fn old_entries_past_the_cap_are_dropped_not_refused() {
        let entries: Vec<String> = (0..30)
            .map(|i| format!(r#"{{"version": "0.0.{i}", "changes": ["x"]}}"#))
            .collect();
        let manifest = with_changelog(&format!("[{}]", entries.join(",")));
        assert_eq!(
            parse_manifest(manifest.as_bytes()).unwrap().changelog.len(),
            20
        );
    }

    #[test]
    fn a_hidden_character_in_a_line_is_refused() {
        let manifest = with_changelog("[{\"version\": \"0.1.1\", \"changes\": [\"a\\u202eb\"]}]");
        assert!(parse_manifest(manifest.as_bytes()).is_err());
    }
}
