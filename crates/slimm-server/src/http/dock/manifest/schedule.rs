// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The manifest's `schedules`: commands the host runs on a timer with nobody
//! invoking them, once an admin approves the `schedule` capability.

use serde::Deserialize;

use super::{ManifestError, malformed};

/// The capability this section belongs to.
const SCHEDULE: &str = "schedule";
/// Most schedules a module may declare.
const MAX_SCHEDULES: usize = 8;
/// The shortest interval: often enough for a feed, rare enough to stay cheap.
pub(in crate::http) const MIN_EVERY_MINUTES: u32 = 5;
/// The longest interval, a week.
pub(in crate::http) const MAX_EVERY_MINUTES: u32 = 7 * 24 * 60;

#[derive(Deserialize)]
pub(super) struct RawSchedule {
    command: String,
    every_minutes: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::http) struct ManifestSchedule {
    pub(in crate::http) command: String,
    pub(in crate::http) every_minutes: u32,
}

/// `schedule` and a schedule list come together, and each entry names one
/// of the module's own `command` extension points, once.
pub(super) fn validate_schedules(
    raw: Vec<RawSchedule>,
    capabilities: &[String],
    command_names: &std::collections::HashSet<String>,
) -> Result<Vec<ManifestSchedule>, ManifestError> {
    let declares = capabilities.iter().any(|c| c == SCHEDULE);
    if declares && raw.is_empty() {
        return Err(malformed("the schedule capability needs schedules"));
    }
    if !declares && !raw.is_empty() {
        return Err(malformed(
            "schedules are only meaningful with the schedule capability",
        ));
    }
    if raw.len() > MAX_SCHEDULES {
        return Err(malformed("manifest declares too many schedules"));
    }
    let mut schedules: Vec<ManifestSchedule> = Vec::with_capacity(raw.len());
    for entry in raw {
        let command = entry.command.trim().to_owned();
        if !command_names.contains(&command) {
            return Err(malformed(
                "a schedule must name one of the module's commands",
            ));
        }
        if schedules.iter().any(|s| s.command == command) {
            return Err(malformed("a command may have only one schedule"));
        }
        if !(MIN_EVERY_MINUTES..=MAX_EVERY_MINUTES).contains(&entry.every_minutes) {
            return Err(malformed("schedule every_minutes is out of range"));
        }
        schedules.push(ManifestSchedule {
            command,
            every_minutes: entry.every_minutes,
        });
    }
    Ok(schedules)
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    fn raw(command: &str, every_minutes: u32) -> RawSchedule {
        RawSchedule {
            command: command.into(),
            every_minutes,
        }
    }

    fn names() -> HashSet<String> {
        ["poll".to_owned(), "digest".to_owned()]
            .into_iter()
            .collect()
    }

    fn caps(list: &[&str]) -> Vec<String> {
        list.iter().map(std::string::ToString::to_string).collect()
    }

    #[test]
    fn the_capability_and_schedules_come_together() {
        assert!(validate_schedules(vec![], &caps(&["schedule"]), &names()).is_err());
        assert!(validate_schedules(vec![raw("poll", 15)], &caps(&[]), &names()).is_err());
        assert_eq!(
            validate_schedules(vec![], &caps(&[]), &names()).unwrap(),
            vec![]
        );
    }

    #[test]
    fn a_schedule_names_a_declared_command_once_within_the_interval_range() {
        let ok = validate_schedules(
            vec![
                raw("poll", MIN_EVERY_MINUTES),
                raw("digest", MAX_EVERY_MINUTES),
            ],
            &caps(&["schedule"]),
            &names(),
        )
        .unwrap();
        assert_eq!(ok.len(), 2);
        for bad in [
            vec![raw("missing", 15)],
            vec![raw("poll", 15), raw("poll", 30)],
            vec![raw("poll", MIN_EVERY_MINUTES - 1)],
            vec![raw("poll", MAX_EVERY_MINUTES + 1)],
        ] {
            assert!(validate_schedules(bad, &caps(&["schedule"]), &names()).is_err());
        }
    }
}
